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

    local doh_resolvers_raw="${DOH_RESOLVERS:-8.8.8.8,8.8.4.4,1.1.1.1,1.0.0.1,9.9.9.9,149.112.112.112,208.67.222.222,208.67.220.220,45.90.28.0,45.90.30.0,194.242.2.2,194.242.2.3,94.140.14.14,94.140.15.15,76.76.2.0,76.76.10.0}"
    local doh_resolvers=()
    IFS=',' read -r -a doh_resolvers <<< "$doh_resolvers_raw"

    for resolver_ip in "${doh_resolvers[@]}"; do
        resolver_ip="${resolver_ip//[[:space:]]/}"
        [ -z "$resolver_ip" ] && continue

        if ! validate_ip "$resolver_ip"; then
            log_warn "Skipping invalid DoH resolver IP: $resolver_ip"
            continue
        fi

        if [ "$resolver_ip" = "$PRIMARY_DNS" ]; then
            log_debug "Skipping DoH block for $resolver_ip (is upstream DNS)"
            continue
        fi

        add_important_rule "Block DoH resolver $resolver_ip (TCP/443)" \
            iptables -A OUTPUT -d "$resolver_ip" -p tcp --dport 443 -j DROP
        add_important_rule "Block DoH resolver $resolver_ip (UDP/443)" \
            iptables -A OUTPUT -d "$resolver_ip" -p udp --dport 443 -j DROP
    done

    local vpn_block_rules_raw="${VPN_BLOCK_RULES:-udp:1194:OpenVPN,tcp:1194:OpenVPN-TCP,udp:51820:WireGuard,tcp:1723:PPTP,udp:500:IKE,udp:4500:IPSec-NAT}"
    local vpn_block_rules=()
    IFS=',' read -r -a vpn_block_rules <<< "$vpn_block_rules_raw"

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

    local tor_ports_raw="${TOR_BLOCK_PORTS:-9001,9030,9050,9051,9150}"
    local tor_ports=()
    IFS=',' read -r -a tor_ports <<< "$tor_ports_raw"

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

    add_optional_rule "Allow ICMP (ping)" \
        iptables -A OUTPUT -p icmp -j ACCEPT
    add_optional_rule "Allow DHCP (ports 67-68)" \
        iptables -A OUTPUT -p udp --dport 67:68 -j ACCEPT
    add_optional_rule "Allow HTTP (port 80)" \
        iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
    add_optional_rule "Allow HTTPS (port 443)" \
        iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
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
