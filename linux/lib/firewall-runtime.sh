#!/bin/bash

################################################################################
# firewall-runtime.sh - Firewall activation, persistence, and cache helpers
################################################################################

activate_firewall() {
    log "Activating restrictive firewall..."

    local critical_failed=0

    if ! validate_ip "$PRIMARY_DNS"; then
        log_warn "Primary DNS '$PRIMARY_DNS' invalid - usando fallback"
        PRIMARY_DNS="${FALLBACK_DNS_PRIMARY:-8.8.8.8}"
    fi

    local gateway
    gateway=$(ip route | grep default | awk '{print $3}' | head -1)

    add_optional_rule "Flush OUTPUT chain" iptables -F OUTPUT

    # Make bridged guest-VM frames traverse netfilter so they cannot bypass the
    # host policy by bridging onto the LAN.
    apply_bridge_enforcement

    add_critical_rule "Allow loopback traffic" \
        iptables -A OUTPUT -o lo -j ACCEPT || critical_failed=1

    # VPN tunnel interfaces are dropped before the ESTABLISHED,RELATED accept
    # so that an already-connected tunnel cannot keep flowing.
    apply_vpn_interface_block_rules

    add_critical_rule "Allow established connections" \
        iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT || critical_failed=1
    add_critical_rule "Allow DNS to localhost (UDP)" \
        iptables -A OUTPUT -p udp -d 127.0.0.1 --dport 53 -j ACCEPT || critical_failed=1
    add_critical_rule "Allow DNS to localhost (TCP)" \
        iptables -A OUTPUT -p tcp -d 127.0.0.1 --dport 53 -j ACCEPT || critical_failed=1
    # Confine upstream :53 to the dnsmasq process so a student cannot query the
    # upstream resolver directly (dig @<upstream>). The gateway:53 allow is
    # intentionally gone (it let `dig @<gateway>` resolve unfiltered). Fall back
    # to an unconfined allow if owner-match is unavailable so dnsmasq's own
    # forwarding never breaks.
    if ! apply_upstream_dns_owner_rule "$PRIMARY_DNS"; then
        add_critical_rule "Allow DNS to upstream $PRIMARY_DNS (UDP)" \
            iptables -A OUTPUT -p udp -d "$PRIMARY_DNS" --dport 53 -j ACCEPT || critical_failed=1
        add_critical_rule "Allow DNS to upstream $PRIMARY_DNS (TCP)" \
            iptables -A OUTPUT -p tcp -d "$PRIMARY_DNS" --dport 53 -j ACCEPT || critical_failed=1
    fi

    add_important_rule "Log blocked external DNS attempts" \
        iptables -A OUTPUT -p udp --dport 53 -m limit --limit 5/min -j LOG --log-prefix "OPENPATH-DNS-DROP "
    add_important_rule "Block external DNS (UDP)" \
        iptables -A OUTPUT -p udp --dport 53 -j DROP
    add_important_rule "Block external DNS (TCP)" \
        iptables -A OUTPUT -p tcp --dport 53 -j DROP
    add_important_rule "Block DNS-over-TLS (port 853)" \
        iptables -A OUTPUT -p tcp --dport 853 -j DROP

    # Bypass-vector blocking (DoH ipset, VPN port catalog, Tor port catalog).
    # These DROP rules must precede the generic HTTP/HTTPS ACCEPT rules below.
    apply_doh_block_rules
    apply_vpn_port_block_rules
    apply_tor_block_rules

    # Name-aware egress: the allow set must exist before the match-set ACCEPT
    # rule (iptables rejects a rule that references a missing set) and before
    # dnsmasq loads its ipset= directives.
    ensure_allow_dst_ipset

    # ICMP echo-request scoped to the allow set (anti ping-tunnel); error types
    # (PMTUD/diagnostics) kept. Must follow ensure_allow_dst_ipset so the set
    # exists before the match-set rule references it.
    apply_icmp_egress_rules
    add_optional_rule "Allow DHCP (ports 67-68)" \
        iptables -A OUTPUT -p udp --dport 67:68 -j ACCEPT
    # HTTP/HTTPS and NTP scoped to resolved-whitelist IPs (or broad as fallback).
    apply_http_egress_rules
    apply_ntp_egress_rules
    # Intranet ranges (configurable allow-list; default = all RFC1918). Operators
    # can narrow RFC1918_ALLOW to shrink the LAN/tethered-proxy blast radius.
    apply_rfc1918_egress_rules

    add_optional_rule "Log dropped egress (detectability)" \
        iptables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "OPENPATH-EGRESS-DROP "
    add_critical_rule "Default deny (DROP all)" \
        iptables -A OUTPUT -j DROP || critical_failed=1

    # FORWARD default-deny: block bridged/guest-VM traffic from routing around
    # the host policy (forces hosted VMs onto host-routed NAT).
    apply_forward_default_deny

    # IPv6 egress firewall mirroring the v4 policy (closes the unfiltered-IPv6
    # bypass on dual-stack networks).
    apply_ipv6_firewall

    save_firewall_rules

    if [ "$critical_failed" -ne 0 ]; then
        log_error "CRITICAL: Some firewall rules failed to apply"
        log_error "System may not be properly protected"
        return 1
    fi

    if ! verify_firewall_rules; then
        log_error "Firewall verification failed after activation"
        return 1
    fi

    log "Restrictive firewall activated (DNS: $PRIMARY_DNS, GW: ${gateway:-none})"
    return 0
}

deactivate_firewall() {
    log "Deactivating firewall..."

    if ! iptables -F OUTPUT 2>/dev/null; then
        log_warn "Could not flush OUTPUT chain"
    fi

    if ! iptables -P OUTPUT ACCEPT 2>/dev/null; then
        log_warn "Could not set OUTPUT policy to ACCEPT"
    fi

    # Restore a permissive FORWARD chain (paired with apply_forward_default_deny).
    restore_forward_chain

    # Restore permissive IPv6 (paired with apply_ipv6_firewall).
    deactivate_ipv6_firewall

    # Bypass-block cleanup: the OUTPUT flush above removed every rule that
    # referenced the DoH ipset, so the set itself can be destroyed now.
    # Captive-portal passthrough, `openpath disable`, and uninstall all relax
    # the bypass blocks through this path.
    destroy_doh_block_ipset

    save_firewall_rules
    log "Firewall deactivated (permissive mode)"
}

save_firewall_rules() {
    if command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables 2>/dev/null
        if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
            log_debug "Firewall rules saved to /etc/iptables/rules.v4"
        else
            log_warn "Could not save firewall rules (iptables-save failed)"
        fi
        save_doh_block_ipset_state
    else
        log_debug "iptables-save not available, rules not persisted"
    fi
}

flush_connections() {
    if command -v conntrack >/dev/null 2>&1; then
        local flushed=0
        if conntrack -D -p tcp --dport 443 2>/dev/null; then
            flushed=$((flushed + 1))
        fi
        if conntrack -D -p tcp --dport 80 2>/dev/null; then
            flushed=$((flushed + 1))
        fi
        if [ "$flushed" -gt 0 ]; then
            log "HTTP/HTTPS connections flushed"
        else
            log_debug "No HTTP/HTTPS connections to flush"
        fi
    else
        log_warn "conntrack not available - connections not flushed"
    fi
}

flush_dns_cache() {
    if systemctl is-active --quiet dnsmasq; then
        if pkill -HUP dnsmasq 2>/dev/null; then
            log "DNS cache flushed"
        else
            log_warn "Could not send HUP to dnsmasq"
        fi
    else
        log_debug "dnsmasq not running, no cache to flush"
    fi
}
