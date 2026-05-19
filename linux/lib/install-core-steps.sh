#!/bin/bash

################################################################################
# install-core-steps.sh - Core installer workflow steps
################################################################################

run_pre_install_validation() {
    local errors=0
    local warnings=0

    echo ""
    echo "[Preflight] Validating system requirements..."

    if [ "$EUID" -ne 0 ]; then
        echo "  ✗ Requires root privileges"
        errors=$((errors + 1))
    else
        echo "  ✓ Root privileges detected"
    fi

    if [ ! -d /run/systemd/system ]; then
        echo "  ✗ systemd is not active (required for timers/services)"
        errors=$((errors + 1))
    else
        echo "  ✓ systemd active"
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "  ✗ apt-get is not available (Debian/Ubuntu distribution required)"
        errors=$((errors + 1))
    else
        echo "  ✓ apt-get available"
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        echo "  ✗ systemctl not available"
        errors=$((errors + 1))
    else
        echo "  ✓ systemctl available"
    fi

    local free_mb
    free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 200 ]; then
        echo "  ✗ Insufficient space on / (${free_mb}MB free, minimum 200MB)"
        errors=$((errors + 1))
    else
        echo "  ✓ Sufficient disk space"
    fi

    if ! ip -o link show up 2>/dev/null | grep -q "state UP"; then
        echo "  ⚠ No active network interface detected"
        warnings=$((warnings + 1))
    else
        echo "  ✓ Active network interface detected"
    fi

    if ! timeout 5 getent hosts github.com >/dev/null 2>&1; then
        echo "  ⚠ DNS/Internet not verified (continuing anyway)"
        warnings=$((warnings + 1))
    else
        echo "  ✓ DNS resolution is functional"
    fi

    if ss -lntu 2>/dev/null | grep -qE '[:.]53\s'; then
        echo "  ⚠ Port 53 already in use (will try to release it during installation)"
        warnings=$((warnings + 1))
    else
        echo "  ✓ Port 53 available"
    fi

    if [ "$errors" -gt 0 ]; then
        echo ""
        echo "✗ Preflight failed: ${errors} error(s), ${warnings} warning(s)"
        echo "  Fix the errors or use --skip-preflight at your own risk"
        exit 1
    fi

    if [ "$warnings" -gt 0 ]; then
        echo "  ✓ Preflight completed with ${warnings} warning(s)"
    else
        echo "  ✓ Preflight completed without warnings"
    fi
}

step_install_libraries() {
    echo "[1/13] Installing libraries..."
    mkdir -p "$INSTALL_DIR/lib"
    mkdir -p "$INSTALL_DIR/libexec"
    mkdir -p "$CONFIG_DIR"

    cp "$INSTALLER_SOURCE_DIR/lib/"*.sh "$INSTALL_DIR/lib/"
    cp "$INSTALLER_SOURCE_DIR/libexec/browser-json.py" "$INSTALL_DIR/libexec/"
    cp "$INSTALLER_SOURCE_DIR/libexec/runtime-dependency-overlay.py" "$INSTALL_DIR/libexec/"
    cp "$INSTALLER_SOURCE_DIR/../runtime/browser-policy-spec.json" "$INSTALL_DIR/libexec/"
    cp "$INSTALLER_SOURCE_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh"

    chmod +x "$INSTALL_DIR/lib/"*.sh
    chmod +x "$INSTALL_DIR/libexec/browser-json.py"
    chmod +x "$INSTALL_DIR/libexec/runtime-dependency-overlay.py"
    chmod +x "$INSTALL_DIR/uninstall.sh"
    echo "✓ Libraries installed"

    source "$INSTALL_DIR/lib/common.sh"
    load_libraries
}

step_install_dependencies() {
    echo ""
    echo "[2/13] Installing dependencies..."

    apt_update_with_retry
    DEBIAN_FRONTEND=noninteractive apt_install_with_retry "base dependencies" \
        apt-get install -y \
        iptables ipset curl iproute2 \
        libcap2-bin dnsutils conntrack python3

    RUNLEVEL=1 apt_install_with_retry "dnsmasq" \
        apt-get install -y dnsmasq

    if [ -d /etc/default ]; then
        grep -q "IGNORE_RESOLVCONF" /etc/default/dnsmasq 2>/dev/null || \
            echo "IGNORE_RESOLVCONF=yes" >> /etc/default/dnsmasq
    fi

    setcap 'cap_net_bind_service,cap_net_admin=+ep' /usr/sbin/dnsmasq 2>/dev/null || true
    echo "✓ Dependencias instaladas"
}

step_free_port_53() {
    echo ""
    echo "[3/13] Releasing port 53..."

    free_port_53
    echo "✓ Port 53 released"
}

step_detect_dns() {
    echo ""
    echo "[4/13] Detecting primary DNS..."

    PRIMARY_DNS=$(detect_primary_dns)
    echo "$PRIMARY_DNS" > "$CONFIG_DIR/original-dns.conf"
    echo "✓ DNS primario: $PRIMARY_DNS"
}

step_install_scripts() {
    echo ""
    echo "[5/13] Instalando scripts..."

    cp "$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-update.sh" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/openpath-update.sh"

    cp "$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-runtime-dependency-apply.sh" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/openpath-runtime-dependency-apply.sh"

    cp "$INSTALLER_SOURCE_DIR/scripts/runtime/dnsmasq-watchdog.sh" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/dnsmasq-watchdog.sh"

    cp "$INSTALLER_SOURCE_DIR/scripts/runtime/captive-portal-detector.sh" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/captive-portal-detector.sh"

    cp "$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-sse-listener.sh" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/openpath-sse-listener.sh"

    cp "$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-browser-setup.sh" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/openpath-browser-setup.sh"

    cp "$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-cmd.sh" "$SCRIPTS_DIR/openpath"
    chmod +x "$SCRIPTS_DIR/openpath"

    cp "$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-self-update.sh" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/openpath-self-update.sh"

    cp "$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-agent-update.sh" "$SCRIPTS_DIR/"
    chmod +x "$SCRIPTS_DIR/openpath-agent-update.sh"

    create_dns_init_script

    mkdir -p "$ETC_CONFIG_DIR"
    chown root:root "$ETC_CONFIG_DIR" "$CONFIG_DIR" 2>/dev/null || true
    chmod 755 "$ETC_CONFIG_DIR" 2>/dev/null || true

    if [ -n "$WHITELIST_URL" ]; then
        if ! persist_openpath_whitelist_url "$WHITELIST_URL"; then
            echo "✗ ERROR: invalid whitelist URL"
            exit 1
        fi
    else
        echo "  → Whitelist URL not configured yet"
    fi

    if persist_openpath_health_api_config "$HEALTH_API_URL" "$HEALTH_API_SECRET"; then
        if [ -n "$HEALTH_API_URL" ]; then
            echo "  → Health API URL configurada"
        fi
        if [ -n "$HEALTH_API_SECRET" ]; then
            echo "  → Health API secret configurado"
        fi
    else
        echo "✗ ERROR: invalid health API configuration"
        exit 1
    fi

    if [ -n "$CLASSROOM_NAME" ] && [ -n "$API_URL" ]; then
        if ! persist_openpath_classroom_runtime_config "$API_URL" "$CLASSROOM_NAME" ""; then
            echo "✗ ERROR: invalid classroom configuration"
            exit 1
        fi

        if [ -n "$HEALTH_API_SECRET" ]; then
            cp "$HEALTH_API_SECRET_CONF" "$ETC_CONFIG_DIR/api-secret.conf"
            chown root:root "$ETC_CONFIG_DIR/api-secret.conf" 2>/dev/null || true
            chmod 600 "$ETC_CONFIG_DIR/api-secret.conf"
        fi
        echo "  → Classroom mode configured: $CLASSROOM_NAME"
    fi

    echo "✓ Scripts installed"
}

step_configure_sudoers() {
    echo ""
    echo "[6/13] Configuring sudo permissions..."

    if [[ ! -d /etc/sudoers.d ]]; then
        mkdir -p /etc/sudoers.d
        chmod 755 /etc/sudoers.d
    fi

    cat > /etc/sudoers.d/openpath << 'EOF'
# Allow all users to run READ commands without a password.
# These are safe: they do not modify configuration or disable protections.
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath status
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath test
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath check *
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath health
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath domains
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath domains *
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath log
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath log *
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath logs
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath help

# System commands (internal only, not exposed to users)
ALL ALL=(root) NOPASSWD: /usr/local/bin/openpath-update.sh
ALL ALL=(root) NOPASSWD: /usr/local/bin/dnsmasq-watchdog.sh

# NOTE: The following commands REQUIRE the root password:
# openpath update, enable, disable, force, restart, rotate-token, enroll, setup
EOF

    chmod 440 /etc/sudoers.d/openpath
    echo "✓ Sudo permissions configured"
}

step_create_services() {
    echo ""
    echo "[7/13] Creating systemd services..."

    create_systemd_services
    create_logrotate_config
    create_tmpfiles_config
    mkdir -p "$VAR_STATE_DIR/runtime-dependency-queue"
    chown root:root "$VAR_STATE_DIR/runtime-dependency-queue" 2>/dev/null || true
    chmod 1733 "$VAR_STATE_DIR/runtime-dependency-queue"
    mkdir -p "$VAR_STATE_DIR/runtime-dependency-rejected"
    chown root:root "$VAR_STATE_DIR/runtime-dependency-rejected" 2>/dev/null || true
    chmod 0700 "$VAR_STATE_DIR/runtime-dependency-rejected"

    echo "✓ Services created"
}

step_configure_dns() {
    echo ""
    echo "[8/13] Configuring DNS..."

    configure_upstream_dns
    configure_resolv_conf

    echo "✓ DNS configured"
}

step_configure_dnsmasq() {
    echo ""
    echo "[9/13] Configuring dnsmasq..."

    if [ -f /etc/dnsmasq.conf ]; then
        sed -i 's/^no-resolv/#no-resolv/g' /etc/dnsmasq.conf 2>/dev/null || true
        sed -i 's/^cache-size=/#cache-size=/g' /etc/dnsmasq.conf 2>/dev/null || true
    fi

    cat > /etc/dnsmasq.d/openpath.conf << EOF
# Initial configuration - will be overwritten by dnsmasq-whitelist.sh
no-resolv
resolv-file=/run/dnsmasq/resolv.conf
listen-address=127.0.0.1
bind-interfaces
cache-size=1000
server=$PRIMARY_DNS
EOF

    systemctl reset-failed dnsmasq 2>/dev/null || true
    systemctl restart dnsmasq

    echo "  Waiting for dnsmasq to become active..."
    for _ in $(seq 1 5); do
        if systemctl is-active --quiet dnsmasq; then
            break
        fi
        sleep 1
    done

    if systemctl is-active --quiet dnsmasq; then
        echo "✓ dnsmasq active"
    else
        echo "✗ ERROR: dnsmasq did not start"
        journalctl -u dnsmasq -n 10 --no-pager
        exit 1
    fi
}
