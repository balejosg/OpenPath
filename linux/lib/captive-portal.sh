#!/bin/bash
set -o pipefail

# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

################################################################################
# captive-portal.sh - Captive portal helpers
# Part of the OpenPath DNS system
#
# Expected dependencies (must be sourced by the caller):
# - common.sh (VAR_STATE_DIR, LOG_FILE, log functions)
# - dns.sh (detect_primary_dns, restart_dnsmasq)
# - firewall.sh (activate_firewall, deactivate_firewall, flush_connections)
################################################################################

# Debian/FHS state paths (overrideable for tests)
CAPTIVE_PORTAL_STATE_FILE="${CAPTIVE_PORTAL_STATE_FILE:-$VAR_STATE_DIR/captive-portal-active.state}"
CAPTIVE_PORTAL_OBSERVATION_FILE="${CAPTIVE_PORTAL_OBSERVATION_FILE:-$VAR_STATE_DIR/captive-portal-observation.state}"
CAPTIVE_DNSMASQ_BACKUP_FILE="${CAPTIVE_DNSMASQ_BACKUP_FILE:-$VAR_STATE_DIR/openpath.conf.pre-portal}"

is_portal_mode_active() {
    [ -f "$CAPTIVE_PORTAL_STATE_FILE" ]
}

get_portal_mode_start_ts() {
    if [ ! -f "$CAPTIVE_PORTAL_STATE_FILE" ]; then
        return 1
    fi

    local ts
    ts=$(cat "$CAPTIVE_PORTAL_STATE_FILE" 2>/dev/null | head -1)
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        echo "$ts"
        return 0
    fi
    return 1
}

################################################################################
# Marker with expiry (WEDU lesson, mirrors Windows captive-portal-active.json
# expiresAt). Format is additive over the legacy single-line marker:
#   line 1: start epoch (legacy, read by get_portal_mode_start_ts)
#   line 2: expires=<epoch>
# A legacy marker without an expires= line is never considered expired,
# mirroring Test-OpenPathCaptivePortalMarkerExpired on markers without
# expiresAt.
################################################################################

# Print the marker's expiry epoch. Returns 1 when the marker is absent or
# carries no (valid) expiry.
get_portal_mode_expiry_ts() {
    if [ ! -f "$CAPTIVE_PORTAL_STATE_FILE" ]; then
        return 1
    fi

    local expiry
    expiry=$(sed -n 's/^expires=//p' "$CAPTIVE_PORTAL_STATE_FILE" 2>/dev/null | head -1)
    if [[ "$expiry" =~ ^[0-9]+$ ]]; then
        echo "$expiry"
        return 0
    fi
    return 1
}

# Returns 0 when the marker exists and its expiry deadline has passed.
is_portal_mode_expired() {
    local expiry
    expiry=$(get_portal_mode_expiry_ts) || return 1
    [ "$(date +%s)" -ge "$expiry" ]
}

# Write the portal-mode marker with a fresh expiry deadline.
# Args: 1) start epoch (preserved across refreshes)
# The new expires value is clamped so it never exceeds start_ts + MAX_LIFETIME.
write_portal_mode_marker() {
    local start_ts="$1"
    local ttl="${CAPTIVE_PORTAL_TTL_SECONDS:-120}"
    local max_lifetime="${CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS:-1800}"

    if ! [[ "$ttl" =~ ^[0-9]+$ ]] || [ "$ttl" -lt 1 ]; then
        ttl=120
    fi
    if ! [[ "$max_lifetime" =~ ^[0-9]+$ ]] || [ "$max_lifetime" -lt 1 ]; then
        max_lifetime=1800
    fi

    local now hard_deadline expires
    now=$(date +%s)
    hard_deadline=$(( start_ts + max_lifetime ))
    expires=$(( now + ttl ))
    if [ "$expires" -gt "$hard_deadline" ]; then
        expires="$hard_deadline"
    fi

    mkdir -p "$(dirname "$CAPTIVE_PORTAL_STATE_FILE")" 2>/dev/null || true
    {
        echo "$start_ts"
        echo "expires=$expires"
    } > "$CAPTIVE_PORTAL_STATE_FILE" 2>/dev/null || true
}

# Extend the marker's expiry while the portal is still being observed
# (mirrors the Windows watchdog re-arming the marker TTL each cycle).
# Preserves the original start timestamp. Returns 1 when no marker exists.
# When the absolute lifetime cap (CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS) has
# been reached, the refresh is refused and portal mode is force-closed instead.
refresh_portal_mode_expiry() {
    is_portal_mode_active || return 1

    local start_ts now max_lifetime elapsed
    if ! start_ts=$(get_portal_mode_start_ts); then
        start_ts=$(date +%s)
    fi

    now=$(date +%s)
    max_lifetime="${CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS:-1800}"
    if ! [[ "$max_lifetime" =~ ^[0-9]+$ ]] || [ "$max_lifetime" -lt 1 ]; then
        max_lifetime=1800
    fi

    elapsed=$(( now - start_ts ))
    if [ "$elapsed" -ge "$max_lifetime" ]; then
        log "[CAPTIVE] Portal passthrough absolute lifetime cap reached (${elapsed}s >= ${max_lifetime}s) - forcing close" "WARN"
        with_openpath_lock exit_portal_mode_locked
        return 0
    fi

    write_portal_mode_marker "$start_ts"
}

# Watchdog/detector auto-close hook: restore protections when the passthrough
# marker has outlived its deadline (the portal flow never completed). Returns
# 1 when there is nothing to close.
close_expired_portal_mode() {
    is_portal_mode_active || return 1
    is_portal_mode_expired || return 1

    log "[CAPTIVE] Portal passthrough deadline expired - restoring protections" "WARN"
    with_openpath_lock exit_portal_mode_locked
}

################################################################################
# Anti-oscillation observation counters (mirrors Windows
# captive-portal-observation.json / Update-OpenPathCaptivePortalObservation):
# consecutive-observation thresholds gate portal-mode entry/exit so a flapping
# detection result does not toggle the firewall on every poll.
################################################################################

# Read a consecutive-observation counter from the observation file.
# Args: 1) "portal" or "authenticated". Prints 0 for absent/corrupt files.
get_captive_portal_observation_count() {
    local key="$1"
    local value
    value=$(awk -F= -v k="${key}_count" '$1 == k { print $2; exit }' \
        "$CAPTIVE_PORTAL_OBSERVATION_FILE" 2>/dev/null)
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    else
        echo "0"
    fi
}

# Record a detection result: PORTAL increments portal_count and resets
# authenticated_count; AUTHENTICATED does the inverse; NO_NETWORK leaves both
# counters unchanged (Windows parity). Persistence is best-effort.
update_captive_portal_observation() {
    local detected_state="$1"
    local portal_count authenticated_count
    portal_count=$(get_captive_portal_observation_count portal)
    authenticated_count=$(get_captive_portal_observation_count authenticated)

    case "$detected_state" in
        PORTAL)
            portal_count=$((portal_count + 1))
            authenticated_count=0
            ;;
        AUTHENTICATED)
            authenticated_count=$((authenticated_count + 1))
            portal_count=0
            ;;
        *)
            # NO_NETWORK or unknown: keep counters unchanged.
            ;;
    esac

    mkdir -p "$(dirname "$CAPTIVE_PORTAL_OBSERVATION_FILE")" 2>/dev/null || true
    {
        echo "portal_count=$portal_count"
        echo "authenticated_count=$authenticated_count"
        echo "detected_state=$detected_state"
        echo "updated_at=$(date +%s)"
    } > "$CAPTIVE_PORTAL_OBSERVATION_FILE" 2>/dev/null || true
    return 0
}

# Returns 0 once enough consecutive PORTAL observations have accumulated.
# The caller still gates on "not already in portal mode".
should_enter_portal_mode() {
    local threshold="${CAPTIVE_PORTAL_ENTER_THRESHOLD:-2}"
    [ "$(get_captive_portal_observation_count portal)" -ge "$threshold" ]
}

# Returns 0 once enough consecutive AUTHENTICATED observations have
# accumulated. The caller still gates on "currently in portal mode".
should_exit_portal_mode() {
    local threshold="${CAPTIVE_PORTAL_EXIT_THRESHOLD:-1}"
    [ "$(get_captive_portal_observation_count authenticated)" -ge "$threshold" ]
}

################################################################################
# Split-DNS detection (WEDU root cause; mirrors Test-OpenPathSplitDnsActive):
# the captive portal host may resolve ONLY via the network's DHCP-provided DNS
# while the configured upstream returns NXDOMAIN. When that topology is
# detected, portal-mode passthrough must forward to the DHCP DNS or the portal
# stays unreachable and the machine never authenticates.
################################################################################

# Print the admin-declared captive-portal hostnames (one per line, lowercase).
# Returns 1 when none are declared.
get_captive_portal_split_dns_hosts() {
    local raw="${CAPTIVE_PORTAL_SPLIT_DNS_HOSTS:-}"
    [ -n "$raw" ] || return 1

    local found=1
    local host
    local -a hosts
    IFS=',' read -r -a hosts <<< "$raw"
    for host in "${hosts[@]}"; do
        host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        host="${host%.}"
        [ -n "$host" ] || continue
        echo "$host"
        found=0
    done
    return "$found"
}

# Returns 0 when the DNS server answers the host with at least one record.
# Unlike dns_candidate_resolves this compares RESULTS, not transport: dig
# exits 0 on NXDOMAIN, so an empty answer section means "does not resolve".
dns_server_resolves_host() {
    local server="$1"
    local host="$2"
    local timeout_sec="${DNS_VALIDATION_TIMEOUT:-5}"

    local answer
    answer=$(timeout "$timeout_sec" dig @"$server" "$host" +short 2>/dev/null | head -1)
    [ -n "$answer" ]
}

# Probe the declared portal hosts via the DHCP-provided DNS servers vs the
# configured upstream. Prints the first DHCP DNS that resolves a declared host
# the upstream cannot resolve, and returns 0 (split DNS detected). Returns 1
# when no hosts are declared, the DHCP DNS is unknown (graceful degradation),
# or no exclusive resolution is found.
# Args: 1) configured upstream DNS IP (optional)
detect_split_dns_upstream() {
    local upstream="${1:-}"
    local -a portal_hosts dhcp_servers

    mapfile -t portal_hosts < <(get_captive_portal_split_dns_hosts)
    [ "${#portal_hosts[@]}" -gt 0 ] || return 1

    mapfile -t dhcp_servers < <(get_dhcp_dns_servers)
    [ "${#dhcp_servers[@]}" -gt 0 ] || return 1

    local host server
    for host in "${portal_hosts[@]}"; do
        if [ -n "$upstream" ] && dns_server_resolves_host "$upstream" "$host"; then
            # The configured upstream serves this host: no split for it.
            continue
        fi
        for server in "${dhcp_servers[@]}"; do
            [ "$server" = "$upstream" ] && continue
            if dns_server_resolves_host "$server" "$host"; then
                echo "$server"
                return 0
            fi
        done
    done
    return 1
}

# Boolean wrapper over detect_split_dns_upstream (port of the
# Test-OpenPathSplitDnsActive concept).
# Args: 1) configured upstream DNS IP (optional)
is_split_dns_active() {
    detect_split_dns_upstream "$@" >/dev/null
}

get_active_ssid() {
    if ! command -v nmcli >/dev/null 2>&1; then
        return 1
    fi

    LC_ALL=C nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null \
        | awk -F: '$1=="yes" {print $2; exit}'
}

enter_portal_mode_locked() {
    mkdir -p "$VAR_STATE_DIR" 2>/dev/null || true

    PRIMARY_DNS=$(detect_primary_dns)

    # WEDU lesson: when the portal host resolves only via the DHCP-provided
    # DNS (split DNS), passthrough through the configured/detected upstream
    # would NXDOMAIN the portal and authentication could never complete.
    local split_dns_upstream
    if split_dns_upstream=$(detect_split_dns_upstream "$PRIMARY_DNS"); then
        log "[CAPTIVE] Split DNS detected: declared portal host resolves only via DHCP DNS $split_dns_upstream - using it for passthrough" "WARN"
        PRIMARY_DNS="$split_dns_upstream"
    fi
    export PRIMARY_DNS

    if [ -f "$DNSMASQ_CONF" ]; then
        cp "$DNSMASQ_CONF" "$CAPTIVE_DNSMASQ_BACKUP_FILE" 2>/dev/null || true
    fi

    log "[CAPTIVE] Captive portal detected - enabling fail-open mode (DNS passthrough + permissive firewall)" "WARN"

    if ! write_dnsmasq_passthrough_config "$PRIMARY_DNS" "$DNSMASQ_CONF"; then
        log "[CAPTIVE] ERROR: Could not write portal-mode DNS configuration" "ERROR"
    fi

    if ! restart_dnsmasq; then
        log "[CAPTIVE] ERROR: dnsmasq did not restart in portal mode" "ERROR"
        if [ -f "$CAPTIVE_DNSMASQ_BACKUP_FILE" ]; then
            log "[CAPTIVE] Restoring previous DNS configuration" "WARN"
            cp "$CAPTIVE_DNSMASQ_BACKUP_FILE" "$DNSMASQ_CONF" 2>/dev/null || true
            restart_dnsmasq 2>/dev/null || true
        fi
    fi

    # deactivate_firewall also relaxes the bypass blocks (DoH ipset rules,
    # VPN interface/port blocks, Tor port blocks) and destroys the
    # openpath-doh-block ipset so portal login pages on HTTPS resolver
    # infrastructure are reachable during the passthrough window.
    deactivate_firewall
    flush_connections 2>/dev/null || true

    write_portal_mode_marker "$(date +%s)"
    return 0
}

exit_portal_mode_locked() {
    PRIMARY_DNS=$(detect_primary_dns)
    export PRIMARY_DNS

    local start_ts duration
    duration=""
    if start_ts=$(get_portal_mode_start_ts); then
        duration=$(( $(date +%s) - start_ts ))
    fi

    log "[CAPTIVE] Authentication completed - restoring protections" "INFO"
    if [ -n "$duration" ]; then
        log "[CAPTIVE] Tiempo en modo portal: ${duration}s" "INFO"
    fi

    if [ -f "$DNSMASQ_CONF" ] && grep -q "^# OPENPATH PORTAL MODE" "$DNSMASQ_CONF" 2>/dev/null; then
        if [ -f "$CAPTIVE_DNSMASQ_BACKUP_FILE" ]; then
            cp "$CAPTIVE_DNSMASQ_BACKUP_FILE" "$DNSMASQ_CONF" 2>/dev/null || true
            restart_dnsmasq 2>/dev/null || true
        fi
    fi

    rm -f "$CAPTIVE_DNSMASQ_BACKUP_FILE" 2>/dev/null || true
    rm -f "$CAPTIVE_PORTAL_STATE_FILE" 2>/dev/null || true

    activate_firewall
    flush_connections 2>/dev/null || true
    return 0
}
