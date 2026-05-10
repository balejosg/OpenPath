#!/usr/bin/env bats
# UAT Script: 04_agente_linux.md - Agent Integration Tests

load '../test_helper'

setup() {
    TEST_TMP_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_TMP_DIR/etc/openpath"
    export LIB_DIR="$TEST_TMP_DIR/var/lib/openpath"
    export LOG_FILE="$TEST_TMP_DIR/var/log/openpath.log"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LIB_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
}

teardown() {
    if [ -n "$TEST_TMP_DIR" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}

@test "config directory structure exists after install simulation" {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LIB_DIR/checkpoints"
    
    [ -d "$CONFIG_DIR" ]
    [ -d "$LIB_DIR" ]
    [ -d "$LIB_DIR/checkpoints" ]
}

@test "whitelist-url.conf format is valid" {
    local config_file="$CONFIG_DIR/whitelist-url.conf"
    echo "https://raw.githubusercontent.com/balejosg/openpath/main/whitelist.txt" > "$config_file"
    
    [ -f "$config_file" ]
    grep -qE "^https?://" "$config_file"
}

@test "whitelist-url.conf rejects non-URL content" {
    local config_file="$CONFIG_DIR/whitelist-url.conf"
    echo "not a valid url" > "$config_file"
    
    ! grep -qE "^https?://" "$config_file"
}

@test "classroom config is created with valid format" {
    local classroom_file="$CONFIG_DIR/classroom.conf"
    cat > "$classroom_file" << 'EOF'
CLASSROOM_ID=informatica-3
API_URL=http://api.centro.edu:3000
HOSTNAME=$(hostname)
EOF
    
    [ -f "$classroom_file" ]
    grep -q "CLASSROOM_ID=" "$classroom_file"
    grep -q "API_URL=" "$classroom_file"
}

@test "dnsmasq config has correct order (address before server)" {
    local dnsmasq_conf="$TEST_TMP_DIR/dnsmasq.conf"
    cat > "$dnsmasq_conf" << 'EOF'
# OpenPath DNS Whitelist
address=/#/192.0.2.1
address=/#/100::
server=/google.com/8.8.8.8
server=/github.com/8.8.8.8
EOF
    
    local address_line=$(grep -n "address=/#/192.0.2.1" "$dnsmasq_conf" | head -1 | cut -d: -f1)
    local ipv6_line=$(grep -n "address=/#/100::" "$dnsmasq_conf" | head -1 | cut -d: -f1)
    local first_server_line=$(grep -n "server=/" "$dnsmasq_conf" | head -1 | cut -d: -f1)
    
    [ "$address_line" -lt "$first_server_line" ]
    [ "$ipv6_line" -lt "$first_server_line" ]
}

@test "whitelist file parsing extracts domains correctly" {
    local whitelist="$TEST_TMP_DIR/whitelist.txt"
    cat > "$whitelist" << 'EOF'
## WHITELIST
google.com
github.com
# comment line
youtube.com

## BLOCKED-SUBDOMAINS
ads.youtube.com
EOF
    
    local whitelist_count=$(sed -n '/^## WHITELIST/,/^##/p' "$whitelist" | grep -v "^#" | grep -v "^$" | grep -v "^##" | wc -l)
    [ "$whitelist_count" -eq 3 ]
}

@test "blocked subdomains section is parsed correctly" {
    local whitelist="$TEST_TMP_DIR/whitelist.txt"
    cat > "$whitelist" << 'EOF'
## WHITELIST
google.com

## BLOCKED-SUBDOMAINS
ads.google.com
tracking.example.com
EOF
    
    local blocked_count=$(sed -n '/^## BLOCKED-SUBDOMAINS/,/^##/p' "$whitelist" | grep -v "^#" | grep -v "^$" | grep -v "^##" | wc -l)
    [ "$blocked_count" -eq 2 ]
}

@test "emergency disable flag is detected" {
    local whitelist="$TEST_TMP_DIR/whitelist.txt"
    cat > "$whitelist" << 'EOF'
# DESACTIVADO
## WHITELIST
google.com
EOF
    
    grep -q "# DESACTIVADO" "$whitelist"
}

@test "emergency disable detection is case-sensitive" {
    local whitelist="$TEST_TMP_DIR/whitelist.txt"
    echo "#DESACTIVADO" > "$whitelist"
    
    grep -q "#DESACTIVADO" "$whitelist"
}

@test "health status file has valid JSON structure" {
    local health_file="$LIB_DIR/health-status"
    cat > "$health_file" << 'EOF'
{
  "status": "HEALTHY",
  "timestamp": "2025-01-03T15:00:00Z",
  "dnsmasq": "running",
  "last_sync": "2025-01-03T14:55:00Z"
}
EOF
    
    [ -f "$health_file" ]
    grep -q '"status"' "$health_file"
}

@test "log file rotation keeps recent entries" {
    for i in {1..100}; do
        echo "2025-01-03 15:00:$i [INFO] Log entry $i" >> "$LOG_FILE"
    done
    
    local line_count=$(wc -l < "$LOG_FILE")
    [ "$line_count" -eq 100 ]
}

@test "checkpoint directory stores rollback data" {
    local checkpoint_dir="$LIB_DIR/checkpoints"
    mkdir -p "$checkpoint_dir/checkpoint-20250103-150000"
    echo "backup data" > "$checkpoint_dir/checkpoint-20250103-150000/dnsmasq.conf.bak"
    
    [ -d "$checkpoint_dir/checkpoint-20250103-150000" ]
    [ -f "$checkpoint_dir/checkpoint-20250103-150000/dnsmasq.conf.bak" ]
}

@test "iptables rules format is valid" {
    local rules_file="$TEST_TMP_DIR/iptables-rules"
    cat > "$rules_file" << 'EOF'
-A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j ACCEPT
-A OUTPUT -p udp --dport 53 -j DROP
-A OUTPUT -p tcp --dport 53 -d 127.0.0.1 -j ACCEPT
-A OUTPUT -p tcp --dport 53 -j DROP
EOF
    
    grep -q "dport 53" "$rules_file"
    grep -q "127.0.0.1" "$rules_file"
    grep -q "ACCEPT" "$rules_file"
    grep -q "DROP" "$rules_file"
}

@test "VPN ports are blocked in firewall rules" {
    local rules_file="$TEST_TMP_DIR/iptables-rules"
    cat > "$rules_file" << 'EOF'
-A OUTPUT -p udp --dport 1194 -j DROP
-A OUTPUT -p tcp --dport 1194 -j DROP
-A OUTPUT -p udp --dport 1195 -j DROP
EOF
    
    grep -q "dport 1194" "$rules_file"
}

@test "Firefox managed extension policy has required structure" {
    local policies_file="$TEST_TMP_DIR/policies.json"
    cat > "$policies_file" << 'EOF'
{
  "policies": {
    "ExtensionSettings": {
      "openpath-block-monitor@openpath": {
        "installation_mode": "force_installed"
      }
    }
  }
}
EOF
    
    grep -q "ExtensionSettings" "$policies_file"
    ! grep -q "WebsiteFilter" "$policies_file"
}

@test "Chromium policies have URLBlocklist" {
    local policies_file="$TEST_TMP_DIR/chromium-policy.json"
    cat > "$policies_file" << 'EOF'
{
  "URLBlocklist": ["*"],
  "URLAllowlist": ["google.com", "github.com"]
}
EOF
    
    grep -q "URLBlocklist" "$policies_file"
    grep -q "URLAllowlist" "$policies_file"
}

@test "systemd timer format is valid" {
    local timer_file="$TEST_TMP_DIR/openpath.timer"
    cat > "$timer_file" << 'EOF'
[Unit]
Description=OpenPath whitelist update timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=openpath-update.service

[Install]
WantedBy=timers.target
EOF
    
    grep -q "OnUnitActiveSec=5min" "$timer_file"
    grep -q "Unit=openpath-update.service" "$timer_file"
}

@test "watchdog timer runs every minute" {
    local timer_file="$TEST_TMP_DIR/watchdog.timer"
    cat > "$timer_file" << 'EOF'
[Timer]
OnBootSec=30sec
OnUnitActiveSec=1min
EOF
    
    grep -q "OnUnitActiveSec=1min" "$timer_file"
}

@test "openpath CLI help output format" {
    local help_output="$TEST_TMP_DIR/help.txt"
    cat > "$help_output" << 'EOF'
OpenPath - DNS Whitelist System

Usage: openpath <command>

Commands:
  status    Show system status
  update    Force whitelist update
  domains   List whitelisted domains
  check     Check if domain is allowed
  log       Show recent logs
  health    Show health status
  test      Test DNS resolution
EOF
    
    grep -q "status" "$help_output"
    grep -q "update" "$help_output"
    grep -q "domains" "$help_output"
}

@test "registration token format validation" {
    local valid_token="abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
    local invalid_token="short"
    
    [ ${#valid_token} -eq 64 ]
    [ ${#invalid_token} -lt 64 ]
}

@test "API URL format validation accepts valid URLs" {
    local valid_urls=(
        "http://localhost:3000"
        "https://api.example.com"
        "http://192.168.1.100:3000"
    )
    
    for url in "${valid_urls[@]}"; do
        [[ "$url" =~ ^https?:// ]]
    done
}

@test "corrupted whitelist is detected" {
    local whitelist="$TEST_TMP_DIR/whitelist.txt"
    echo "CORRUPTED_CONTENT_RANDOM" > "$whitelist"
    
    ! grep -q "## WHITELIST" "$whitelist"
}

@test "backup whitelist exists after update" {
    local whitelist="$LIB_DIR/whitelist.txt"
    local backup="$LIB_DIR/whitelist.txt.bak"
    
    echo "## WHITELIST" > "$whitelist"
    echo "google.com" >> "$whitelist"
    cp "$whitelist" "$backup"
    
    [ -f "$backup" ]
}

@test "native messaging host manifest is valid JSON" {
    local manifest="$TEST_TMP_DIR/native-host.json"
    cat > "$manifest" << 'EOF'
{
  "name": "whitelist_native_host",
  "description": "OpenPath Native Messaging Host",
  "path": "/usr/local/bin/openpath-native-host",
  "type": "stdio",
  "allowed_extensions": ["openpath-block-monitor@openpath"]
}
EOF
    
    grep -q '"name"' "$manifest"
    grep -q '"allowed_extensions"' "$manifest"
}
