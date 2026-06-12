#!/bin/bash

################################################################################
# firewall-snapshot.sh - Firewall snapshot and verification helpers
################################################################################

get_firewall_rules_snapshot() {
    local snapshot

    if snapshot=$(iptables -S OUTPUT 2>/dev/null) && [ -n "$snapshot" ]; then
        printf '%s\n' "$snapshot"
        return 0
    fi

    snapshot=$(iptables -L OUTPUT -n 2>/dev/null) || return 1
    printf '%s\n' "$snapshot"
    return 0
}

firewall_snapshot_is_canonical() {
    local snapshot="$1"
    printf '%s\n' "$snapshot" | grep -Eq -- '(^-P OUTPUT )|(^-A OUTPUT )'
}

firewall_snapshot_has_loopback_rule() {
    local snapshot="$1"

    if firewall_snapshot_is_canonical "$snapshot"; then
        printf '%s\n' "$snapshot" | grep -Eq -- '^-A OUTPUT([[:space:]].*)?[[:space:]]-o lo([[:space:]].*)?[[:space:]]-j ACCEPT$'
        return $?
    fi

    printf '%s\n' "$snapshot" | grep -Eq -- 'ACCEPT.*( lo($|[[:space:]])|/\*[[:space:]]*lo[[:space:]]*\*/)'
}

firewall_snapshot_has_localhost_dns_rule() {
    local snapshot="$1"

    if firewall_snapshot_is_canonical "$snapshot"; then
        printf '%s\n' "$snapshot" | grep -Eq -- '^-A OUTPUT([[:space:]].*)?[[:space:]]-d 127\.0\.0\.1(/32)?([[:space:]].*)?[[:space:]]--dport 53([[:space:]].*)?[[:space:]]-j ACCEPT$'
        return $?
    fi

    printf '%s\n' "$snapshot" | grep -Eq -- 'ACCEPT.*127\.0\.0\.1.*(dpt:53|dpt:domain)'
}

firewall_snapshot_dns_drop_rule_count() {
    local snapshot="$1"

    if firewall_snapshot_is_canonical "$snapshot"; then
        printf '%s\n' "$snapshot" | grep -Ec -- '^-A OUTPUT([[:space:]].*)?[[:space:]]--dport 53([[:space:]].*)?[[:space:]]-j DROP$'
        return 0
    fi

    printf '%s\n' "$snapshot" | grep -Ec -- 'DROP.*(dpt:53|dpt:domain)'
}

firewall_snapshot_has_final_drop_rule() {
    local snapshot="$1"

    if firewall_snapshot_is_canonical "$snapshot"; then
        printf '%s\n' "$snapshot" | grep -Eq -- '^-A OUTPUT -j DROP$'
        return $?
    fi

    printf '%s\n' "$snapshot" | grep -Eq -- 'DROP.*(anywhere|0\.0\.0\.0/0).*(anywhere|0\.0\.0\.0/0)'
}

firewall_snapshot_has_port_drop_rule() {
    local snapshot="$1"
    local proto="$2"
    local port="$3"

    if firewall_snapshot_is_canonical "$snapshot"; then
        printf '%s\n' "$snapshot" | grep -Eq -- "^-A OUTPUT([[:space:]].*)?[[:space:]]-p $proto([[:space:]].*)?[[:space:]]--dport $port([[:space:]].*)?[[:space:]]-j DROP$"
        return $?
    fi

    printf '%s\n' "$snapshot" | grep -Eq -- "DROP[[:space:]]+${proto}[[:space:]].*dpt:${port}([[:space:]]|$)"
}

# True when a DoH bypass-block rule is present: either the ipset-backed rule
# (-m set --match-set ... dst, dport 443) or a per-IP fallback (-d <ip>,
# dport 443).
firewall_snapshot_has_doh_block_rule() {
    local snapshot="$1"

    if firewall_snapshot_is_canonical "$snapshot"; then
        printf '%s\n' "$snapshot" \
            | grep -E -- '^-A OUTPUT[[:space:]].*-j DROP$' \
            | grep -E -- '--dport 443([[:space:]]|$)' \
            | grep -Eq -- '(--match-set[[:space:]]|-d[[:space:]])'
        return $?
    fi

    printf '%s\n' "$snapshot" | grep -Eq -- 'DROP.*(match-set|dpt:443)'
}

# True when an interface-scoped VPN block rule (-o tun+/tap+/...) is present.
# Only detectable from canonical `iptables -S` output; `iptables -L` without
# -v omits interfaces.
firewall_snapshot_has_vpn_interface_block_rule() {
    local snapshot="$1"

    if firewall_snapshot_is_canonical "$snapshot"; then
        printf '%s\n' "$snapshot" | grep -Eq -- '^-A OUTPUT([[:space:]].*)?[[:space:]]-o [[:alnum:]._+-]+([[:space:]].*)?[[:space:]]-j DROP$'
        return $?
    fi

    return 1
}

has_firewall_loopback_rule() {
    local snapshot
    snapshot=$(get_firewall_rules_snapshot) || return 1
    firewall_snapshot_has_loopback_rule "$snapshot"
}

# Bypass-block status checks. Each echoes one of:
#   "disabled" - switched off via configuration (return 0)
#   "active"   - expected rules present (return 0)
#   "inactive" - expected rules missing (return 1)
check_doh_block_status() {
    if ! doh_block_enabled; then
        echo "disabled"
        return 0
    fi

    local snapshot
    if ! snapshot=$(get_firewall_rules_snapshot 2>/dev/null); then
        echo "inactive"
        return 1
    fi

    if firewall_snapshot_has_doh_block_rule "$snapshot"; then
        echo "active"
        return 0
    fi

    echo "inactive"
    return 1
}

check_vpn_block_status() {
    if ! vpn_block_enabled; then
        echo "disabled"
        return 0
    fi

    local snapshot
    if ! snapshot=$(get_firewall_rules_snapshot 2>/dev/null); then
        echo "inactive"
        return 1
    fi

    local vpn_block_rules_raw="${VPN_BLOCK_RULES:-$(openpath_default_vpn_block_rules)}"
    local vpn_block_rules=()
    IFS=',' read -r -a vpn_block_rules <<< "$vpn_block_rules_raw"

    local vpn_rule vpn_protocol vpn_port
    for vpn_rule in "${vpn_block_rules[@]}"; do
        vpn_rule="${vpn_rule//[[:space:]]/}"
        [ -z "$vpn_rule" ] && continue

        IFS=':' read -r vpn_protocol vpn_port _ <<< "$vpn_rule"
        vpn_protocol="$(printf '%s' "$vpn_protocol" | tr '[:upper:]' '[:lower:]')"
        if [ "$vpn_protocol" != "tcp" ] && [ "$vpn_protocol" != "udp" ]; then
            continue
        fi
        [[ "$vpn_port" =~ ^[0-9]+$ ]] || continue

        if ! firewall_snapshot_has_port_drop_rule "$snapshot" "$vpn_protocol" "$vpn_port"; then
            echo "inactive"
            return 1
        fi
    done

    if firewall_snapshot_is_canonical "$snapshot" \
        && ! firewall_snapshot_has_vpn_interface_block_rule "$snapshot"; then
        echo "inactive"
        return 1
    fi

    echo "active"
    return 0
}

check_tor_block_status() {
    if ! tor_block_enabled; then
        echo "disabled"
        return 0
    fi

    local snapshot
    if ! snapshot=$(get_firewall_rules_snapshot 2>/dev/null); then
        echo "inactive"
        return 1
    fi

    local tor_ports_raw="${TOR_BLOCK_PORTS:-$(openpath_default_tor_block_ports)}"
    local tor_ports=()
    IFS=',' read -r -a tor_ports <<< "$tor_ports_raw"

    local tor_port
    for tor_port in "${tor_ports[@]}"; do
        tor_port="${tor_port//[[:space:]]/}"
        [ -z "$tor_port" ] && continue
        [[ "$tor_port" =~ ^[0-9]+$ ]] || continue

        if ! firewall_snapshot_has_port_drop_rule "$snapshot" "tcp" "$tor_port"; then
            echo "inactive"
            return 1
        fi
    done

    echo "active"
    return 0
}

verify_firewall_rules() {
    local firewall_output
    firewall_output=$(get_firewall_rules_snapshot) || {
        log_error "Cannot read firewall rules"
        return 1
    }

    local missing=0

    if ! firewall_snapshot_has_loopback_rule "$firewall_output"; then
        log_warn "Missing firewall rule: loopback accept"
        missing=$((missing + 1))
    fi

    if ! firewall_snapshot_has_localhost_dns_rule "$firewall_output"; then
        log_warn "Missing firewall rule: localhost DNS accept"
        missing=$((missing + 1))
    fi

    local drop_count
    drop_count=$(firewall_snapshot_dns_drop_rule_count "$firewall_output") || drop_count=0
    if [ "$drop_count" -lt 2 ]; then
        log_warn "Missing firewall rule: DNS DROP (found $drop_count, need 2)"
        missing=$((missing + 1))
    fi

    if ! firewall_snapshot_has_final_drop_rule "$firewall_output"; then
        log_warn "Missing firewall rule: final DROP (default deny)"
        missing=$((missing + 1))
    fi

    # Bypass-block rules are reported but non-fatal: they are applied with
    # add_important_rule and must not hard-fail activation on kernels without
    # ipset/match support.
    if doh_block_enabled && ! firewall_snapshot_has_doh_block_rule "$firewall_output"; then
        log_warn "Bypass-block rule missing: DoH resolver block (:443)"
    fi

    if vpn_block_enabled && firewall_snapshot_is_canonical "$firewall_output" \
        && ! firewall_snapshot_has_vpn_interface_block_rule "$firewall_output"; then
        log_warn "Bypass-block rule missing: VPN interface block (${VPN_BLOCK_INTERFACES:-tun+,tap+})"
    fi

    if [ "$missing" -gt 0 ]; then
        log_error "Firewall verification failed: $missing critical rules missing"
        return 1
    fi

    log_debug "Firewall verification passed"
    return 0
}

check_firewall_status() {
    local snapshot
    local rules

    snapshot=$(get_firewall_rules_snapshot 2>/dev/null) || {
        echo "inactive"
        return 1
    }

    rules=$(firewall_snapshot_dns_drop_rule_count "$snapshot")
    if [ "$rules" -ge 2 ]; then
        echo "active"
        return 0
    fi

    echo "inactive"
    return 1
}
