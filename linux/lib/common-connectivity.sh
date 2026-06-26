#!/bin/bash
################################################################################
# common-connectivity.sh - Connectivity helpers shared by OpenPath runtime
################################################################################

# URL and expected response for (single) captive portal detection
# Configurable via defaults.conf or environment variables
# NOTE: CAPTIVE_PORTAL_CHECK_URL/CAPTIVE_PORTAL_CHECK_EXPECTED are kept for testability.
CAPTIVE_PORTAL_CHECK_URL="${CAPTIVE_PORTAL_CHECK_URL:-${CAPTIVE_PORTAL_URL:-http://detectportal.firefox.com/success.txt}}"
CAPTIVE_PORTAL_CHECK_EXPECTED="${CAPTIVE_PORTAL_CHECK_EXPECTED:-${CAPTIVE_PORTAL_EXPECTED:-success}}"

# Detect primary DNS dynamically
is_usable_upstream_dns() {
    local dns="$1"

    validate_ip "$dns" || return 1

    case "$dns" in
        0.*|127.*|169.254.*|224.*|225.*|226.*|227.*|228.*|229.*|23[0-9].*|24[0-9].*|25[0-5].*)
            return 1
            ;;
    esac

    return 0
}

dns_candidate_resolves() {
    local dns="$1"

    is_usable_upstream_dns "$dns" || return 1
    timeout 5 dig @"$dns" google.com +short >/dev/null 2>&1
}

detect_dns_from_resolv_conf() {
    local resolv_conf="$1"
    local dns

    [ -n "$resolv_conf" ] && [ -f "$resolv_conf" ] || return 1

    while IFS= read -r dns; do
        dns="${dns%%#*}"
        dns=$(printf '%s' "$dns" | awk '$1 == "nameserver" { print $2 }')
        [ -n "$dns" ] || continue

        if dns_candidate_resolves "$dns"; then
            echo "$dns"
            return 0
        fi
    done < "$resolv_conf"

    return 1
}

detect_primary_dns() {
    local dns=""

    # 1. Try to read saved DNS.
    # Prefer the previously-persisted upstream when it is format-valid, WITHOUT
    # re-probing it. Once installed, apply_upstream_dns_owner_rule (firewall)
    # confines upstream :53 to dnsmasq's uid, so a `dig @<upstream>` probe run as
    # root on a later openpath-update is dropped by our OWN firewall and always
    # fails -- which would discard the good upstream and degrade PRIMARY_DNS to the
    # 8.8.8.8 fallback. The firewall only ever allowed the persisted upstream, so
    # every dnsmasq forward to that fallback is then dropped and all DNS dies
    # (whitelist download, the management/control-plane host, etc.). The persisted
    # value was validated when first written; keep it stable across updates so the
    # dnsmasq upstream and the firewall's allowed upstream cannot diverge.
    if [ -f "$ORIGINAL_DNS_FILE" ]; then
        local saved_dns
        saved_dns=$(head -1 "$ORIGINAL_DNS_FILE")
        if is_usable_upstream_dns "$saved_dns"; then
            echo "$saved_dns"
            return 0
        fi
    fi

    # 2. NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
        while IFS= read -r dns; do
            [ -n "$dns" ] || continue
            if dns_candidate_resolves "$dns"; then
                echo "$dns"
                return 0
            fi
        done < <(nmcli dev show 2>/dev/null | awk 'toupper($1) ~ /^IP4\.DNS/ { print $2 }')
    fi

    # 3. systemd-resolved
    if dns=$(detect_dns_from_resolv_conf "${OPENPATH_SYSTEMD_RESOLV_CONF:-/run/systemd/resolve/resolv.conf}"); then
        echo "$dns"
        return 0
    fi

    # 4. Current resolver configuration, when it exposes a real upstream.
    if dns=$(detect_dns_from_resolv_conf "${OPENPATH_RESOLV_CONF:-/etc/resolv.conf}"); then
        echo "$dns"
        return 0
    fi

    # 5. Gateway as DNS
    local gw
    gw=$(ip route | grep default | awk '{print $3}' | head -1)
    if dns_candidate_resolves "$gw"; then
        echo "$gw"
        return 0
    fi

    dns="${FALLBACK_DNS_PRIMARY:-8.8.8.8}"
    if is_usable_upstream_dns "$dns"; then
        echo "$dns"
    else
        echo "8.8.8.8"
    fi
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# Discover the DHCP-provided DNS servers for the current network.
# Linux analogue of the Windows DhcpNameServer registry lookup
# (Get-OpenPathCaptivePortalDhcpNameServerCandidates): the DHCP-offered
# resolver is the only one that knows internal captive-portal hostnames,
# so split-DNS detection needs it even after OpenPath pins /etc/resolv.conf
# to 127.0.0.1.
#
# Tries, in order:
#   1. systemd-resolved's upstream list (/run/systemd/resolve/resolv.conf)
#   2. dhclient lease files (/var/lib/dhcp/dhclient*.lease*)
#   3. NetworkManager per-device DNS (nmcli dev show IP4.DNS)
#
# Prints one usable IPv4 address per line (deduplicated, source order kept).
# Returns 1 when no DHCP DNS could be determined; callers must degrade
# gracefully and skip split-DNS detection in that case.
get_dhcp_dns_servers() {
    local candidates candidate emitted=""
    local resolved_conf="${OPENPATH_SYSTEMD_RESOLV_CONF:-/run/systemd/resolve/resolv.conf}"
    local lease_dir="${OPENPATH_DHCLIENT_LEASE_DIR:-/var/lib/dhcp}"

    candidates=$(
        {
            # 1. systemd-resolved upstream list (DHCP-provided on most setups)
            if [ -f "$resolved_conf" ]; then
                awk '$1 == "nameserver" { print $2 }' "$resolved_conf"
            fi

            # 2. dhclient leases: take the most recent domain-name-servers
            #    declaration from each lease file
            local lease
            for lease in "$lease_dir"/dhclient*.lease*; do
                [ -f "$lease" ] || continue
                sed -n 's/.*option domain-name-servers \([^;]*\);.*/\1/p' "$lease" \
                    | tail -1 | tr ',' '\n'
            done

            # 3. NetworkManager: per-device DNS still reflects the DHCP offer
            #    even after /etc/resolv.conf is pinned to 127.0.0.1
            if command -v nmcli >/dev/null 2>&1; then
                nmcli dev show 2>/dev/null \
                    | awk 'toupper($1) ~ /^IP4\.DNS/ { print $2 }'
            fi
        } 2>/dev/null
    )

    while IFS= read -r candidate; do
        candidate="${candidate//[[:space:]]/}"
        [ -n "$candidate" ] || continue
        is_usable_upstream_dns "$candidate" || continue
        case "$emitted" in
            *"|$candidate|"*) continue ;;
        esac
        emitted="${emitted}|$candidate|"
        echo "$candidate"
    done <<< "$candidates"

    [ -n "$emitted" ]
}

check_internet() {
    if timeout 10 curl -s http://detectportal.firefox.com/success.txt 2>/dev/null | grep -q "success"; then
        return 0
    fi
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Get captive portal state.
# Returns one of AUTHENTICATED, PORTAL, NO_NETWORK.
get_captive_portal_state() {
    local timeout_sec="${CAPTIVE_PORTAL_TIMEOUT:-3}"
    local checks_raw="${CAPTIVE_PORTAL_CHECKS:-}"

    if [ -n "$checks_raw" ]; then
        local total=0
        local reachable=0
        local success=0
        local transport_fail=0

        local check
        local -a checks
        IFS='|' read -r -a checks <<< "$checks_raw"

        for check in "${checks[@]}"; do
            [ -z "$check" ] && continue
            total=$((total + 1))

            local url expected
            IFS=',' read -r url expected <<< "$check"
            url="${url//[[:space:]]/}"

            local response rc
            response=$(timeout "$timeout_sec" curl -s -L "$url" 2>/dev/null)
            rc=$?
            if [ "$rc" -ne 0 ]; then
                transport_fail=$((transport_fail + 1))
                continue
            fi

            reachable=$((reachable + 1))
            response=$(printf '%s' "$response" | tr -d '\n\r')
            if [ "$response" = "$expected" ]; then
                success=$((success + 1))
            fi
        done

        if [ "$total" -eq 0 ] || [ "$transport_fail" -ge "$total" ] || [ "$reachable" -eq 0 ] || [ "$reachable" -lt 2 ]; then
            echo "NO_NETWORK"
            return 0
        fi

        local threshold
        threshold=$(((reachable / 2) + 1))
        if [ "$success" -ge "$threshold" ]; then
            echo "AUTHENTICATED"
            return 0
        fi

        echo "PORTAL"
        return 0
    fi

    local response rc
    response=$(timeout "$timeout_sec" curl -s -L "$CAPTIVE_PORTAL_CHECK_URL" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "NO_NETWORK"
        return 0
    fi

    response=$(printf '%s' "$response" | tr -d '\n\r')
    if [ "$response" = "$CAPTIVE_PORTAL_CHECK_EXPECTED" ]; then
        echo "AUTHENTICATED"
        return 0
    fi

    echo "PORTAL"
    return 0
}

check_captive_portal() {
    local state
    state=$(get_captive_portal_state)
    [ "$state" = "PORTAL" ]
}

is_network_authenticated() {
    local state
    state=$(get_captive_portal_state)
    [ "$state" = "AUTHENTICATED" ]
}
