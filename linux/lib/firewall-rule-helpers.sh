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
OPENPATH_ALLOW_DST_IPSET6="${OPENPATH_ALLOW_DST_IPSET6:-openpath-allow-dst6}"

# Non-local sinkhole addresses the dnsmasq default-deny resolves blocked domains
# to (kept in sync with OPENPATH_DNS_SINKHOLE_IPV4/IPV6 in dns-dnsmasq.sh). The
# fast-fail REJECT targets exactly these, so a blocked-domain connection is reset
# instantly instead of black-holing at the default DROP.
OPENPATH_DNS_SINKHOLE_IPV4="${OPENPATH_DNS_SINKHOLE_IPV4:-192.0.2.1}"
OPENPATH_DNS_SINKHOLE_IPV6="${OPENPATH_DNS_SINKHOLE_IPV6:-100::}"
# Entries in the egress allow set must not outlive the DNS answer that put a
# shared CDN IP there: dnsmasq caps cached answers at max-cache-ttl=300s
# (dns-dnsmasq.sh), so the allow-set timeout is aligned to <= that value. A
# longer timeout (the previous 600s default) widened the window in which a
# recycled/shared IP that has stopped resolving for an allowed domain stays
# reachable for whatever now answers on it. Residual: IP-layer scoping cannot
# distinguish two names that share one IP (domain-fronting on a shared front),
# so timeout-alignment only shrinks the reuse window, it does not close it.
OPENPATH_ALLOW_SET_TIMEOUT="${OPENPATH_ALLOW_SET_TIMEOUT:-300}"

ipv6_firewall_enabled() { openpath_flag_enabled "${IPV6_FIREWALL_ENABLED:-1}"; }
ip6tables_available() { command -v ip6tables >/dev/null 2>&1; }

# IPv6 egress is filtered only when enabled AND ip6tables is usable; otherwise
# IPv6 is left to the (inert) dnsmasq v6 sinkhole, which is the pre-existing gap.
ipv6_firewall_active() { ipv6_firewall_enabled && ip6tables_available; }

# True when the IPv6 name-aware allow set can be used (v6 firewall active, the
# allow-set feature enabled, and ipset available to populate it).
ipv6_allow_set_active() {
    ipv6_firewall_active && allow_set_egress_enabled && openpath_ipset_available
}

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

# Surface (but do not "fix") a security-relevant enum env var set to an
# unrecognized value, so a typo such as RFC1918_EGRESS_MODE=restrict does not
# silently no-op an intended hardening and leave the operator believing it took
# effect. Deliberately does NOT change the value or the caller's fail direction
# -- the existing default semantics still apply; this only logs the mismatch.
# $1=var name (for the message), $2=raw value, $3=comma-separated allowed values.
openpath_warn_unknown_enum() {
    local name="$1" value="$2" allowed="$3" lowered
    [ -z "$value" ] && return 0
    lowered="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    case ",$allowed," in
        *",$lowered,"*) return 0 ;;
    esac
    log_warn "Unknown value '$value' for $name; expected one of: ${allowed//,/, }. Using default behaviour."
    return 0
}

doh_block_enabled() { openpath_flag_enabled "${DOH_BLOCK_ENABLED:-1}"; }
vpn_block_enabled() { openpath_flag_enabled "${VPN_BLOCK_ENABLED:-1}"; }
tor_block_enabled() { openpath_flag_enabled "${TOR_BLOCK_ENABLED:-1}"; }

# Blocked domains resolve to a non-local sinkhole IP that the default DROP then
# black-holes, so a browser hangs the full TCP connect timeout (~90s) on every
# blocked sub-resource of an allowed page. When enabled, the firewall sends a TCP
# reset for connections to the sinkhole IP (instant "connection refused") and the
# DNS layer drops the v6 sinkhole answer when no IPv6 firewall can reset it.
# SECURITY: the reset is scoped to the (already obviously-fake, non-routable)
# sinkhole IP only, so it reveals nothing about which real destinations are
# filtered (those still hit the silent DROP), never permits egress (it refuses),
# and keeps the non-local sinkhole. Off by default; enable after WEDU/Docker
# validation. Override: OPENPATH_SINKHOLE_FAST_FAIL.
sinkhole_fast_fail_enabled() { openpath_flag_enabled "${SINKHOLE_FAST_FAIL:-0}"; }

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
    if ipv6_firewall_active; then
        add_important_rule "Create egress allow ipset $OPENPATH_ALLOW_DST_IPSET6 (inet6)" \
            ipset create "$OPENPATH_ALLOW_DST_IPSET6" hash:ip family inet6 timeout "$OPENPATH_ALLOW_SET_TIMEOUT" -exist
    fi
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

# Intranet egress mode. "all" (default, legacy) ACCEPTs every RFC1918 CIDR on
# ALL ports; that is a full tunnel through any LAN/USB-tethered box running a
# proxy (a tethered phone presents a fresh RFC1918 interface). "restricted"
# (RECOMMENDED, opt-in via defaults.conf / OPENPATH_RFC1918_EGRESS_MODE) scopes
# the intranet ACCEPT to RFC1918_ALLOW_PORTS only (the minimal set a local
# gateway/captive-portal flow legitimately needs), so a LAN proxy on an arbitrary
# high port is no longer a tunnel. It is not the default because some deployments
# reach services over RFC1918 on non-standard ports; widen RFC1918_ALLOW_PORTS to
# fit, then enable. SECURITY: "all" leaves the tethered-proxy full-tunnel hole
# open -- prefer "restricted" once the deployment's RFC1918 port needs are known.
rfc1918_egress_mode() {
    local raw="${RFC1918_EGRESS_MODE:-all}"
    openpath_warn_unknown_enum "RFC1918_EGRESS_MODE" "$raw" "all,restricted"
    printf '%s' "$raw" | tr '[:upper:]' '[:lower:]'
}

# Intranet egress. Allow a configurable list of private/intranet CIDRs (default:
# all RFC1918). Operators can narrow RFC1918_ALLOW to the specific ranges their
# deployment needs, shrinking the LAN/USB-tethered-proxy blast radius. In
# "restricted" mode the per-CIDR ACCEPT is further port-scoped to
# RFC1918_ALLOW_PORTS so a LAN/tethered proxy on an arbitrary port is not a
# full tunnel.
apply_rfc1918_egress_rules() {
    local ranges_raw="${RFC1918_ALLOW:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
    local ranges=()
    IFS=',' read -r -a ranges <<< "$ranges_raw"

    local mode
    mode="$(rfc1918_egress_mode)"

    local -a ports=()
    if [ "$mode" = "restricted" ]; then
        # Minimal set a local gateway / captive-portal flow needs: DNS to a LAN
        # resolver (53), local web/portal (80/443), DHCP is already handled
        # globally elsewhere. NTP/other LAN services can be added via
        # RFC1918_ALLOW_PORTS if a deployment requires them.
        local ports_raw="${RFC1918_ALLOW_PORTS:-53,80,443}"
        IFS=',' read -r -a ports <<< "$ports_raw"
    fi

    local cidr
    for cidr in "${ranges[@]}"; do
        cidr="${cidr//[[:space:]]/}"
        [ -z "$cidr" ] && continue

        if [ "$mode" = "restricted" ]; then
            local port proto
            for port in "${ports[@]}"; do
                port="${port//[[:space:]]/}"
                [ -z "$port" ] && continue
                if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                    log_warn "Skipping invalid RFC1918 allow port: $port"
                    continue
                fi
                for proto in tcp udp; do
                    add_optional_rule "Allow intranet $cidr ($proto/$port)" \
                        iptables -A OUTPUT -d "$cidr" -p "$proto" --dport "$port" -j ACCEPT
                done
            done
        else
            add_optional_rule "Allow intranet $cidr" \
                iptables -A OUTPUT -d "$cidr" -j ACCEPT
        fi
    done
}

# ICMP egress. The previous rule ACCEPTed all ICMP to any destination, which is
# a covert channel (ping-tunnel: data smuggled in echo-request payloads to an
# arbitrary host). Scope echo-request to the resolved-whitelist allow set when
# name-aware egress is active, so a student can only ping IPs an allowed domain
# resolved to; keep the error types that path MTU discovery and connectivity
# diagnostics depend on (destination-unreachable carries the PMTUD "frag needed"
# message; time-exceeded is traceroute/TTL). Falls back to a broad ICMP ACCEPT
# when name-aware egress is unavailable so connectivity is never lost on kernels
# without ipset.
apply_icmp_egress_rules() {
    if allow_set_egress_active; then
        add_optional_rule "Allow ICMP echo-request to resolved-whitelist IPs" \
            iptables -A OUTPUT -p icmp --icmp-type echo-request -m set --match-set "$OPENPATH_ALLOW_DST_IPSET" dst -j ACCEPT
        # PMTUD and diagnostics: keep the error/reply types regardless of dest.
        add_optional_rule "Allow ICMP destination-unreachable (PMTUD)" \
            iptables -A OUTPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
        add_optional_rule "Allow ICMP time-exceeded" \
            iptables -A OUTPUT -p icmp --icmp-type time-exceeded -j ACCEPT
        add_optional_rule "Allow ICMP echo-reply" \
            iptables -A OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT
        return 0
    fi

    log_warn "Name-aware egress inactive (ipset unavailable or disabled) - allowing broad ICMP"
    add_optional_rule "Allow ICMP (ping)" \
        iptables -A OUTPUT -p icmp -j ACCEPT
}

# Fast-fail for blocked domains (UX). Send a TCP reset for connections to the
# non-local IPv4 sinkhole so a browser gets an instant "connection refused"
# instead of hanging the full connect timeout at the default DROP. Inserted
# before the final OUTPUT DROP in activate_firewall. Scoped strictly to the
# sinkhole IP: real/direct-IP egress still hits the silent DROP (stealth
# preserved), the reset never permits egress, and the non-local sinkhole is
# unchanged. Best-effort (add_optional_rule): a kernel without the REJECT target
# degrades to the current DROP/hang, never to a leak. No-op unless enabled.
apply_sinkhole_fast_fail_rules() {
    sinkhole_fast_fail_enabled || return 0
    add_optional_rule "Fast-fail blocked domains (RST to v4 sinkhole $OPENPATH_DNS_SINKHOLE_IPV4)" \
        iptables -A OUTPUT -d "$OPENPATH_DNS_SINKHOLE_IPV4" -p tcp -j REJECT --reject-with tcp-reset
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

# Resolve the uid dnsmasq drops to, so upstream :53 can be confined to it.
# Honors OPENPATH_DNSMASQ_UID (tests/operators), then a user= directive in the
# generated config, then the conventional 'dnsmasq' account. Empty when it
# cannot be resolved (caller leaves upstream :53 unconfined).
resolve_dnsmasq_uid() {
    if [ -n "${OPENPATH_DNSMASQ_UID:-}" ]; then
        printf '%s' "$OPENPATH_DNSMASQ_UID"
        return 0
    fi
    local user="dnsmasq" cfg_user=""
    if [ -f "${DNSMASQ_CONF:-}" ]; then
        cfg_user=$(grep -E '^[[:space:]]*user=' "$DNSMASQ_CONF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
        [ -n "$cfg_user" ] && user="$cfg_user"
    fi
    id -u "$user" 2>/dev/null || true
}

# Allow upstream DNS :53 only from the dnsmasq process, so a student cannot query
# the upstream resolver directly (dig @<upstream>) to get unfiltered answers; all
# other :53 to the upstream falls through to the DROP rules. Returns 0 when the
# owner-scoped rules were applied, 1 when owner-match is unavailable (caller must
# fall back to an unconfined allow so dnsmasq's own forwarding never breaks).
apply_upstream_dns_owner_rule() {
    local upstream="$1"
    local uid
    uid=$(resolve_dnsmasq_uid)
    [ -n "$uid" ] || { log_warn "dnsmasq uid unresolved - upstream :53 left unconfined"; return 1; }

    if iptables -A OUTPUT -p udp -d "$upstream" --dport 53 -m owner --uid-owner "$uid" -j ACCEPT 2>/dev/null; then
        iptables -A OUTPUT -p tcp -d "$upstream" --dport 53 -m owner --uid-owner "$uid" -j ACCEPT 2>/dev/null || true
        log_debug "Upstream DNS :53 confined to dnsmasq uid $uid"
        return 0
    fi

    log_warn "owner-match unavailable - upstream :53 left unconfined"
    return 1
}

# IPv6 egress firewall mirroring the v4 OUTPUT/FORWARD policy. Without this,
# IPv6 was completely unfiltered (no ip6tables rules) while the dnsmasq v6
# sinkhole was inert, so a student on a dual-stack network could resolve via a
# public v6 resolver or use a v6 literal and reach anything. Clients resolve
# over the v4 localhost sinkhole (which returns AAAA records added to the v6
# allow set), so all v6 :53 is dropped here. ICMPv6 (NDP/RA) must stay allowed.
apply_ipv6_firewall() {
    if ! ipv6_firewall_active; then
        ipv6_firewall_enabled && log_warn "ip6tables unavailable - IPv6 egress NOT filtered"
        return 0
    fi

    add_optional_rule "Flush IPv6 OUTPUT chain" ip6tables -F OUTPUT
    add_critical_rule "IPv6 allow loopback" \
        ip6tables -A OUTPUT -o lo -j ACCEPT
    add_critical_rule "IPv6 allow established" \
        ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # NDP/RA/MLD control messages must stay (v6 is non-functional without them):
    # neighbour/router solicit+advert and redirect. echo-request (covert
    # ping-tunnel) is handled separately below so it can be scoped to the allow
    # set rather than blanket-accepted.
    local icmp6_type
    for icmp6_type in destination-unreachable packet-too-big time-exceeded parameter-problem \
        router-solicitation router-advertisement neighbour-solicitation neighbour-advertisement redirect; do
        add_optional_rule "IPv6 allow ICMPv6 ${icmp6_type} (NDP/RA/PMTUD)" \
            ip6tables -A OUTPUT -p ipv6-icmp --icmpv6-type "$icmp6_type" -j ACCEPT
    done
    if ipv6_allow_set_active; then
        add_optional_rule "IPv6 allow ICMPv6 echo-request to resolved-whitelist" \
            ip6tables -A OUTPUT -p ipv6-icmp --icmpv6-type echo-request -m set --match-set "$OPENPATH_ALLOW_DST_IPSET6" dst -j ACCEPT
        add_optional_rule "IPv6 allow ICMPv6 echo-reply" \
            ip6tables -A OUTPUT -p ipv6-icmp --icmpv6-type echo-reply -j ACCEPT
    else
        # No allow set to scope against: keep echo open so connectivity checks
        # still work in the degraded path.
        add_optional_rule "IPv6 allow ICMPv6 echo-request (broad fallback)" \
            ip6tables -A OUTPUT -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
    fi
    add_optional_rule "IPv6 allow DHCPv6" \
        ip6tables -A OUTPUT -p udp --dport 546:547 -j ACCEPT

    # No local v6 resolver (dnsmasq listens on 127.0.0.1 only): drop all v6 DNS
    # so clients fall back to the v4 localhost sinkhole.
    add_important_rule "IPv6 block DNS (UDP)" \
        ip6tables -A OUTPUT -p udp --dport 53 -j DROP
    add_important_rule "IPv6 block DNS (TCP)" \
        ip6tables -A OUTPUT -p tcp --dport 53 -j DROP
    add_important_rule "IPv6 block DNS-over-TLS" \
        ip6tables -A OUTPUT -p tcp --dport 853 -j DROP

    if ipv6_allow_set_active; then
        add_important_rule "IPv6 allow HTTP to resolved-whitelist (80)" \
            ip6tables -A OUTPUT -p tcp --dport 80 -m set --match-set "$OPENPATH_ALLOW_DST_IPSET6" dst -j ACCEPT
        add_important_rule "IPv6 allow HTTPS to resolved-whitelist (443)" \
            ip6tables -A OUTPUT -p tcp --dport 443 -m set --match-set "$OPENPATH_ALLOW_DST_IPSET6" dst -j ACCEPT
        add_important_rule "IPv6 allow NTP to resolved-whitelist (123)" \
            ip6tables -A OUTPUT -p udp --dport 123 -m set --match-set "$OPENPATH_ALLOW_DST_IPSET6" dst -j ACCEPT
    else
        log_warn "IPv6 name-aware egress unavailable (ipset) - allowing broad IPv6 HTTP/HTTPS"
        add_optional_rule "IPv6 allow HTTP (80)" ip6tables -A OUTPUT -p tcp --dport 80 -j ACCEPT
        add_optional_rule "IPv6 allow HTTPS (443)" ip6tables -A OUTPUT -p tcp --dport 443 -j ACCEPT
    fi

    # Fast-fail blocked domains on v6: RST to the v6 sinkhole so a dual-stack
    # client (Happy Eyeballs) fails the v6 limb instantly instead of black-holing
    # at the default DROP. Scoped to the sinkhole IP; must precede the DROP.
    if sinkhole_fast_fail_enabled; then
        add_optional_rule "Fast-fail blocked domains (RST to v6 sinkhole $OPENPATH_DNS_SINKHOLE_IPV6)" \
            ip6tables -A OUTPUT -d "$OPENPATH_DNS_SINKHOLE_IPV6" -p tcp -j REJECT --reject-with tcp-reset
    fi

    add_optional_rule "IPv6 log dropped egress (detectability)" \
        ip6tables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "OPENPATH-EGRESS6-DROP "
    add_critical_rule "IPv6 default deny (DROP all)" \
        ip6tables -A OUTPUT -j DROP

    # FORWARD mirror so a bridged guest VM cannot route v6 around the host.
    if bridge_enforcement_enabled; then
        ip6tables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        add_important_rule "IPv6 FORWARD allow established" \
            ip6tables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
        add_critical_rule "IPv6 FORWARD default deny" \
            ip6tables -P FORWARD DROP
    fi
    return 0
}

# Restore a permissive IPv6 firewall on deactivation/uninstall.
deactivate_ipv6_firewall() {
    ip6tables_available || return 0
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
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
