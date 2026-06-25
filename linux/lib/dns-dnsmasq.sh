#!/bin/bash

# Forward a domain to the upstream resolver and, when name-aware egress is
# enabled, register its resolved IPs into the firewall allow ipset
# (openpath-allow-dst) via dnsmasq's ipset= directive, so the host can actually
# connect to them on 80/443. Mirrors apply_http_egress_rules
# (firewall-rule-helpers.sh). Self-contained: falls back to the default set name
# when firewall-rule-helpers.sh is not sourced.
emit_dnsmasq_allow_domain() {
    local domain="$1" upstream="$2" conf="$3"
    printf 'server=/%s/%s\n' "$domain" "$upstream" >> "$conf"
    case "$(printf '%s' "${ALLOW_SET_EGRESS_ENABLED:-1}" | tr '[:upper:]' '[:lower:]')" in
        0 | false | no | off | disabled) return 0 ;;
    esac
    # Add resolved IPv4 to the v4 allow set, and AAAA to the v6 set when the IPv6
    # firewall is enabled (dnsmasq routes each address to the matching family).
    local sets="${OPENPATH_ALLOW_DST_IPSET:-openpath-allow-dst}"
    case "$(printf '%s' "${IPV6_FIREWALL_ENABLED:-1}" | tr '[:upper:]' '[:lower:]')" in
        0 | false | no | off | disabled) ;;
        *) sets="${sets},${OPENPATH_ALLOW_DST_IPSET6:-openpath-allow-dst6}" ;;
    esac
    printf 'ipset=/%s/%s\n' "$domain" "$sets" >> "$conf"
}

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

# Write a restricted dnsmasq config that only forwards critical domains upstream.
# All other queries remain sinkholed. Used by the watchdog protected-mode path.
# Args:
#   1) upstream DNS IP (required)
#   2) output path (optional; defaults to $DNSMASQ_CONF)
write_dnsmasq_protected_mode_config() {
    local upstream_dns="$1"
    local conf_path="${2:-$DNSMASQ_CONF}"
    local sinkhole_ipv4="${OPENPATH_DNS_SINKHOLE_IPV4:-192.0.2.1}"
    local sinkhole_ipv6="${OPENPATH_DNS_SINKHOLE_IPV6:-100::}"

    if [ -z "${upstream_dns:-}" ]; then
        log_warn "write_dnsmasq_protected_mode_config: upstream DNS is empty"
        return 1
    fi

    local temp_conf="${conf_path}.protected-mode.tmp"

    cat > "$temp_conf" << EOF
# OPENPATH PROTECTED MODE - critical-domains only (watchdog threshold reached)
no-resolv
resolv-file=/run/dnsmasq/resolv.conf
listen-address=127.0.0.1
bind-interfaces
cache-size=1000

# DEFAULT BLOCK — everything not in the critical list is sinkholed
address=/#/${sinkhole_ipv4}
EOF

    # IPv6 default-deny answer: same fast-fail gating as the main sinkhole config
    # (omit 100:: so a blocked AAAA returns no address when no active IPv6 firewall
    # can reset it), so a tampered endpoint in protected mode does not hang on a v6
    # sinkhole either.
    if _dns_emit_blocked_aaaa_sinkhole; then
        printf 'address=/#/%s\n' "$sinkhole_ipv6" >> "$temp_conf"
    fi

    cat >> "$temp_conf" << 'EOF'

# CRITICAL DOMAINS — control plane, captive portal probes, OS/system
EOF

    local protected_domain
    while IFS= read -r protected_domain; do
        [ -z "$protected_domain" ] && continue
        emit_dnsmasq_allow_domain "$protected_domain" "$upstream_dns" "$temp_conf"
    done < <(get_openpath_protected_domains)

    mv "$temp_conf" "$conf_path"
    return 0
}

# Whether the blocked-domain IPv6 sinkhole answer (address=/#/<v6>) should be
# written. Default: yes (unchanged). Under SINKHOLE_FAST_FAIL it is written only
# when an active IPv6 firewall (ip6tables present + IPV6_FIREWALL_ENABLED) will
# RST connections to the v6 sinkhole; otherwise it is omitted so a blocked domain
# returns no AAAA address (dnsmasq answers REFUSED for the v4-only wildcard) and a
# dual-stack client (Happy Eyeballs) falls straight to the fast-failing IPv4
# sinkhole instead of black-holing on a v6 sinkhole nothing resets. Omitting
# it leaks nothing: the v6 fail-closed boundary is the ip6tables firewall, not
# this (inert) DNS answer. Self-contained env checks, since firewall-rule-helpers.sh
# may not be sourced in the DNS-generation context.
_dns_emit_blocked_aaaa_sinkhole() {
    case "$(printf '%s' "${SINKHOLE_FAST_FAIL:-1}" | tr '[:upper:]' '[:lower:]')" in
        '' | 0 | false | no | off | disabled) return 0 ;;
    esac
    case "$(printf '%s' "${IPV6_FIREWALL_ENABLED:-1}" | tr '[:upper:]' '[:lower:]')" in
        0 | false | no | off | disabled) return 1 ;;
    esac
    command -v ip6tables >/dev/null 2>&1
}

write_dnsmasq_default_sinkhole_rules() {
    local conf_path="$1"
    local sinkhole_ipv4="${OPENPATH_DNS_SINKHOLE_IPV4:-192.0.2.1}"
    local sinkhole_ipv6="${OPENPATH_DNS_SINKHOLE_IPV6:-100::}"

    if [ -z "${conf_path:-}" ]; then
        log_warn "write_dnsmasq_default_sinkhole_rules: output path is empty"
        return 1
    fi

    # IPv4 sinkhole first (Critical Contract: sinkhole before server= allows).
    printf 'address=/#/%s\n' "$sinkhole_ipv4" >> "$conf_path"
    if _dns_emit_blocked_aaaa_sinkhole; then
        printf 'address=/#/%s\n' "$sinkhole_ipv6" >> "$conf_path"
    fi
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

# Control plane, browser updates, and bootstrap/download
EOF

    local protected_domain
    while IFS= read -r protected_domain; do
        [ -z "$protected_domain" ] && continue
        emit_dnsmasq_allow_domain "$protected_domain" "$upstream_dns" "$temp_conf"
    done < <(get_openpath_protected_domains)

    # Captive portal probes are reached over HTTP/80, so they must land in the
    # egress allow set too (emit_dnsmasq_allow_domain adds the ipset= directive).
    echo "" >> "$temp_conf"
    echo "# Captive portal detection" >> "$temp_conf"
    local captive_probe_domain
    for captive_probe_domain in \
        detectportal.firefox.com \
        connectivity-check.ubuntu.com \
        captive.apple.com \
        www.msftconnecttest.com \
        clients3.google.com; do
        emit_dnsmasq_allow_domain "$captive_probe_domain" "$upstream_dns" "$temp_conf"
    done

    echo "" >> "$temp_conf"
    echo "# NTP (time synchronization)" >> "$temp_conf"
    local ntp_domain
    for ntp_domain in ntp.ubuntu.com time.google.com; do
        emit_dnsmasq_allow_domain "$ntp_domain" "$upstream_dns" "$temp_conf"
    done
    echo "" >> "$temp_conf"

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
            emit_dnsmasq_allow_domain "$safe_domain" "$upstream_dns" "$temp_conf"
        else
            log_warn "Skipping invalid domain: $domain"
            invalid_count=$((invalid_count + 1))
        fi
    done

    if [ "$invalid_count" -gt 0 ]; then
        log_warn "Skipped $invalid_count invalid domains"
    fi

    echo "" >> "$temp_conf"

    local runtime_dependency_domains=()
    if declare -F get_runtime_dependency_domains >/dev/null 2>&1; then
        local runtime_dependency_domain
        while IFS= read -r runtime_dependency_domain; do
            [ -n "$runtime_dependency_domain" ] && runtime_dependency_domains+=("$runtime_dependency_domain")
        done < <(get_runtime_dependency_domains --prune)
    fi

    if [ "${#runtime_dependency_domains[@]}" -gt 0 ]; then
        echo "# Runtime dependency domains (${#runtime_dependency_domains[@]} domains)" >> "$temp_conf"
        local runtime_dependency_domain
        for runtime_dependency_domain in "${runtime_dependency_domains[@]}"; do
            if validate_domain "$runtime_dependency_domain"; then
                local safe_runtime_dependency_domain
                safe_runtime_dependency_domain="$(sanitize_domain "$runtime_dependency_domain")"
                emit_dnsmasq_allow_domain "$safe_runtime_dependency_domain" "$upstream_dns" "$temp_conf"
            else
                log_warn "Skipping invalid runtime dependency domain: $runtime_dependency_domain"
            fi
        done
        echo "" >> "$temp_conf"
    fi

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
