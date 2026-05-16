#!/bin/bash

# Write a temporary dnsmasq config that forwards all queries upstream.
# Used for captive portal authentication (fail-open DNS passthrough).
# Args:
#   1) upstream DNS IP (required)
#   2) output path (optional; defaults to $DNSMASQ_CONF)
write_dnsmasq_passthrough_config() {
    local upstream_dns="$1"
    local conf_path="${2:-$DNSMASQ_CONF}"

    if [ -z "${upstream_dns:-}" ]; then
        log_warn "write_dnsmasq_passthrough_config: upstream DNS is empty"
        return 1
    fi

    cat > "$conf_path" << EOF
# OPENPATH PORTAL MODE - DNS passthrough (temporary)
no-resolv
resolv-file=/run/dnsmasq/resolv.conf
listen-address=127.0.0.1
bind-interfaces
cache-size=1000
server=$upstream_dns
EOF

    return 0
}

write_dnsmasq_default_sinkhole_rules() {
    local conf_path="$1"
    local sinkhole_ipv4="${OPENPATH_DNS_SINKHOLE_IPV4:-192.0.2.1}"
    local sinkhole_ipv6="${OPENPATH_DNS_SINKHOLE_IPV6:-100::}"

    if [ -z "${conf_path:-}" ]; then
        log_warn "write_dnsmasq_default_sinkhole_rules: output path is empty"
        return 1
    fi

    cat >> "$conf_path" <<EOF
address=/#/${sinkhole_ipv4}
address=/#/${sinkhole_ipv6}
EOF
}

# Generate dnsmasq configuration
generate_dnsmasq_config() {
    log "Generating dnsmasq configuration..."

    local temp_conf="${DNSMASQ_CONF}.tmp"
    local upstream_dns
    upstream_dns=$(select_usable_upstream_dns "${PRIMARY_DNS:-}")

    cat > "$temp_conf" << EOF
# =============================================
# OpenPath - dnsmasq DNS Sinkhole v$VERSION
# =============================================

# Base configuration
no-resolv
resolv-file=/run/dnsmasq/resolv.conf
listen-address=127.0.0.1
bind-interfaces
cache-size=1000
max-cache-ttl=300
neg-ttl=60

# =============================================
# DEFAULT BLOCK (MUST BE FIRST)
# Everything not explicitly listed returns a non-local sinkhole address.
# =============================================
EOF

    write_dnsmasq_default_sinkhole_rules "$temp_conf" || return 1

    cat >> "$temp_conf" << EOF
# =============================================
# ESSENTIAL DOMAINS (always allowed)
# Required for system operation
# =============================================

# Control plane and bootstrap/download
EOF

    local protected_domain
    while IFS= read -r protected_domain; do
        [ -z "$protected_domain" ] && continue
        echo "server=/${protected_domain}/${upstream_dns}" >> "$temp_conf"
    done < <(get_openpath_protected_domains)

    cat >> "$temp_conf" << EOF

# Captive portal detection
server=/detectportal.firefox.com/${upstream_dns}
server=/connectivity-check.ubuntu.com/${upstream_dns}
server=/captive.apple.com/${upstream_dns}
server=/www.msftconnecttest.com/${upstream_dns}
server=/clients3.google.com/${upstream_dns}

# NTP (time synchronization)
server=/ntp.ubuntu.com/${upstream_dns}
server=/time.google.com/${upstream_dns}

EOF

    {
        echo "# ============================================="
        echo "# WHITELIST DOMAINS (${#WHITELIST_DOMAINS[@]} domains)"
        echo "# ============================================="
    } >> "$temp_conf"

    local invalid_count=0
    for domain in "${WHITELIST_DOMAINS[@]}"; do
        if validate_domain "$domain"; then
            local safe_domain
            safe_domain=$(sanitize_domain "$domain")
            echo "server=/${safe_domain}/${upstream_dns}" >> "$temp_conf"
        else
            log_warn "Skipping invalid domain: $domain"
            invalid_count=$((invalid_count + 1))
        fi
    done

    if [ "$invalid_count" -gt 0 ]; then
        log_warn "Skipped $invalid_count invalid domains"
    fi

    echo "" >> "$temp_conf"

    if [ ${#BLOCKED_SUBDOMAINS[@]} -gt 0 ]; then
        echo "# Blocked subdomains (NXDOMAIN)" >> "$temp_conf"
        for blocked in "${BLOCKED_SUBDOMAINS[@]}"; do
            if validate_domain "$blocked"; then
                local safe_blocked
                safe_blocked=$(sanitize_domain "$blocked")
                echo "address=/${safe_blocked}/" >> "$temp_conf"
            else
                log_warn "Skipping invalid blocked subdomain: $blocked"
            fi
        done
        echo "" >> "$temp_conf"
    fi

    mv "$temp_conf" "$DNSMASQ_CONF"

    log "✓ dnsmasq configuration generated: ${#WHITELIST_DOMAINS[@]} domains + essentials"
}

# Validate dnsmasq configuration
validate_dnsmasq_config() {
    local output
    output=$(dnsmasq --test 2>&1)
    if echo "$output" | grep -qi "syntax check OK\|sintaxis correcta"; then
        return 0
    else
        log "ERROR: Invalid dnsmasq configuration: $output"
        return 1
    fi
}

# Restart dnsmasq
restart_dnsmasq() {
    log "Restarting dnsmasq..."

    if ! validate_dnsmasq_config; then
        return 1
    fi

    systemctl reset-failed dnsmasq 2>/dev/null || true
    if timeout 30 systemctl restart dnsmasq; then
        for _ in $(seq 1 5); do
            if systemctl is-active --quiet dnsmasq; then
                log "✓ dnsmasq restarted successfully"
                return 0
            fi
            sleep 1
        done
    fi

    log "ERROR: Failed to restart dnsmasq"
    return 1
}

# Verify DNS is working
verify_dns() {
    local probe_domain
    local probe_result

    probe_domain=$(select_allowed_dns_probe_domain)
    probe_result=$(resolve_local_dns_probe "$probe_domain")

    if dns_probe_result_is_public "$probe_result"; then
        return 0
    fi
    return 1
}
