#!/bin/bash

# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

################################################################################
# services.sh - Systemd service management functions
# Part of the OpenPath DNS system
################################################################################

# Create all systemd services
create_systemd_services() {
    log "Creating systemd services..."
    
    create_firewall_restore_service
    create_whitelist_service
    create_whitelist_timer
    create_agent_update_service
    create_agent_update_timer
    create_sse_listener_service
    create_watchdog_service
    create_watchdog_timer
    create_captive_portal_service
    create_runtime_dependency_apply_service
    create_runtime_dependency_apply_path
    create_dnsmasq_override
    create_tmpfiles_config
    install_nm_dispatcher
    
    systemctl daemon-reload
    
    log "✓ Systemd services created"
}

# Early-boot firewall restore (boot fail-open fix). Runs before the network is
# configured (DefaultDependencies=no, Before/Wants=network-pre.target) so the
# saved OUTPUT default-deny is in force from the first moment an interface could
# carry traffic, instead of leaving OUTPUT policy ACCEPT for the ~2 min until the
# dnsmasq timer first fires openpath-update.sh. The script recreates the
# referenced ipsets first, restores rules.v4/.v6, and seeds a fail-closed ruleset
# if none is saved.
create_firewall_restore_service() {
    cat > /etc/systemd/system/openpath-firewall-restore.service << 'EOF'
[Unit]
Description=OpenPath Early-Boot Firewall Restore (fail-closed)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/openpath-firewall-restore.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# Whitelist update service
create_whitelist_service() {
    cat > /etc/systemd/system/openpath-dnsmasq.service << 'EOF'
[Unit]
Description=Update OpenPath DNS Whitelist
After=network-online.target dnsmasq.service
Wants=network-online.target
Requires=dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openpath-update.sh
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# Timer for periodic updates (configurable fallback — SSE handles real-time)
create_whitelist_timer() {
    local interval="${TIMER_INTERVAL_MINUTES:-5}"
    cat > /etc/systemd/system/openpath-dnsmasq.timer << EOF
[Unit]
Description=Timer for OpenPath DNS Whitelist Update
After=network-online.target

[Timer]
OnBootSec=2min
OnCalendar=*:0/${interval}
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# SSE listener service for instant rule updates
create_sse_listener_service() {
    cat > /etc/systemd/system/openpath-sse-listener.service << 'EOF'
[Unit]
Description=OpenPath SSE Listener for Instant Rule Updates
After=network-online.target dnsmasq.service openpath-dnsmasq.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/openpath-sse-listener.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# Agent update service
create_agent_update_service() {
    cat > /etc/systemd/system/openpath-agent-update.service << 'EOF'
[Unit]
Description=OpenPath Linux Agent Update Check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openpath-agent-update.sh
TimeoutStartSec=900
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# Timer for unattended agent software updates
create_agent_update_timer() {
    cat > /etc/systemd/system/openpath-agent-update.timer << 'EOF'
[Unit]
Description=Timer for OpenPath Linux Agent Updates
After=network-online.target

[Timer]
OnBootSec=45min
OnUnitActiveSec=1d
AccuracySec=1h
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Watchdog service
create_watchdog_service() {
    cat > /etc/systemd/system/dnsmasq-watchdog.service << 'EOF'
[Unit]
Description=dnsmasq Health Check and Auto-Recovery
After=dnsmasq.service
Wants=dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dnsmasq-watchdog.sh
StandardOutput=journal
StandardError=journal
SuccessExitStatus=0 1

[Install]
WantedBy=multi-user.target
EOF
}

# Watchdog timer
create_watchdog_timer() {
    cat > /etc/systemd/system/dnsmasq-watchdog.timer << 'EOF'
[Unit]
Description=Timer for dnsmasq Health Check
After=dnsmasq.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Captive portal detector service
create_captive_portal_service() {
    cat > /etc/systemd/system/captive-portal-detector.service << 'EOF'
[Unit]
Description=Captive Portal Detector for URL Whitelist
After=network-online.target dnsmasq.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/captive-portal-detector.sh
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

create_runtime_dependency_apply_service() {
    cat > /etc/systemd/system/openpath-runtime-dependency-apply.service << 'EOF'
[Unit]
Description=Apply OpenPath Browser Runtime Dependencies
After=dnsmasq.service
Wants=dnsmasq.service
StartLimitIntervalSec=60
StartLimitBurst=20

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openpath-runtime-dependency-apply.sh
TimeoutStartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

create_runtime_dependency_apply_path() {
    cat > /etc/systemd/system/openpath-runtime-dependency-apply.path << 'EOF'
[Unit]
Description=Watch OpenPath Browser Runtime Dependency Queue

[Path]
PathExistsGlob=/var/lib/openpath/runtime-dependency-queue/*.json
Unit=openpath-runtime-dependency-apply.service

[Install]
WantedBy=multi-user.target
EOF
}

# Override for dnsmasq to initialize upstream DNS
create_dnsmasq_override() {
    mkdir -p /etc/systemd/system/dnsmasq.service.d
    cat > /etc/systemd/system/dnsmasq.service.d/whitelist-override.conf << 'EOF'
[Service]
ExecStartPre=/usr/local/bin/dnsmasq-init-resolv.sh
EOF
}

# Enable and start services
enable_services() {
    log "Enabling services..."
    
    systemctl enable openpath-firewall-restore.service
    systemctl enable dnsmasq
    systemctl enable openpath-dnsmasq.timer
    systemctl enable openpath-agent-update.timer
    systemctl enable dnsmasq-watchdog.timer
    systemctl enable captive-portal-detector.service
    systemctl enable openpath-sse-listener.service 2>/dev/null || true
    systemctl enable openpath-runtime-dependency-apply.path

    systemctl start openpath-dnsmasq.timer
    systemctl start openpath-agent-update.timer
    systemctl start dnsmasq-watchdog.timer
    systemctl start captive-portal-detector.service
    systemctl start openpath-sse-listener.service 2>/dev/null || true
    systemctl start openpath-runtime-dependency-apply.path
    
    log "✓ Services enabled and started"
}

# Disable services
disable_services() {
    log "Disabling services..."
    
    systemctl stop openpath-sse-listener.service 2>/dev/null || true
    systemctl stop openpath-dnsmasq.timer 2>/dev/null || true
    systemctl stop openpath-agent-update.timer 2>/dev/null || true
    systemctl stop dnsmasq-watchdog.timer 2>/dev/null || true
    systemctl stop captive-portal-detector.service 2>/dev/null || true
    systemctl stop openpath-runtime-dependency-apply.path 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    
    systemctl disable openpath-sse-listener.service 2>/dev/null || true
    systemctl disable openpath-dnsmasq.timer 2>/dev/null || true
    systemctl disable openpath-agent-update.timer 2>/dev/null || true
    systemctl disable dnsmasq-watchdog.timer 2>/dev/null || true
    systemctl disable captive-portal-detector.service 2>/dev/null || true
    systemctl disable openpath-runtime-dependency-apply.path 2>/dev/null || true
    systemctl disable openpath-firewall-restore.service 2>/dev/null || true

    log "✓ Services disabled"
}

# Remove services
remove_services() {
    log "Removing services..."
    
    disable_services
    
    rm -f /etc/systemd/system/openpath-firewall-restore.service
    rm -f /etc/systemd/system/openpath-dnsmasq.service
    rm -f /etc/systemd/system/openpath-dnsmasq.timer
    rm -f /etc/systemd/system/openpath-agent-update.service
    rm -f /etc/systemd/system/openpath-agent-update.timer
    rm -f /etc/systemd/system/openpath-sse-listener.service
    rm -f /etc/systemd/system/openpath-runtime-dependency-apply.service
    rm -f /etc/systemd/system/openpath-runtime-dependency-apply.path
    rm -f /etc/systemd/system/dnsmasq-watchdog.service
    rm -f /etc/systemd/system/dnsmasq-watchdog.timer
    rm -f /etc/systemd/system/captive-portal-detector.service
    rm -rf /etc/systemd/system/dnsmasq.service.d
    remove_nm_dispatcher
    
    systemctl daemon-reload
    
    log "✓ Services removed"
}

# Configure logrotate
create_logrotate_config() {
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/openpath-dnsmasq << 'EOF'
/var/log/openpath.log
/var/log/captive-portal-detector.log
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    size 10M
}
EOF
}

# Write tmpfiles.d rules for /run/dnsmasq and the runtime-dependency queue directories.
# A narrower variant that only covers /run/dnsmasq lives in linux/lib/dns-runtime.sh.
create_tmpfiles_config() {
    mkdir -p /etc/tmpfiles.d
    cat > /etc/tmpfiles.d/openpath-dnsmasq.conf << 'EOF'
d /run/dnsmasq 0755 root root -
d /var/lib/openpath/runtime-dependency-queue 1733 root root -
d /var/lib/openpath/runtime-dependency-rejected 0700 root root -
EOF
}

# Install a NetworkManager dispatcher hook to wake the captive portal detector
# immediately on network changes.
# Optional: only installed if NetworkManager dispatcher directory exists.
install_nm_dispatcher() {
    local dispatcher_dir="/etc/NetworkManager/dispatcher.d"
    local hook_path="$dispatcher_dir/99-openpath-captive-check"

    if [ ! -d "$dispatcher_dir" ]; then
        log_debug "[CAPTIVE] NetworkManager dispatcher dir not found; skipping hook install"
        return 0
    fi

    cat > "$hook_path" << 'EOF'
#!/bin/bash
set -o pipefail

INTERFACE="$1"
ACTION="$2"

case "$ACTION" in
    up|connectivity-change|dhcp4-change|dhcp6-change)
        # Wake captive portal detector service (interrupts sleep)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl kill -s USR1 captive-portal-detector.service 2>/dev/null || true
        fi
        logger -t openpath "[CAPTIVE] Network change ($ACTION on $INTERFACE) - waking captive portal detector" 2>/dev/null || true
        ;;
esac

exit 0
EOF

    chmod 755 "$hook_path" 2>/dev/null || true
    log "✓ NetworkManager dispatcher hook installed: $hook_path"
    return 0
}

remove_nm_dispatcher() {
    local hook_path="/etc/NetworkManager/dispatcher.d/99-openpath-captive-check"
    rm -f "$hook_path" 2>/dev/null || true
}
