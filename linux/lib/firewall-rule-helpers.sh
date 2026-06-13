#!/bin/bash

################################################################################
# firewall-rule-helpers.sh - iptables rule wrapper helpers
################################################################################

add_critical_rule() {
    local desc="$1"
    shift

    if "$@" 2>/dev/null; then
        log_debug "✓ [CRITICAL] $desc"
        return 0
    fi

    log_error "FAILED [CRITICAL]: $desc"
    log_error "  Command: $*"
    return 1
}

add_important_rule() {
    local desc="$1"
    shift

    if "$@" 2>/dev/null; then
        log_debug "✓ [IMPORTANT] $desc"
        return 0
    fi

    log_warn "FAILED [IMPORTANT]: $desc (continuing)"
    return 0
}

add_optional_rule() {
    local desc="$1"
    shift

    if "$@" 2>/dev/null; then
        log_debug "✓ [OPTIONAL] $desc"
        return 0
    fi

    log_debug "SKIPPED [OPTIONAL]: $desc"
    return 0
}

################################################################################
# Bypass-vector blocking (DoH / VPN / Tor) rule builders
#
# Mirrors the Windows agent's anti-bypass catalog
# (windows/lib/internal/Firewall.Catalog.ps1). Defaults live in
# lib/defaults.conf and can be overridden via /etc/openpath/overrides.conf or
# environment variables:
#   OPENPATH_DOH_BLOCK_ENABLED / OPENPATH_DOH_RESOLVERS
#   OPENPATH_VPN_BLOCK_ENABLED / OPENPATH_VPN_BLOCK_RULES / OPENPATH_VPN_BLOCK_INTERFACES
#   OPENPATH_TOR_BLOCK_ENABLED / OPENPATH_TOR_BLOCK_PORTS
################################################################################

OPENPATH_DOH_BLOCK_IPSET="${OPENPATH_DOH_BLOCK_IPSET:-openpath-doh-block}"
OPENPATH_IPSET_STATE_FILE="${OPENPATH_IPSET_STATE_FILE:-/etc/iptables/openpath-ipsets.v4}"

# Name-aware egress allow set: dnsmasq adds the resolved IPs of whitelisted and
# essential domains here (via ipset= directives in the generated config), and
# the firewall scopes the 80/443 ACCEPT to this set instead of any destination.
# See apply_http_egress_rules and emit_dnsmasq_allow_domain (dns-dnsmasq.sh).
OPENPATH_ALLOW_DST_IPSET="${OPENPATH_ALLOW_DST_IPSET:-openpath-allow-dst}"
OPENPATH_ALLOW_SET_TIMEOUT="${OPENPATH_ALLOW_SET_TIMEOUT:-600}"

# IPv4 subset of the Windows Get-DefaultDohResolverIps catalog (the Linux
# agent enforces IPv4 only; dnsmasq sinkholes IPv6 via address=/#/100::).
openpath_default_doh_resolvers() {
    printf '%s' "8.8.8.8,8.8.4.4,1.1.1.1,1.0.0.1,9.9.9.9,149.112.112.112,208.67.222.222,208.67.220.220,45.90.28.0,45.90.30.0,194.242.2.2,194.242.2.3,94.140.14.14,94.140.15.15,76.76.2.0,76.76.10.0"
}

# Matches Windows Get-DefaultVpnBlockRules (protocol:port:name)
openpath_default_vpn_block_rules() {
    printf '%s' "udp:1194:OpenVPN,tcp:1194:OpenVPN-TCP,udp:51820:WireGuard,tcp:1723:PPTP,udp:500:IKE,udp:4500:IPSec-NAT"
}

# Matches Windows Get-DefaultTorBlockPorts
openpath_default_tor_block_ports() {
    printf '%s' "9001,9030,9050,9051,9150"
}

openpath_flag_enabled() {
    local value="${1:-1}"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        0 | false | no | off | disabled) return 1 ;;
        *) return 0 ;;
    esac
}

doh_block_enabled() { openpath_flag_enabled "${DOH_BLOCK_ENABLED:-1}"; }
vpn_block_enabled() { openpath_flag_enabled "${VPN_BLOCK_ENABLED:-1}"; }
tor_block_enabled() { openpath_flag_enabled "${TOR_BLOCK_ENABLED:-1}"; }

openpath_ipset_available() { command -v ipset >/dev/null 2>&1; }

allow_set_egress_enabled() { openpath_flag_enabled "${ALLOW_SET_EGRESS_ENABLED:-1}"; }

# Name-aware egress is in force only when enabled AND ipset is usable; callers
# fall back to a broad 80/443 ACCEPT otherwise so connectivity is never lost on
# kernels without ipset.
allow_set_egress_active() {
    allow_set_egress_enabled && openpath_ipset_available
}

# Create (idempotent) the egress allow ipset that dnsmasq populates with the
# resolved IPs of whitelisted/essential domains. It must exist both before
# dnsmasq loads its config (the ipset= directive does not create the set) and
# before the match-set ACCEPT rule is inserted (iptables rejects a rule that
# references a missing set). The timeout lets a recycled CDN IP that stops
# resolving expire out of the set; -exist keeps live entries across re-activation.
ensure_allow_dst_ipset() {
    allow_set_egress_active || return 0
    add_important_rule "Create egress allow ipset $OPENPATH_ALLOW_DST_IPSET" \
        ipset create "$OPENPATH_ALLOW_DST_IPSET" hash:ip timeout "$OPENPATH_ALLOW_SET_TIMEOUT" -exist
    return 0
}

# HTTP/HTTPS egress. When name-aware egress is active, scope the 80/443 ACCEPT to
# the resolved-whitelist allow set so only IPs dnsmasq resolved for an allowed
# domain are reachable (closes direct-IP, --resolve, self-hosted-DoH and
# domain-fronting bypasses). Falls back to a broad ACCEPT when ipset is
# unavailable or the feature is disabled.
apply_http_egress_rules() {
    if allow_set_egress_active; then
        add_important_rule "Allow HTTP to resolved-whitelist IPs (port 80)" \
            iptables -A OUTPUT -p tcp --dport 80 -m set --match-set "$OPENPATH_ALLOW_DST_IPSET" dst -j ACCEPT
        add_important_rule "Allow HTTPS to resolved-whitelist IPs (port 443)" \
            iptables -A OUTPUT -p tcp --dport 443 -m set --match-set "$OPENPATH_ALLOW_DST_IPSET" dst -j ACCEPT
        return 0
    fi

    log_warn "Name-aware egress inactive (ipset unavailable or disabled) - allowing broad HTTP/HTTPS"
    add_optional_rule "Allow HTTP (port 80)" \
        iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
    add_optional_rule "Allow HTTPS (port 443)" \
        iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
}

# NTP egress. When name-aware egress is active, scope udp/123 to the same
# resolved-whitelist allow set (the NTP domains ntp.ubuntu.com/time.google.com
# are populated into it), so a student cannot run an NTP-shaped tunnel to an
# arbitrary endpoint. Falls back to a broad ACCEPT otherwise.
apply_ntp_egress_rules() {
    if allow_set_egress_active; then
        add_important_rule "Allow NTP to resolved-whitelist IPs (port 123)" \
            iptables -A OUTPUT -p udp --dport 123 -m set --match-set "$OPENPATH_ALLOW_DST_IPSET" dst -j ACCEPT
        return 0
    fi

    add_optional_rule "Allow NTP (port 123)" \
        iptables -A OUTPUT -p udp --dport 123 -j ACCEPT
}

bridge_enforcement_enabled() { openpath_flag_enabled "${BRIDGE_ENFORCEMENT_ENABLED:-1}"; }

# Subject bridged/forwarded guest-VM traffic to netfilter. Loading br_netfilter
# and enabling bridge-nf-call-ip(6)tables makes frames crossing a Linux bridge
# traverse the iptables FORWARD chain, so a hosted VM cannot bridge onto the LAN
# below the host firewall. Persisted across reboots; non-fatal when the module
# is unavailable (e.g. inside a restricted container).
apply_bridge_enforcement() {
    bridge_enforcement_enabled || return 0

    local sysctl_d_dir="${OPENPATH_SYSCTL_D_DIR:-/etc/sysctl.d}"
    if modprobe br_netfilter 2>/dev/null; then
        sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
        sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true
        if [ -d "$sysctl_d_dir" ]; then
            {
                echo "# OpenPath: subject bridged guest-VM frames to netfilter"
                echo "net.bridge.bridge-nf-call-iptables=1"
                echo "net.bridge.bridge-nf-call-ip6tables=1"
            } > "$sysctl_d_dir/99-openpath-bridge.conf" 2>/dev/null || true
        fi
        log_debug "br_netfilter enabled; bridged frames traverse iptables"
    else
        log_warn "br_netfilter unavailable - bridged VM traffic may not be fully constrained"
    fi
}

# FORWARD default-deny so a classroom endpoint does not route guest/bridged
# traffic around the host policy; a hosted VM is thereby forced onto host-routed
# NAT (where the OUTPUT policy applies). Established/related is allowed so
# legitimate NAT return traffic still flows. Idempotent (deletes the prior
# established rule before re-adding). Gated so operators that legitimately route
# (Docker/libvirt) can disable it via OPENPATH_BRIDGE_ENFORCEMENT_ENABLED=0.
apply_forward_default_deny() {
    bridge_enforcement_enabled || return 0

    iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    add_important_rule "FORWARD allow established (NAT return)" \
        iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    add_critical_rule "FORWARD default deny (bridged/guest VM)" \
        iptables -P FORWARD DROP
}

# Restore a permissive FORWARD chain on deactivation/uninstall.
restore_forward_chain() {
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
}

# DoH egress blocking: DROP tcp/udp :443 to known resolver IPs through an
# ipset. Rules are port-scoped to 443, so dnsmasq's own upstream queries on
# :53 (e.g. 8.8.8.8:53) stay reachable even though the upstream IP is in the
# block set. Falls back to per-IP rules when ipset is unavailable.
apply_doh_block_rules() {
    if ! doh_block_enabled; then
        log_warn "DoH IP blocking disabled by configuration (OPENPATH_DOH_BLOCK_ENABLED)"
        return 0
    fi

    local doh_resolvers_raw="${DOH_RESOLVERS:-$(openpath_default_doh_resolvers)}"
    local doh_resolvers=()
    IFS=',' read -r -a doh_resolvers <<< "$doh_resolvers_raw"

    local resolver_ip
    if openpath_ipset_available; then
        add_important_rule "Create DoH block ipset $OPENPATH_DOH_BLOCK_IPSET" \
            ipset create "$OPENPATH_DOH_BLOCK_IPSET" hash:ip -exist
        add_important_rule "Flush DoH block ipset $OPENPATH_DOH_BLOCK_IPSET" \
            ipset flush "$OPENPATH_DOH_BLOCK_IPSET"

        for resolver_ip in "${doh_resolvers[@]}"; do
            resolver_ip="${resolver_ip//[[:space:]]/}"
            [ -z "$resolver_ip" ] && continue

            if ! validate_ip "$resolver_ip"; then
                log_warn "Skipping invalid DoH resolver IP: $resolver_ip"
                continue
            fi

            add_important_rule "Add DoH resolver $resolver_ip to ipset" \
                ipset add "$OPENPATH_DOH_BLOCK_IPSET" "$resolver_ip" -exist
        done

        add_important_rule "Block DoH resolvers in $OPENPATH_DOH_BLOCK_IPSET (TCP/443)" \
            iptables -A OUTPUT -p tcp --dport 443 -m set --match-set "$OPENPATH_DOH_BLOCK_IPSET" dst -j DROP
        add_important_rule "Block DoH resolvers in $OPENPATH_DOH_BLOCK_IPSET (UDP/443)" \
            iptables -A OUTPUT -p udp --dport 443 -m set --match-set "$OPENPATH_DOH_BLOCK_IPSET" dst -j DROP
        return 0
    fi

    log_warn "ipset not available - using per-IP DoH block rules"
    for resolver_ip in "${doh_resolvers[@]}"; do
        resolver_ip="${resolver_ip//[[:space:]]/}"
        [ -z "$resolver_ip" ] && continue

        if ! validate_ip "$resolver_ip"; then
            log_warn "Skipping invalid DoH resolver IP: $resolver_ip"
            continue
        fi

        add_important_rule "Block DoH resolver $resolver_ip (TCP/443)" \
            iptables -A OUTPUT -d "$resolver_ip" -p tcp --dport 443 -j DROP
        add_important_rule "Block DoH resolver $resolver_ip (UDP/443)" \
            iptables -A OUTPUT -d "$resolver_ip" -p udp --dport 443 -j DROP
    done
    return 0
}

# Drop everything routed out through VPN tunnel interfaces (tun+/tap+ by
# default). Applied early in the OUTPUT chain, before the generic
# ESTABLISHED,RELATED accept, so already-established tunnels are cut too.
apply_vpn_interface_block_rules() {
    if ! vpn_block_enabled; then
        log_debug "VPN blocking disabled by configuration (OPENPATH_VPN_BLOCK_ENABLED)"
        return 0
    fi

    local vpn_interfaces_raw="${VPN_BLOCK_INTERFACES:-tun+,tap+}"
    local vpn_interfaces=()
    IFS=',' read -r -a vpn_interfaces <<< "$vpn_interfaces_raw"

    local vpn_iface
    for vpn_iface in "${vpn_interfaces[@]}"; do
        vpn_iface="${vpn_iface//[[:space:]]/}"
        [ -z "$vpn_iface" ] && continue

        if ! [[ "$vpn_iface" =~ ^[A-Za-z0-9._-]{1,15}\+?$ ]]; then
            log_warn "Skipping invalid VPN interface pattern: $vpn_iface"
            continue
        fi

        add_important_rule "Block VPN interface output ($vpn_iface)" \
            iptables -A OUTPUT -o "$vpn_iface" -j DROP
    done
    return 0
}

# Block the VPN control/tunnel port catalog (protocol:port:name entries).
apply_vpn_port_block_rules() {
    if ! vpn_block_enabled; then
        log_warn "VPN blocking disabled by configuration (OPENPATH_VPN_BLOCK_ENABLED)"
        return 0
    fi

    local vpn_block_rules_raw="${VPN_BLOCK_RULES:-$(openpath_default_vpn_block_rules)}"
    local vpn_block_rules=()
    IFS=',' read -r -a vpn_block_rules <<< "$vpn_block_rules_raw"

    local vpn_rule
    for vpn_rule in "${vpn_block_rules[@]}"; do
        vpn_rule="${vpn_rule//[[:space:]]/}"
        [ -z "$vpn_rule" ] && continue

        local vpn_protocol=""
        local vpn_port=""
        local vpn_name="VPN"

        IFS=':' read -r vpn_protocol vpn_port vpn_name <<< "$vpn_rule"
        vpn_protocol="$(printf '%s' "$vpn_protocol" | tr '[:upper:]' '[:lower:]')"

        if [ "$vpn_protocol" != "tcp" ] && [ "$vpn_protocol" != "udp" ]; then
            log_warn "Skipping invalid VPN rule protocol: $vpn_rule"
            continue
        fi

        if ! [[ "$vpn_port" =~ ^[0-9]+$ ]] || [ "$vpn_port" -lt 1 ] || [ "$vpn_port" -gt 65535 ]; then
            log_warn "Skipping invalid VPN rule port: $vpn_rule"
            continue
        fi

        [ -z "$vpn_name" ] && vpn_name="VPN-$vpn_port"

        add_important_rule "Block $vpn_name (port $vpn_port/$vpn_protocol)" \
            iptables -A OUTPUT -p "$vpn_protocol" --dport "$vpn_port" -j DROP
    done
    return 0
}

# Block the Tor port catalog (TCP).
apply_tor_block_rules() {
    if ! tor_block_enabled; then
        log_warn "Tor port blocking disabled by configuration (OPENPATH_TOR_BLOCK_ENABLED)"
        return 0
    fi

    local tor_ports_raw="${TOR_BLOCK_PORTS:-$(openpath_default_tor_block_ports)}"
    local tor_ports=()
    IFS=',' read -r -a tor_ports <<< "$tor_ports_raw"

    local tor_port
    for tor_port in "${tor_ports[@]}"; do
        tor_port="${tor_port//[[:space:]]/}"
        [ -z "$tor_port" ] && continue

        if ! [[ "$tor_port" =~ ^[0-9]+$ ]] || [ "$tor_port" -lt 1 ] || [ "$tor_port" -gt 65535 ]; then
            log_warn "Skipping invalid Tor port: $tor_port"
            continue
        fi

        add_important_rule "Block Tor (port $tor_port)" \
            iptables -A OUTPUT -p tcp --dport "$tor_port" -j DROP
    done
    return 0
}

# Destroy the DoH block ipset and drop its persisted state. Safe to call when
# the set does not exist. Callers must flush/remove iptables rules that
# reference the set first (deactivate_firewall does).
destroy_doh_block_ipset() {
    rm -f "$OPENPATH_IPSET_STATE_FILE" 2>/dev/null || true
    openpath_ipset_available || return 0

    if ipset list "$OPENPATH_DOH_BLOCK_IPSET" >/dev/null 2>&1; then
        if ipset destroy "$OPENPATH_DOH_BLOCK_IPSET" 2>/dev/null; then
            log_debug "Destroyed DoH block ipset $OPENPATH_DOH_BLOCK_IPSET"
        else
            log_warn "Could not destroy DoH block ipset $OPENPATH_DOH_BLOCK_IPSET"
        fi
    fi
    return 0
}

# Persist the DoH block ipset next to the iptables snapshot so a restore of
# /etc/iptables/rules.v4 (which references the set) can recreate it first.
save_doh_block_ipset_state() {
    openpath_ipset_available || return 0

    if ipset list "$OPENPATH_DOH_BLOCK_IPSET" >/dev/null 2>&1; then
        if ipset save "$OPENPATH_DOH_BLOCK_IPSET" > "$OPENPATH_IPSET_STATE_FILE" 2>/dev/null; then
            log_debug "DoH block ipset state saved to $OPENPATH_IPSET_STATE_FILE"
        else
            log_warn "Could not save DoH block ipset state"
        fi
    else
        rm -f "$OPENPATH_IPSET_STATE_FILE" 2>/dev/null || true
    fi
    return 0
}
