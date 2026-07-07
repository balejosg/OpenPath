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

    # sink4/sink6 are the canonical defaults.conf values, so a deployment that
    # overrides the sinkhole addresses still classifies its own sinkhole
    # answers as non-public. 0.0.0.0/:: are generic null answers, not
    # sinkholes, and stay literal.
    printf '%s\n' "$result" | awk \
        -v sink4="$OPENPATH_DNS_SINKHOLE_IPV4" \
        -v sink6="$OPENPATH_DNS_SINKHOLE_IPV6" '
        /^[[:space:]]*$/ { next }
        $0 == "0.0.0.0" || $0 == "::" { next }
        $0 == sink4 || $0 == sink6 { next }
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

# Render the OpenPath /etc/resolv.conf body (local dnsmasq resolver). Kept as a
# pure function so the content contract is unit-testable.
#
# Deliberately carries NO `search` domain. A search domain (e.g. `search lan`)
# makes glibc retry a failed absolute lookup as "<host>.<search>"; for a
# whitelisted FQDN that transiently fails to resolve (DNS churn during a
# whitelist update, brief upstream hiccup) that fallthrough name is not
# whitelisted, so the sinkhole wildcard (address=/#/<sink>) answers it with the
# sink IP. The browser then commits to the dead sinkhole (IPv6-preferring clients
# black-hole on the v6 sink) instead of failing fast and re-querying once the
# real answer is available. Omitting the search domain makes such a miss a clean
# NXDOMAIN. See dns.bats and the page-observer canary post-mortem.
render_openpath_resolv_conf() {
    cat << 'EOF'
# Generado por openpath
# DNS local (dnsmasq)
nameserver 127.0.0.1
options edns0 trust-ad
EOF
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

    render_openpath_resolv_conf > /etc/resolv.conf

    chattr +i /etc/resolv.conf 2>/dev/null || true

    log "✓ /etc/resolv.conf configured"
}

# Configure upstream DNS for dnsmasq
configure_upstream_dns() {
    log "Configuring upstream DNS..."

    local resolv_out
    resolv_out=$(dnsmasq_upstream_resolv_conf_path)
    mkdir -p "$(dirname "$resolv_out")"

    PRIMARY_DNS=$(select_usable_upstream_dns "$(detect_primary_dns)")

    persist_upstream_dns "$PRIMARY_DNS"

    render_dnsmasq_upstream_resolv_conf "$PRIMARY_DNS" > "$resolv_out"

    log "✓ Upstream DNS configured: $PRIMARY_DNS"
}

# Generate the boot-time DNS initialisation script and write it to disk.
# Everything between the heredoc markers below is a script template evaluated
# at boot, not at install time. Escaped dollar signs (\$) are intentional: they
# defer variable expansion to the generated script's runtime environment.
#
# The generated script deliberately does NOT re-derive the upstream from the
# live network (nmcli / resolv.conf / gateway): the boot-restored firewall only
# allows the PERSISTED upstream on :53, so a re-derived value can diverge and
# be silently dropped (see the detect_primary_dns invariant comment in
# common-connectivity.sh). It sources the installed connectivity library and
# calls the owner helpers; the only inline fallback is a verbatim read of the
# persisted file for the case where the library itself is missing.
create_dns_init_script() {
    local fallback_primary="${FALLBACK_DNS_PRIMARY:-8.8.8.8}"
    local fallback_secondary="${FALLBACK_DNS_SECONDARY:-8.8.4.4}"
    local original_dns_file="${ORIGINAL_DNS_FILE:-/etc/openpath/original-dns.conf}"
    local legacy_original_dns_file="${VAR_STATE_DIR:-/var/lib/openpath}/original-dns.conf"
    local connectivity_lib="${INSTALL_DIR:-/usr/local/lib/openpath}/lib/common-connectivity.sh"

    cat > "$SCRIPTS_DIR/dnsmasq-init-resolv.sh" << EOF
#!/bin/bash
# Regenerate the dnsmasq upstream resolv.conf on each boot from the PERSISTED
# upstream. Single owner of the upstream logic: common-connectivity.sh.

FALLBACK_DNS_PRIMARY="${fallback_primary}"
FALLBACK_DNS_SECONDARY="${fallback_secondary}"
ORIGINAL_DNS_FILE="${original_dns_file}"
LEGACY_ORIGINAL_DNS_FILE="${legacy_original_dns_file}"
OPENPATH_CONNECTIVITY_LIB="${connectivity_lib}"
RESOLV_OUT="\${OPENPATH_DNSMASQ_RESOLV_CONF:-/run/dnsmasq/resolv.conf}"

mkdir -p "\$(dirname "\$RESOLV_OUT")"

PRIMARY_DNS=""
# shellcheck disable=SC1090
if [ -f "\$OPENPATH_CONNECTIVITY_LIB" ] && source "\$OPENPATH_CONNECTIVITY_LIB"; then
    PRIMARY_DNS=\$(resolve_persisted_upstream_dns "\$ORIGINAL_DNS_FILE" "\$LEGACY_ORIGINAL_DNS_FILE")
    render_dnsmasq_upstream_resolv_conf "\$PRIMARY_DNS" "\$FALLBACK_DNS_SECONDARY" > "\$RESOLV_OUT"
else
    # Degraded last resort (connectivity library missing => broken install):
    # trust the persisted value verbatim -- it was format-validated when it was
    # written by persist_upstream_dns. No detection logic is re-implemented here.
    PRIMARY_DNS=\$(head -1 "\$ORIGINAL_DNS_FILE" 2>/dev/null || true)
    [ -n "\$PRIMARY_DNS" ] || PRIMARY_DNS=\$(head -1 "\$LEGACY_ORIGINAL_DNS_FILE" 2>/dev/null || true)
    [ -n "\$PRIMARY_DNS" ] || PRIMARY_DNS="\$FALLBACK_DNS_PRIMARY"
    printf '# DNS upstream para dnsmasq\\nnameserver %s\\nnameserver %s\\n' "\$PRIMARY_DNS" "\$FALLBACK_DNS_SECONDARY" > "\$RESOLV_OUT"
fi

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
