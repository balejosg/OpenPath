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
    add_critical_rule "Allow DNS to upstream $PRIMARY_DNS (UDP)" \
        iptables -A OUTPUT -p udp -d "$PRIMARY_DNS" --dport 53 -j ACCEPT || critical_failed=1
    add_critical_rule "Allow DNS to upstream $PRIMARY_DNS (TCP)" \
        iptables -A OUTPUT -p tcp -d "$PRIMARY_DNS" --dport 53 -j ACCEPT || critical_failed=1

    if [ -n "$gateway" ] && [ "$gateway" != "$PRIMARY_DNS" ]; then
        add_optional_rule "Allow DNS to gateway $gateway (UDP)" \
            iptables -A OUTPUT -p udp -d "$gateway" --dport 53 -j ACCEPT
        add_optional_rule "Allow DNS to gateway $gateway (TCP)" \
            iptables -A OUTPUT -p tcp -d "$gateway" --dport 53 -j ACCEPT
    fi

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

    add_optional_rule "Allow ICMP (ping)" \
        iptables -A OUTPUT -p icmp -j ACCEPT
    add_optional_rule "Allow DHCP (ports 67-68)" \
        iptables -A OUTPUT -p udp --dport 67:68 -j ACCEPT
    # HTTP/HTTPS scoped to resolved-whitelist IPs (or broad ACCEPT as fallback).
    apply_http_egress_rules
    add_optional_rule "Allow NTP (port 123)" \
        iptables -A OUTPUT -p udp --dport 123 -j ACCEPT
    add_optional_rule "Allow private network 10.0.0.0/8" \
        iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
    add_optional_rule "Allow private network 172.16.0.0/12" \
        iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
    add_optional_rule "Allow private network 192.168.0.0/16" \
        iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT

    add_critical_rule "Default deny (DROP all)" \
        iptables -A OUTPUT -j DROP || critical_failed=1

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
