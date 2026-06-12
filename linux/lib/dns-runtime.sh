#!/bin/bash

get_first_whitelisted_domain() {
    local whitelist_file="${1:-${WHITELIST_FILE:-}}"
    [ -n "$whitelist_file" ] && [ -f "$whitelist_file" ] || return 1

    local candidate
    while IFS= read -r candidate; do
        candidate=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | sed 's/[[:space:]]//g; s/^\.*//; s/\.*$//')
        [ -n "$candidate" ] || continue
        if ! declare -F validate_domain >/dev/null 2>&1 || validate_domain "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(
        awk '
            BEGIN { section = "whitelist" }
            /^[[:space:]]*##[[:space:]]*WHITELIST[[:space:]]*$/ { section = "whitelist"; next }
            /^[[:space:]]*##[[:space:]]*BLOCKED-SUBDOMAINS[[:space:]]*$/ { section = "blocked"; next }
            /^[[:space:]]*##[[:space:]]*BLOCKED-PATHS[[:space:]]*$/ { section = "blocked"; next }
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            section == "whitelist" { print }
        ' "$whitelist_file" 2>/dev/null
    )

    return 1
}

dns_probe_file_contains_domain() {
    local domain="$1"
    local whitelist_file="${2:-${WHITELIST_FILE:-}}"
    [ -n "$domain" ] && [ -n "$whitelist_file" ] && [ -f "$whitelist_file" ] || return 1

    local normalized
    normalized=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | sed 's/[[:space:]]//g; s/^\.*//; s/\.*$//')
    [ -n "$normalized" ] || return 1

    awk -v domain="$normalized" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            line = tolower($0)
            gsub(/[[:space:]\r\n]/, "", line)
            sub(/^\.+/, "", line)
            sub(/\.+$/, "", line)
            if (line == domain) {
                found = 1
                exit
            }
        }
        END { exit found ? 0 : 1 }
    ' "$whitelist_file" 2>/dev/null
}

select_allowed_dns_probe_domain() {
    local whitelist_file="${1:-${WHITELIST_FILE:-}}"
    local domain

    if domain=$(get_first_whitelisted_domain "$whitelist_file"); then
        printf '%s\n' "$domain"
        return 0
    fi

    if declare -F get_openpath_protected_domains >/dev/null 2>&1; then
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            printf '%s\n' "$domain"
            return 0
        done < <(get_openpath_protected_domains)
    fi

    printf '%s\n' "github.com"
}

select_blocked_dns_probe_domain() {
    local whitelist_file="${1:-${WHITELIST_FILE:-}}"
    local candidate

    for candidate in facebook.com wikipedia.org example.com reddit.com duckduckgo.com youtube.com instagram.com tiktok.com; do
        if declare -F is_openpath_protected_domain >/dev/null 2>&1 && is_openpath_protected_domain "$candidate"; then
            continue
        fi
        if dns_probe_file_contains_domain "$candidate" "$whitelist_file"; then
            continue
        fi
        printf '%s\n' "$candidate"
        return 0
    done

    printf '%s\n' "example.net"
}

resolve_local_dns_probe() {
    local domain="$1"
    [ -n "$domain" ] || return 1

    timeout 3 dig @127.0.0.1 "$domain" +short +time=2 +tries=1 2>/dev/null || true
}

dns_probe_result_is_public() {
    local result="${1:-}"

    printf '%s\n' "$result" | awk '
        /^[[:space:]]*$/ { next }
        $0 == "0.0.0.0" || $0 == "::" { next }
        $0 == "192.0.2.1" || $0 == "100::" { next }
        { found = 1; exit }
        END { exit found ? 0 : 1 }
    '
}

dns_probe_result_is_blocked() {
    local result="${1:-}"

    if dns_probe_result_is_public "$result"; then
        return 1
    fi
    return 0
}

# Free port 53 (stop services that can bind the local DNS socket)
free_port_53() {
    log "Freeing port 53..."

    # The Debian dnsmasq package can auto-start during dependency installation.
    # Stop it before disabling systemd-resolved so postinst does not leave DNS down
    # while waiting for a port still held by the default dnsmasq daemon.
    systemctl stop dnsmasq 2>/dev/null || true

    # Stop systemd-resolved socket and service
    systemctl stop systemd-resolved.socket 2>/dev/null || true
    systemctl disable systemd-resolved.socket 2>/dev/null || true
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true

    # Wait for port to be released
    local retries=30
    while [ $retries -gt 0 ]; do
        if ! ss -tulpn 2>/dev/null | grep -q ":53 "; then
            log "✓ Port 53 freed"
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done

    log "⚠ Port 53 still occupied after 30 seconds"
    return 1
}

# Configure /etc/resolv.conf to use local dnsmasq
configure_resolv_conf() {
    log "Configuring /etc/resolv.conf..."

    # Unprotect if protected
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # Backup if symlink
    if [ -L /etc/resolv.conf ]; then
        local target
        target=$(readlink -f /etc/resolv.conf)
        echo "$target" > "$CONFIG_DIR/resolv.conf.symlink.backup"
        rm -f /etc/resolv.conf
    elif [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$CONFIG_DIR/resolv.conf.backup"
    fi

    cat > /etc/resolv.conf << 'EOF'
# Generado por openpath
# DNS local (dnsmasq)
nameserver 127.0.0.1
options edns0 trust-ad
search lan
EOF

    chattr +i /etc/resolv.conf 2>/dev/null || true

    log "✓ /etc/resolv.conf configured"
}

# Configure upstream DNS for dnsmasq
configure_upstream_dns() {
    log "Configuring upstream DNS..."

    mkdir -p /run/dnsmasq

    PRIMARY_DNS=$(select_usable_upstream_dns "$(detect_primary_dns)")

    echo "$PRIMARY_DNS" > "$ORIGINAL_DNS_FILE"

    cat > /run/dnsmasq/resolv.conf << EOF
# DNS upstream para dnsmasq
nameserver $PRIMARY_DNS
nameserver ${FALLBACK_DNS_SECONDARY:-8.8.4.4}
EOF

    log "✓ Upstream DNS configured: $PRIMARY_DNS"
}

select_usable_upstream_dns() {
    local dns="${1:-}"
    local fallback="${2:-${FALLBACK_DNS_PRIMARY:-8.8.8.8}}"

    if declare -F is_usable_upstream_dns >/dev/null 2>&1 && is_usable_upstream_dns "$dns"; then
        printf '%s\n' "$dns"
        return 0
    fi

    if declare -F is_usable_upstream_dns >/dev/null 2>&1 && is_usable_upstream_dns "$fallback"; then
        printf '%s\n' "$fallback"
        return 0
    fi

    printf '%s\n' "8.8.8.8"
}

# Generate the boot-time DNS initialisation script and write it to disk.
# Everything between the heredoc markers below is a script template that will be
# evaluated at boot, not at install time. Escaped dollar signs (\$) are intentional:
# they defer variable expansion to the generated script's runtime environment.
create_dns_init_script() {
    local fallback_primary="${FALLBACK_DNS_PRIMARY:-8.8.8.8}"
    local fallback_secondary="${FALLBACK_DNS_SECONDARY:-8.8.4.4}"
    local original_dns_file="${ORIGINAL_DNS_FILE:-/etc/openpath/original-dns.conf}"
    local legacy_original_dns_file="${VAR_STATE_DIR:-/var/lib/openpath}/original-dns.conf"

    cat > "$SCRIPTS_DIR/dnsmasq-init-resolv.sh" << EOF
#!/bin/bash
# Regenerate /run/dnsmasq/resolv.conf on each boot

FALLBACK_DNS_PRIMARY="${fallback_primary}"
FALLBACK_DNS_SECONDARY="${fallback_secondary}"
ORIGINAL_DNS_FILE="${original_dns_file}"
LEGACY_ORIGINAL_DNS_FILE="${legacy_original_dns_file}"

mkdir -p /run/dnsmasq

is_usable_upstream_dns() {
    local dns="\$1"
    [[ "\$dns" =~ ^[0-9]{1,3}(\\.[0-9]{1,3}){3}\$ ]] || return 1
    case "\$dns" in
        0.*|127.*|169.254.*|224.*|225.*|226.*|227.*|228.*|229.*|23[0-9].*|24[0-9].*|25[0-5].*)
            return 1
            ;;
    esac
    return 0
}

read_dns_from_file() {
    local dns_file="\$1"
    local dns=""
    [ -f "\$dns_file" ] || return 1
    dns=\$(head -1 "\$dns_file" 2>/dev/null || true)
    if is_usable_upstream_dns "\$dns"; then
        printf '%s\\n' "\$dns"
        return 0
    fi
    return 1
}

read_dns_from_resolv_conf() {
    local resolv_conf="\$1"
    local dns=""
    [ -f "\$resolv_conf" ] || return 1
    while IFS= read -r dns; do
        dns="\${dns%%#*}"
        dns=\$(printf '%s' "\$dns" | awk '\$1 == "nameserver" { print \$2 }')
        [ -n "\$dns" ] || continue
        if is_usable_upstream_dns "\$dns"; then
            printf '%s\\n' "\$dns"
            return 0
        fi
    done < "\$resolv_conf"
    return 1
}

PRIMARY_DNS=""
PRIMARY_DNS=\$(read_dns_from_file "\$ORIGINAL_DNS_FILE" || true)
[ -z "\$PRIMARY_DNS" ] && PRIMARY_DNS=\$(read_dns_from_file "\$LEGACY_ORIGINAL_DNS_FILE" || true)
if [ -z "\$PRIMARY_DNS" ] && command -v nmcli >/dev/null 2>&1; then
    while IFS= read -r dns; do
        if is_usable_upstream_dns "\$dns"; then
            PRIMARY_DNS="\$dns"
            break
        fi
    done < <(nmcli dev show 2>/dev/null | awk 'toupper(\$1) ~ /^IP4\\.DNS/ { print \$2 }')
fi
[ -z "\$PRIMARY_DNS" ] && PRIMARY_DNS=\$(read_dns_from_resolv_conf /run/systemd/resolve/resolv.conf || true)
[ -z "\$PRIMARY_DNS" ] && PRIMARY_DNS=\$(read_dns_from_resolv_conf /etc/resolv.conf || true)
[ -z "\$PRIMARY_DNS" ] && PRIMARY_DNS=\$(ip route | grep default | awk '{print \$3}' | head -1)
if ! is_usable_upstream_dns "\$PRIMARY_DNS"; then
    PRIMARY_DNS="\$FALLBACK_DNS_PRIMARY"
fi

cat > /run/dnsmasq/resolv.conf << DNSEOF
nameserver \$PRIMARY_DNS
nameserver \$FALLBACK_DNS_SECONDARY
DNSEOF

echo "dnsmasq-init-resolv: DNS upstream configurado a \$PRIMARY_DNS"
EOF
    chmod +x "$SCRIPTS_DIR/dnsmasq-init-resolv.sh"
}

# Write a minimal tmpfiles.d rule that ensures /run/dnsmasq exists at boot.
# A broader variant covering additional runtime state directories lives in
# linux/lib/services.sh and supersedes this one in all standard sourcing contexts.
create_dnsmasq_runtime_tmpfiles_config() {
    cat > /etc/tmpfiles.d/openpath-dnsmasq.conf << 'EOF'
# Create /run/dnsmasq directory on each boot
d /run/dnsmasq 0755 root root -
EOF
}

# Restore original DNS
restore_dns() {
    log "Restoring original DNS..."

    chattr -i /etc/resolv.conf 2>/dev/null || true

    if [ -f "$CONFIG_DIR/resolv.conf.symlink.backup" ]; then
        local target
        target=$(cat "$CONFIG_DIR/resolv.conf.symlink.backup")
        ln -sf "$target" /etc/resolv.conf
    elif [ -f "$CONFIG_DIR/resolv.conf.backup" ]; then
        cp "$CONFIG_DIR/resolv.conf.backup" /etc/resolv.conf
    else
        cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
    fi

    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true

    log "✓ DNS restored"
}
