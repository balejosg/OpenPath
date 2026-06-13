#!/usr/bin/env bats
################################################################################
# services.bats - Tests for lib/services.sh
################################################################################

load 'test_helper'

setup() {
    # Create temp directory for tests
    TEST_TMP_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_TMP_DIR/config"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    export SCRIPTS_DIR="$TEST_TMP_DIR/scripts"
    
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$INSTALL_DIR/lib"
    mkdir -p "$SCRIPTS_DIR"
    mkdir -p "$TEST_TMP_DIR/systemd/system"
    mkdir -p "$TEST_TMP_DIR/logrotate.d"
    mkdir -p "$TEST_TMP_DIR/tmpfiles.d"
    
    # Copy libs
    cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/" 2>/dev/null || true
    
    setup_mock_log

    # Mock systemctl
    systemctl() { return 0; }
    export -f systemctl
}

# ============== Tests de create_whitelist_service ==============

@test "create_whitelist_service generates unit file" {
    # Temporarily redirect to test location
    local service_file="$TEST_TMP_DIR/systemd/system/openpath-dnsmasq.service"
    
    # Source and override the function to use test path
    create_whitelist_service() {
        cat > "$service_file" << 'EOF'
[Unit]
Description=Update OpenPath DNS
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
    
    run create_whitelist_service
    [ "$status" -eq 0 ]
    [ -f "$service_file" ]
}

@test "create_whitelist_service includes required sections" {
    local service_file="$TEST_TMP_DIR/systemd/system/openpath-dnsmasq.service"
    
    create_whitelist_service() {
        cat > "$service_file" << 'EOF'
[Unit]
Description=Update OpenPath DNS

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openpath-update.sh

[Install]
WantedBy=multi-user.target
EOF
    }
    
    run create_whitelist_service
    
    grep -q "\[Unit\]" "$service_file"
    grep -q "\[Service\]" "$service_file"
    grep -q "\[Install\]" "$service_file"
}

# ============== Tests de create_whitelist_timer ==============

@test "create_whitelist_timer generates timer file" {
    local timer_file="$TEST_TMP_DIR/systemd/system/openpath-dnsmasq.timer"
    
    create_whitelist_timer() {
        cat > "$timer_file" << 'EOF'
[Unit]
Description=Timer for OpenPath DNS Update

[Timer]
OnBootSec=2min
OnCalendar=*:0/5
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    }
    
    run create_whitelist_timer
    [ "$status" -eq 0 ]
    [ -f "$timer_file" ]
}

@test "create_whitelist_timer configures 5 minute interval" {
    local timer_file="$TEST_TMP_DIR/systemd/system/openpath-dnsmasq.timer"
    
    create_whitelist_timer() {
        cat > "$timer_file" << 'EOF'
[Timer]
OnCalendar=*:0/5
EOF
    }
    
    run create_whitelist_timer
    
    grep -q "OnCalendar=\*:0/5" "$timer_file"
}

@test "services library defines unattended linux agent update timer with randomized delay" {
    run grep -nF 'create_agent_update_timer()' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'openpath-agent-update.timer' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'RandomizedDelaySec=6h' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'Persistent=true' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]
}

# ============== Tests de create_watchdog_service ==============

@test "create_watchdog_service generates unit file" {
    local service_file="$TEST_TMP_DIR/systemd/system/dnsmasq-watchdog.service"
    
    create_watchdog_service() {
        cat > "$service_file" << 'EOF'
[Unit]
Description=OpenPath DNS Health Check and Auto-Recovery

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dnsmasq-watchdog.sh

[Install]
WantedBy=multi-user.target
EOF
    }
    
    run create_watchdog_service
    [ "$status" -eq 0 ]
    [ -f "$service_file" ]
}

# ============== Tests de create_logrotate_config ==============

@test "create_logrotate_config generates configuration file" {
    local logrotate_file="$TEST_TMP_DIR/logrotate.d/openpath"
    
    create_logrotate_config() {
        cat > "$logrotate_file" << 'EOF'
/var/log/openpath.log
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
    
    run create_logrotate_config
    [ "$status" -eq 0 ]
    [ -f "$logrotate_file" ]
}

@test "create_logrotate_config includes compression" {
    local logrotate_file="$TEST_TMP_DIR/logrotate.d/openpath"
    
    create_logrotate_config() {
        cat > "$logrotate_file" << 'EOF'
{
    compress
    delaycompress
}
EOF
    }
    
    run create_logrotate_config
    
    grep -q "compress" "$logrotate_file"
}

@test "create_logrotate_config configures daily rotation" {
    local logrotate_file="$TEST_TMP_DIR/logrotate.d/openpath"
    
    create_logrotate_config() {
        cat > "$logrotate_file" << 'EOF'
{
    daily
    rotate 7
}
EOF
    }
    
    run create_logrotate_config
    
    grep -q "daily" "$logrotate_file"
    grep -q "rotate 7" "$logrotate_file"
}

# ============== Tests de create_tmpfiles_config ==============

@test "create_tmpfiles_config generates configuration" {
    local tmpfiles_file="$TEST_TMP_DIR/tmpfiles.d/openpath.conf"
    
    create_tmpfiles_config() {
        cat > "$tmpfiles_file" << 'EOF'
d /run/dnsmasq 0755 root root -
EOF
    }
    
    run create_tmpfiles_config
    [ "$status" -eq 0 ]
    [ -f "$tmpfiles_file" ]
}

@test "create_tmpfiles_config creates /run/dnsmasq directory" {
    local tmpfiles_file="$TEST_TMP_DIR/tmpfiles.d/openpath.conf"
    
    create_tmpfiles_config() {
        cat > "$tmpfiles_file" << 'EOF'
d /run/dnsmasq 0755 root root -
EOF
    }
    
    run create_tmpfiles_config
    
    grep -q "/run/dnsmasq" "$tmpfiles_file"
}

@test "create_systemd_services creates runtime dependency apply service and path" {
    run grep -nF "create_runtime_dependency_apply_service" "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]

    run grep -nF "create_runtime_dependency_apply_path" "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]

    run grep -nF "ExecStart=/usr/local/bin/openpath-runtime-dependency-apply.sh" "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]

    run grep -nF "PathExistsGlob=/var/lib/openpath/runtime-dependency-queue/*.json" "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]
}

@test "tmpfiles config provisions runtime dependency queue with root-owned sticky dropbox permissions" {
    run grep -nF "d /var/lib/openpath/runtime-dependency-queue 1733 root root -" "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]

    run grep -nF "d /var/lib/openpath/runtime-dependency-rejected 0700 root root -" "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]
}

@test "runtime dependency apply script restarts dnsmasq only when config changed" {
    local install_dir="$TEST_TMP_DIR/install-runtime-apply"
    local script_path="$PROJECT_DIR/linux/scripts/runtime/openpath-runtime-dependency-apply.sh"

    mkdir -p "$install_dir/lib" "$install_dir/libexec" "$TEST_TMP_DIR/bin"
    cp "$PROJECT_DIR/linux/lib/"*.sh "$install_dir/lib/"
    cp "$PROJECT_DIR/linux/libexec/"*.py "$install_dir/libexec/"
    cp "$PROJECT_DIR/runtime/browser-policy-spec.json" "$install_dir/libexec/"
    printf '4.1.0\n' > "$install_dir/VERSION"
    : > "$install_dir/lib/defaults.conf"

    cat >> "$install_dir/lib/dns.sh" <<'EOF'
parse_whitelist_sections() { :; }
process_runtime_dependency_queue() { :; }
generate_dnsmasq_config() { printf 'dns-config\n' > "$DNSMASQ_CONF"; }
has_config_changed() { [ "$(cat "$DNSMASQ_CONF_HASH" 2>/dev/null)" != "newhash" ]; }
restart_dnsmasq() { printf 'restart\n' >> "$RESTART_LOG"; return 0; }
flush_dns_cache() { :; }
with_openpath_lock() { "$@"; }
EOF

    cat > "$TEST_TMP_DIR/bin/sha256sum" <<'EOF'
#!/bin/bash
printf 'newhash  %s\n' "$1"
EOF
    chmod +x "$TEST_TMP_DIR/bin/sha256sum"

    export INSTALL_DIR="$install_dir"
    export WHITELIST_FILE="$TEST_TMP_DIR/whitelist.txt"
    export DNSMASQ_CONF="$TEST_TMP_DIR/openpath.conf"
    export DNSMASQ_CONF_HASH="$TEST_TMP_DIR/openpath.conf.hash"
    export RESTART_LOG="$TEST_TMP_DIR/restart.log"
    export PATH="$TEST_TMP_DIR/bin:$PATH"
    cat > "$WHITELIST_FILE" <<'EOF'
allowed.example
EOF

    generate_dnsmasq_config() { :; }

    printf 'newhash\n' > "$DNSMASQ_CONF_HASH"
    printf 'dns-config\n' > "$DNSMASQ_CONF"
    run "$script_path"
    [ "$status" -eq 0 ]
    [ ! -f "$RESTART_LOG" ]

    printf 'oldhash\n' > "$DNSMASQ_CONF_HASH"
    run "$script_path"
    [ "$status" -eq 0 ]
    grep -q "restart" "$RESTART_LOG"
    grep -q "newhash" "$DNSMASQ_CONF_HASH"
}

# ============== Early-boot firewall restore (boot fail-open fix, F-A) ==============

@test "create_firewall_restore_service defines an early-boot fail-closed unit" {
    run grep -nF 'create_firewall_restore_service()' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]

    # Runs before the network is configured so OUTPUT is never ACCEPT at boot.
    run grep -nF 'DefaultDependencies=no' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]
    run grep -nF 'Before=network-pre.target' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]
    run grep -nF 'ExecStart=/usr/local/bin/openpath-firewall-restore.sh' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]
}

@test "create_systemd_services wires the firewall-restore service first" {
    run grep -nF 'create_firewall_restore_service' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]
}

@test "enable_services enables the firewall-restore service" {
    run grep -nF 'systemctl enable openpath-firewall-restore.service' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]
}

@test "openpath-firewall-restore.sh seeds a fail-closed ruleset when no saved rules exist" {
    local script="$PROJECT_DIR/linux/scripts/runtime/openpath-firewall-restore.sh"
    local iptables_log="$TEST_TMP_DIR/iptables.log"
    local ip6tables_log="$TEST_TMP_DIR/ip6tables.log"

    cat > "$TEST_TMP_DIR/iptables" <<EOF
#!/bin/bash
echo "\$*" >> "$iptables_log"
exit 0
EOF
    cat > "$TEST_TMP_DIR/ip6tables" <<EOF
#!/bin/bash
echo "\$*" >> "$ip6tables_log"
exit 0
EOF
    # ipset present so the script still recreates the empty allow sets.
    cat > "$TEST_TMP_DIR/ipset" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TMP_DIR/iptables" "$TEST_TMP_DIR/ip6tables" "$TEST_TMP_DIR/ipset"

    export OPENPATH_IPTABLES_RULES_V4="$TEST_TMP_DIR/missing-rules.v4"
    export OPENPATH_IPTABLES_RULES_V6="$TEST_TMP_DIR/missing-rules.v6"
    export OPENPATH_IPSET_STATE_FILE="$TEST_TMP_DIR/missing-ipsets.v4"
    export PATH="$TEST_TMP_DIR:$PATH"

    run "$script"
    [ "$status" -eq 0 ]

    # Default-deny OUTPUT with only loopback / established / localhost DNS / DHCP.
    grep -q -- "-A OUTPUT -o lo -j ACCEPT" "$iptables_log"
    grep -q -- "-A OUTPUT -p udp -d 127.0.0.1 --dport 53 -j ACCEPT" "$iptables_log"
    grep -q -- "-A OUTPUT -j DROP" "$iptables_log"
    grep -q -- "-P OUTPUT DROP" "$iptables_log"
}

@test "openpath-firewall-restore.sh recreates allow ipsets then restores saved rules" {
    local script="$PROJECT_DIR/linux/scripts/runtime/openpath-firewall-restore.sh"
    local ipset_log="$TEST_TMP_DIR/ipset.log"
    local restore_log="$TEST_TMP_DIR/restore.log"

    printf '*filter\n:OUTPUT DROP [0:0]\nCOMMIT\n' > "$TEST_TMP_DIR/rules.v4"

    cat > "$TEST_TMP_DIR/ipset" <<EOF
#!/bin/bash
echo "\$*" >> "$ipset_log"
exit 0
EOF
    cat > "$TEST_TMP_DIR/iptables-restore" <<EOF
#!/bin/bash
cat >> "$restore_log"
exit 0
EOF
    chmod +x "$TEST_TMP_DIR/ipset" "$TEST_TMP_DIR/iptables-restore"

    export OPENPATH_IPTABLES_RULES_V4="$TEST_TMP_DIR/rules.v4"
    export OPENPATH_IPTABLES_RULES_V6="$TEST_TMP_DIR/missing-rules.v6"
    export OPENPATH_IPSET_STATE_FILE="$TEST_TMP_DIR/missing-ipsets.v4"
    export PATH="$TEST_TMP_DIR:$PATH"

    run "$script"
    [ "$status" -eq 0 ]

    # Allow sets are recreated BEFORE restore (rules.v4 references them).
    grep -q "create openpath-allow-dst hash:ip timeout 300 -exist" "$ipset_log"
    # Saved ruleset was fed to iptables-restore.
    grep -q "OUTPUT DROP" "$restore_log"
}

# ============== Tests de enable_services / disable_services ==============

@test "enable_services runs without errors" {
    source "$PROJECT_DIR/linux/lib/services.sh"
    
    run enable_services
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled"* ]] || [[ "$output" == *"started"* ]]
}

@test "disable_services runs without errors" {
    source "$PROJECT_DIR/linux/lib/services.sh"
    
    run disable_services
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled"* ]] || [[ "$output" == *"Services"* ]]
}
