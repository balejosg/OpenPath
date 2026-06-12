#!/usr/bin/env bats
################################################################################
# openpath-cmd.bats - Tests para scripts/runtime/openpath-cmd.sh
################################################################################

load 'test_helper'

setup() {
    # Create temp directory for tests
    TEST_TMP_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_TMP_DIR/config"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$INSTALL_DIR/lib"
    
    # Copy libs
    cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/" 2>/dev/null || true
    
    # Create test whitelist
    create_test_whitelist "$CONFIG_DIR/whitelist.txt" >/dev/null
}

teardown() {
    if [ -n "$TEST_TMP_DIR" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}

# ============== Tests de cmd_check ==============

@test "check detecta dominio en whitelist" {
    local domain="google.com"
    local whitelist_file="$CONFIG_DIR/whitelist.txt"
    
    if grep -qi "^${domain}$" "$whitelist_file" 2>/dev/null; then
        local in_whitelist=true
    else
        local in_whitelist=false
    fi
    
    [ "$in_whitelist" = true ]
}

@test "check detecta dominio NO en whitelist" {
    local domain="malware.com"
    local whitelist_file="$CONFIG_DIR/whitelist.txt"
    
    if grep -qi "^${domain}$" "$whitelist_file" 2>/dev/null; then
        local in_whitelist=true
    else
        local in_whitelist=false
    fi
    
    [ "$in_whitelist" = false ]
}

# ============== Tests de subdominios bloqueados ==============

@test "detecta subdominio bloqueado" {
    local subdomain="ads.google.com"
    local whitelist_file="$CONFIG_DIR/whitelist.txt"
    
    # Extraer subdominios bloqueados
    local blocked=$(sed -n '/## BLOCKED-SUBDOMAINS/,/## BLOCKED-PATHS/p' "$whitelist_file" | grep -v "^#" | grep -v "^$")
    
    if echo "$blocked" | grep -qi "^${subdomain}$"; then
        local is_blocked=true
    else
        local is_blocked=false
    fi
    
    [ "$is_blocked" = true ]
}

# ============== Tests de estadísticas ==============

@test "cuenta dominios en whitelist" {
    local whitelist_file="$CONFIG_DIR/whitelist.txt"
    
    # Contar dominios en sección WHITELIST
    local count=$(sed -n '/## WHITELIST/,/## BLOCKED/p' "$whitelist_file" | grep -v "^#" | grep -v "^$" | grep -v "## BLOCKED" | wc -l)
    
    [ "$count" -eq 3 ]
}

@test "cuenta subdominios bloqueados" {
    local whitelist_file="$CONFIG_DIR/whitelist.txt"
    
    local count=$(sed -n '/## BLOCKED-SUBDOMAINS/,/## BLOCKED-PATHS/p' "$whitelist_file" | grep -v "^#" | grep -v "^$" | grep -v "## BLOCKED" | wc -l)
    
    [ "$count" -eq 2 ]
}

@test "incluye comando setup para modo aula" {
    run grep -n "setup           Setup assistant" "$PROJECT_DIR/linux/lib/runtime-cli-system.sh"
    [ "$status" -eq 0 ]
}

@test "status muestra seccion de enrollment" {
    run grep -n "Enrolled:" "$PROJECT_DIR/linux/lib/runtime-cli-system.sh"
    [ "$status" -eq 0 ]
}

@test "cmd_status reports request setup once" {
    run sh -c "awk '/^cmd_status\\(\\) \\{/ { capture = 1 } /^cmd_update\\(\\)/ { capture = 0 } capture { print }' '$PROJECT_DIR/linux/lib/runtime-cli-system.sh' | grep -c 'Requests:'"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

@test "cmd_disable reuses shared disabled-mode transition helper" {
    run grep -n "enter_disabled_mode" "$PROJECT_DIR/linux/lib/runtime-cli-system.sh"
    [ "$status" -eq 0 ]
}

@test "enroll soporta token por archivo o stdin" {
    run grep -n -- "--token-file" "$PROJECT_DIR/linux/lib/runtime-cli-commands.sh"
    [ "$status" -eq 0 ]

    run grep -n -- "--token-stdin" "$PROJECT_DIR/linux/lib/runtime-cli-commands.sh"
    [ "$status" -eq 0 ]
}

@test "setup soporta enrollment token por classroom id" {
    run grep -n -- "--classroom-id" "$PROJECT_DIR/linux/lib/runtime-cli-commands.sh"
    [ "$status" -eq 0 ]

    run grep -n -- "--enrollment-token" "$PROJECT_DIR/linux/lib/runtime-cli-commands.sh"
    [ "$status" -eq 0 ]
}

@test "setup puede pedir datos por /dev/tty cuando stdin no es interactivo" {
    run grep -n "/dev/tty" "$PROJECT_DIR/linux/lib/runtime-cli.sh"
    [ "$status" -eq 0 ]

    run grep -n "read_prompt_value" "$PROJECT_DIR/linux/lib/runtime-cli-commands.sh"
    [ "$status" -eq 0 ]
}

@test "persist_openpath_enrollment_state writes classroom runtime state atomically" {
    local helper_script="$TEST_TMP_DIR/persist-enrollment-state.sh"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"

export INSTALL_DIR="$project_dir/linux"
export ETC_CONFIG_DIR="$state_dir/etc/openpath"
export VAR_STATE_DIR="$state_dir/var/lib/openpath"
mkdir -p "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"

source "$project_dir/linux/lib/common.sh"

persist_openpath_enrollment_state \
  "https://api.openpath.test" \
  "Aula-Canary" \
  "classroom-123" \
  "https://api.openpath.test/w/token-123/whitelist.txt"

printf 'api=%s\n' "$(cat "$ETC_CONFIG_DIR/api-url.conf")"
printf 'classroom=%s\n' "$(cat "$ETC_CONFIG_DIR/classroom.conf")"
printf 'classroom_id=%s\n' "$(cat "$ETC_CONFIG_DIR/classroom-id.conf")"
printf 'whitelist=%s\n' "$(cat "$ETC_CONFIG_DIR/whitelist-url.conf")"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR"

    [ "$status" -eq 0 ]
    [[ "$output" == *"api=https://api.openpath.test"* ]]
    [[ "$output" == *"classroom=Aula-Canary"* ]]
    [[ "$output" == *"classroom_id=classroom-123"* ]]
    [[ "$output" == *"whitelist=https://api.openpath.test/w/token-123/whitelist.txt"* ]]
}

@test "persist_openpath_enrollment_state preserves existing files when validation fails" {
    local helper_script="$TEST_TMP_DIR/persist-enrollment-state-invalid.sh"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"

export INSTALL_DIR="$project_dir/linux"
export ETC_CONFIG_DIR="$state_dir/etc/openpath"
export VAR_STATE_DIR="$state_dir/var/lib/openpath"
mkdir -p "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"

source "$project_dir/linux/lib/common.sh"

printf '%s' 'https://existing.example/api' > "$ETC_CONFIG_DIR/api-url.conf"
printf '%s' 'Existing Classroom' > "$ETC_CONFIG_DIR/classroom.conf"
printf '%s' 'existing-id' > "$ETC_CONFIG_DIR/classroom-id.conf"
printf '%s' 'https://existing.example/w/original/whitelist.txt' > "$ETC_CONFIG_DIR/whitelist-url.conf"

if persist_openpath_enrollment_state \
  "https://api.openpath.test" \
  "Broken Classroom" \
  "broken-id" \
  "whitelist-dnsmasq/whitelist-url doesn't exist"; then
  echo "unexpected-success"
  exit 1
fi

printf 'api=%s\n' "$(cat "$ETC_CONFIG_DIR/api-url.conf")"
printf 'classroom=%s\n' "$(cat "$ETC_CONFIG_DIR/classroom.conf")"
printf 'classroom_id=%s\n' "$(cat "$ETC_CONFIG_DIR/classroom-id.conf")"
printf 'whitelist=%s\n' "$(cat "$ETC_CONFIG_DIR/whitelist-url.conf")"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR"

    [ "$status" -eq 0 ]
    [[ "$output" == *"api=https://existing.example/api"* ]]
    [[ "$output" == *"classroom=Existing Classroom"* ]]
    [[ "$output" == *"classroom_id=existing-id"* ]]
    [[ "$output" == *"whitelist=https://existing.example/w/original/whitelist.txt"* ]]
    [[ "$output" != *"unexpected-success"* ]]
}

@test "health treats remote-disabled fail-open mode as expected state" {
    local whitelist_file="$CONFIG_DIR/whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-cmd-health.sh"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
extracted_script="$state_dir/cmd-health.sh"

export VERSION="test"
export WHITELIST_FILE="$whitelist_file"
export FIREFOX_POLICIES="$state_dir/firefox-policies.json"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export VAR_STATE_DIR="$state_dir"
export RED=""
export GREEN=""
export YELLOW=""
export BLUE=""
export NC=""

: > "$FIREFOX_POLICIES"
: > "$SYSTEM_DISABLED_FLAG"

timeout() {
    shift
    "$@"
}

dig() {
    case "$2" in
        google.com)
            echo "142.250.184.14"
            ;;
        facebook.com)
            echo "0.0.0.0"
            ;;
    esac
}

iptables() {
    printf "Chain OUTPUT (policy ACCEPT)\n"
}

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

find() {
    return 1
}

source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_health\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_health
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"system disabled remotely"* ]]
    [[ "$output" != *"ISSUES DETECTED"* ]]
}

@test "health resolves a domain from the active whitelist instead of hard-coded google.com" {
    local whitelist_file="$TEST_TMP_DIR/google-es-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-health-whitelist-domain.sh"

    cat > "$whitelist_file" <<'EOF'
## WHITELIST
google.es
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
extracted_script="$state_dir/cmd-health.sh"

export VERSION="test"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export WHITELIST_FILE="$whitelist_file"
export FIREFOX_POLICIES="$state_dir/firefox-policies.json"
touch "$FIREFOX_POLICIES"

GREEN=""
RED=""
YELLOW=""
BLUE=""
NC=""

timeout() {
    shift
    "$@"
}

dig() {
    case "$2" in
        google.es)
            echo "216.58.204.163"
            ;;
        facebook.com)
            echo "0.0.0.0"
            ;;
        *)
            return 1
            ;;
    esac
}

check_firewall_status() { return 0; }
has_firewall_loopback_rule() { return 0; }
verify_firewall_rules() { return 0; }
check_doh_block_status() { echo "active"; return 0; }
check_vpn_block_status() { echo "active"; return 0; }
check_tor_block_status() { echo "active"; return 0; }

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

find() {
    return 1
}

source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_health\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_health
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Whitelisted domain (google.es): ✓ resolves"* ]]
    [[ "$output" != *"Whitelisted domain (google.com)"* ]]
    [[ "$output" != *"ISSUES DETECTED"* ]]
}

@test "health fails when a real non-whitelisted domain resolves to a public address" {
    local whitelist_file="$TEST_TMP_DIR/google-es-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-health-public-blocked-domain.sh"

    cat > "$whitelist_file" <<'EOF'
## WHITELIST
google.es
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
extracted_script="$state_dir/cmd-health.sh"

export VERSION="test"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export WHITELIST_FILE="$whitelist_file"
export FIREFOX_POLICIES="$state_dir/firefox-policies.json"
touch "$FIREFOX_POLICIES"

GREEN=""
RED=""
YELLOW=""
BLUE=""
NC=""

timeout() {
    shift
    "$@"
}

dig() {
    case "$2" in
        google.es)
            echo "216.58.204.163"
            ;;
        facebook.com)
            echo "157.240.5.35"
            ;;
        *)
            return 1
            ;;
    esac
}

check_firewall_status() { return 0; }
has_firewall_loopback_rule() { return 0; }
verify_firewall_rules() { return 0; }
check_doh_block_status() { echo "active"; return 0; }
check_vpn_block_status() { echo "active"; return 0; }
check_tor_block_status() { echo "active"; return 0; }

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

find() {
    return 1
}

source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_health\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_health
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Blocked domain (facebook.com): ✗ NOT BLOCKED"* ]]
    [[ "$output" == *"ISSUES DETECTED"* ]]
}

@test "health fails in enrolled mode when Firefox extension readiness marker is missing" {
    local whitelist_file="$TEST_TMP_DIR/google-es-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-health-missing-firefox-extension.sh"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"

    cat > "$whitelist_file" <<'EOF'
## WHITELIST
google.es
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
etc_dir="$4"
extracted_script="$state_dir/cmd-health.sh"

export VERSION="test"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export WHITELIST_FILE="$whitelist_file"
export FIREFOX_POLICIES="$state_dir/firefox-policies.json"
export FIREFOX_EXTENSION_READY_FILE="$state_dir/firefox-extension-ready"
export ETC_CONFIG_DIR="$etc_dir"
cat > "$FIREFOX_POLICIES" <<'JSON'
{"policies":{"ExtensionSettings":{"openpath-block-monitor@openpath":{"installation_mode":"force_installed","install_url":"https://control.example/api/extensions/firefox/openpath.xpi"}}}}
JSON

GREEN=""
RED=""
YELLOW=""
BLUE=""
NC=""

timeout() {
    shift
    "$@"
}

dig() {
    case "$2" in
        google.es)
            echo "216.58.204.163"
            ;;
        facebook.com)
            echo "0.0.0.0"
            ;;
        *)
            return 1
            ;;
    esac
}

check_firewall_status() { return 0; }
has_firewall_loopback_rule() { return 0; }
verify_firewall_rules() { return 0; }
check_doh_block_status() { echo "active"; return 0; }
check_vpn_block_status() { echo "active"; return 0; }
check_tor_block_status() { echo "active"; return 0; }

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

find() {
    return 1
}

source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_health\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_health
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file" "$etc_dir"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Firefox extension: ✗ not registered"* ]]
    [[ "$output" == *"ISSUES DETECTED"* ]]
}

@test "health allows deferred Firefox extension registration during enrollment bootstrap" {
    local whitelist_file="$TEST_TMP_DIR/google-es-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-health-deferred-firefox-extension.sh"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"

    cat > "$whitelist_file" <<'EOF'
## WHITELIST
google.es
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
etc_dir="$4"
extracted_script="$state_dir/cmd-health.sh"

export VERSION="test"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export WHITELIST_FILE="$whitelist_file"
export FIREFOX_POLICIES="$state_dir/firefox-policies.json"
export FIREFOX_EXTENSION_READY_FILE="$state_dir/firefox-extension-ready"
export FIREFOX_NATIVE_HOST_DIR="$state_dir/native-hosts"
export OPENPATH_NATIVE_HOST_INSTALL_DIR="$state_dir/native-host-bin"
export ETC_CONFIG_DIR="$etc_dir"
export OPENPATH_ALLOW_DEFERRED_FIREFOX_REGISTRATION=1
mkdir -p "$FIREFOX_NATIVE_HOST_DIR" "$OPENPATH_NATIVE_HOST_INSTALL_DIR"
printf '{}' > "$FIREFOX_NATIVE_HOST_DIR/whitelist_native_host.json"
printf '#!/bin/sh\n' > "$OPENPATH_NATIVE_HOST_INSTALL_DIR/openpath-native-host.py"
chmod +x "$OPENPATH_NATIVE_HOST_INSTALL_DIR/openpath-native-host.py"
cat > "$FIREFOX_POLICIES" <<'JSON'
{"policies":{"ExtensionSettings":{"openpath-block-monitor@openpath":{"installation_mode":"force_installed","install_url":"https://control.example/api/extensions/firefox/openpath.xpi"}}}}
JSON

GREEN=""
RED=""
YELLOW=""
BLUE=""
NC=""

timeout() {
    shift
    "$@"
}

dig() {
    case "$2" in
        google.es)
            echo "216.58.204.163"
            ;;
        facebook.com)
            echo "0.0.0.0"
            ;;
        *)
            return 1
            ;;
    esac
}

check_firewall_status() { return 0; }
has_firewall_loopback_rule() { return 0; }
verify_firewall_rules() { return 0; }
check_doh_block_status() { echo "active"; return 0; }
check_vpn_block_status() { echo "active"; return 0; }
check_tor_block_status() { echo "active"; return 0; }

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

find() {
    return 1
}

source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_health\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_health
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file" "$etc_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox extension: ⚠ registration deferred"* ]]
    [[ "$output" == *"Overall status:"* ]]
    [[ "$output" == *"HEALTHY"* ]]
    [[ "$output" != *"ISSUES DETECTED"* ]]
}

@test "health fails in enrolled mode when Firefox marker records disabled unsigned extension" {
    local whitelist_file="$TEST_TMP_DIR/google-es-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-health-disabled-firefox-extension.sh"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"

    cat > "$whitelist_file" <<'EOF'
## WHITELIST
google.es
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
etc_dir="$4"
extracted_script="$state_dir/cmd-health.sh"

export VERSION="test"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export WHITELIST_FILE="$whitelist_file"
export FIREFOX_POLICIES="$state_dir/firefox-policies.json"
export FIREFOX_EXTENSION_READY_FILE="$state_dir/firefox-extension-ready"
export ETC_CONFIG_DIR="$etc_dir"
export OPENPATH_ALLOW_DEFERRED_FIREFOX_REGISTRATION=1
cat > "$FIREFOX_POLICIES" <<'JSON'
{"policies":{"ExtensionSettings":{"openpath-block-monitor@openpath":{"installation_mode":"force_installed","install_url":"https://control.example/api/extensions/firefox/openpath.xpi"}}}}
JSON
cat > "$FIREFOX_EXTENSION_READY_FILE" <<'EOF_MARKER'
extension_id=openpath-block-monitor@openpath
target_count=1
registered_count=0
profile=student|/home/student|/home/student/.mozilla/firefox/openpath.default|disabled|extensions.json-disabled;active=false;userDisabled=true;signedState=-1;location=app-system-share
EOF_MARKER

GREEN=""
RED=""
YELLOW=""
BLUE=""
NC=""

timeout() {
    shift
    "$@"
}

dig() {
    case "$2" in
        google.es)
            echo "216.58.204.163"
            ;;
        facebook.com)
            echo "0.0.0.0"
            ;;
        *)
            return 1
            ;;
    esac
}

check_firewall_status() { return 0; }
has_firewall_loopback_rule() { return 0; }
verify_firewall_rules() { return 0; }
check_doh_block_status() { echo "active"; return 0; }
check_vpn_block_status() { echo "active"; return 0; }
check_tor_block_status() { echo "active"; return 0; }

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

find() {
    return 1
}

source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_health\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_health
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file" "$etc_dir"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Firefox extension: ✗ disabled or unsigned"* ]]
    [[ "$output" != *"registration deferred"* ]]
    [[ "$output" == *"active=false"* ]]
    [[ "$output" == *"userDisabled=true"* ]]
    [[ "$output" == *"signedState=-1"* ]]
    [[ "$output" == *"ISSUES DETECTED"* ]]
}

@test "health reports issues when firewall verification fails despite DNS rules being present" {
    local helper_script="$TEST_TMP_DIR/run-health-firewall-verification.sh"
    local whitelist_file="$CONFIG_DIR/whitelist.txt"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
extracted_script="$state_dir/cmd-health.sh"

export VERSION="test"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export WHITELIST_FILE="$whitelist_file"
export FIREFOX_POLICIES="$state_dir/firefox-policies.json"
touch "$FIREFOX_POLICIES"

GREEN=""
RED=""
YELLOW=""
BLUE=""
NC=""

timeout() {
    shift
    "$@"
}

dig() {
    case "$2" in
        google.com)
            echo "142.250.184.14"
            ;;
        facebook.com)
            echo "0.0.0.0"
            ;;
    esac
}

iptables() {
    cat <<'RULES'
Chain OUTPUT (policy ACCEPT)
target     prot opt source    destination
ACCEPT     udp  --  anywhere  127.0.0.1   udp dpt:53
ACCEPT     tcp  --  anywhere  127.0.0.1   tcp dpt:53
DROP       udp  --  anywhere  anywhere    udp dpt:53
DROP       tcp  --  anywhere  anywhere    tcp dpt:53
RULES
}

check_firewall_status() {
    echo "active"
    return 0
}

has_firewall_loopback_rule() {
    return 0
}

verify_firewall_rules() {
    return 1
}

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

find() {
    return 1
}

source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_health\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_health
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file"

    [ "$status" -eq 1 ]
    [[ "$output" == *"ISSUES DETECTED"* ]]
}

@test "health uses firewall helpers instead of parsing iptables list output directly" {
    local helper_script="$TEST_TMP_DIR/run-health-firewall-helpers.sh"
    local whitelist_file="$CONFIG_DIR/whitelist.txt"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
extracted_script="$state_dir/cmd-health.sh"

export VERSION="test"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export WHITELIST_FILE="$whitelist_file"
export FIREFOX_POLICIES="$state_dir/firefox-policies.json"
touch "$FIREFOX_POLICIES"

GREEN=""
RED=""
YELLOW=""
BLUE=""
NC=""

timeout() {
    shift
    "$@"
}

dig() {
    case "$2" in
        google.com)
            echo "142.250.184.14"
            ;;
        facebook.com)
            echo "0.0.0.0"
            ;;
    esac
}

iptables() {
    printf "Chain OUTPUT (policy ACCEPT)\n"
}

check_firewall_status() {
    echo "active"
    return 0
}

has_firewall_loopback_rule() {
    return 0
}

verify_firewall_rules() {
    return 0
}

check_doh_block_status() {
    echo "active"
    return 0
}

check_vpn_block_status() {
    echo "active"
    return 0
}

check_tor_block_status() {
    echo "active"
    return 0
}

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

find() {
    return 1
}

source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_health\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_health
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"DNS blocking rules: ✓ active"* ]]
    [[ "$output" == *"Loopback rule: ✓ present"* ]]
    [[ "$output" == *"DoH bypass block: ✓ active"* ]]
    [[ "$output" == *"VPN bypass block: ✓ active"* ]]
    [[ "$output" == *"Tor bypass block: ✓ active"* ]]
    [[ "$output" != *"ISSUES DETECTED"* ]]
}

@test "cmd_status probes active whitelist domain and treats sinkhole as blocked" {
    local whitelist_file="$TEST_TMP_DIR/google-es-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-cmd-status-dns-probe.sh"
    local probe_log="$TEST_TMP_DIR/probes.log"

    cat > "$whitelist_file" <<'EOF'
## WHITELIST
google.es
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
probe_log="$4"
extracted_script="$state_dir/cmd-status.sh"

export VERSION="test"
export WHITELIST_FILE="$whitelist_file"
export VAR_STATE_DIR="$state_dir"
export ETC_CONFIG_DIR="$state_dir/etc/openpath"
export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
export RED=""
export GREEN=""
export YELLOW=""
export BLUE=""
export NC=""
mkdir -p "$ETC_CONFIG_DIR"

timeout() {
    shift
    "$@"
}

dig() {
    printf '%s\n' "$2" >> "$probe_log"
    case "$2" in
        google.es)
            echo "216.58.204.163"
            return 0
            ;;
        google.com)
            echo "0.0.0.0"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

source "$project_dir/linux/lib/common.sh"
source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_status\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_status
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file" "$probe_log"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Resolution: ● working"* ]]
    grep -qx "google.es" "$probe_log"
    ! grep -qx "google.com" "$probe_log"
}

@test "cmd_status reflects the DoH/VPN/Tor bypass-block state" {
    local whitelist_file="$TEST_TMP_DIR/bypass-status-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-cmd-status-bypass.sh"

    cat > "$whitelist_file" <<'EOF'
## WHITELIST
google.es
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
extracted_script="$state_dir/cmd-status.sh"

export VERSION="test"
export WHITELIST_FILE="$whitelist_file"
export VAR_STATE_DIR="$state_dir"
export ETC_CONFIG_DIR="$state_dir/etc/openpath"
export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
export RED=""
export GREEN=""
export YELLOW=""
export BLUE=""
export NC=""
mkdir -p "$ETC_CONFIG_DIR"

timeout() {
    shift
    "$@"
}

dig() {
    case "$2" in
        google.es)
            echo "216.58.204.163"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

check_doh_block_status() { echo "active"; return 0; }
check_vpn_block_status() { echo "disabled"; return 0; }
check_tor_block_status() { echo "inactive"; return 1; }

source "$project_dir/linux/lib/common.sh"
source "$project_dir/linux/lib/dns.sh"
awk '/^cmd_status\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_status
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Bypass blocks:"* ]]
    [[ "$output" == *"DoH block: ● active"* ]]
    [[ "$output" == *"VPN block: ● disabled"* ]]
    [[ "$output" == *"Tor block: ● inactive"* ]]
}

@test "cmd_status reports runtime dependency overlay counts without sensitive host details" {
    local helper_script="$TEST_TMP_DIR/run-cmd-status-runtime-dependency.sh"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/cmd-status.sh"

export VERSION="test"
export VAR_STATE_DIR="$state_dir/var/lib/openpath"
export ETC_CONFIG_DIR="$state_dir/etc/openpath"
export WHITELIST_FILE="$VAR_STATE_DIR/whitelist.txt"
export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
export RUNTIME_DEPENDENCY_QUEUE_DIR="$VAR_STATE_DIR/runtime-dependency-queue"
export RUNTIME_DEPENDENCY_OVERLAY_FILE="$VAR_STATE_DIR/runtime-dependency-overlay.json"
export RED=""
export GREEN=""
export YELLOW=""
export BLUE=""
export NC=""
mkdir -p "$ETC_CONFIG_DIR" "$VAR_STATE_DIR" "$RUNTIME_DEPENDENCY_QUEUE_DIR"
cat > "$WHITELIST_FILE" <<'WHITELIST'
## WHITELIST
allowed.example
WHITELIST
cat > "$RUNTIME_DEPENDENCY_OVERLAY_FILE" <<'JSON'
{"version":1,"entries":[
  {"anchorHost":"allowed.example","dependencyHost":"cdn.example","requestTypes":["fetch"],"firstSeen":"2099-01-01T00:00:00Z","lastSeen":"2099-01-01T00:00:00Z","expiresAt":"2099-01-02T00:00:00Z","source":"firefox-webrequest-local"}
]}
JSON
printf '%s\n' '{"anchorHost":"allowed.example","dependencyHost":"queued.example","requestType":"fetch"}' > "$RUNTIME_DEPENDENCY_QUEUE_DIR/pending.json"

systemctl() {
    [ "$1" = "is-active" ] && return 0
    return 1
}

dig() {
    echo "216.58.204.163"
}

source "$project_dir/linux/lib/common.sh"
source "$project_dir/linux/lib/dns.sh"
source "$project_dir/linux/lib/runtime-dependency-overlay.sh"
awk '/^cmd_status\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > "$extracted_script"
source "$extracted_script"

cmd_status
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Runtime dependencies: 1 active"* ]]
    [[ "$output" == *"Runtime dependency queue: 1 pending"* ]]
    [[ "$output" != *"cdn.example"* ]]
    [[ "$output" != *"queued.example"* ]]
}

@test "cmd_check reports sinkhole-only answers as not resolving" {
    local whitelist_file="$TEST_TMP_DIR/google-es-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-cmd-check-sinkhole.sh"

    cat > "$whitelist_file" <<'EOF'
## WHITELIST
google.es
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
extracted_script="$state_dir/cmd-check.sh"

export WHITELIST_FILE="$whitelist_file"
export RED=""
export GREEN=""
export YELLOW=""
export BLUE=""
export NC=""

timeout() {
    shift
    "$@"
}

dig() {
    echo "0.0.0.0"
    return 0
}

source "$project_dir/linux/lib/dns.sh"
awk '/^normalize_check_target\(\) \{/,/^cmd_health\(\) \{/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" | sed '$d' > "$extracted_script"
source "$extracted_script"

cmd_check facebook.com
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Resolves: ✗"* ]]
    [[ "$output" != *"→ 0.0.0.0"* ]]
}

@test "cmd_check separates whitelist from blocked subdomains and paths" {
    local whitelist_file="$TEST_TMP_DIR/policy-sections.txt"
    local helper_script="$TEST_TMP_DIR/run-cmd-check-sections.sh"

    cat > "$whitelist_file" <<'EOF'
## WHITELIST
allowed.example

## BLOCKED-SUBDOMAINS
chat.allowed.example

## BLOCKED-PATHS
lessons.example/games
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"
extracted_script="$state_dir/cmd-check.sh"

export WHITELIST_FILE="$whitelist_file"
export RED=""
export GREEN=""
export YELLOW=""
export BLUE=""
export NC=""

log() { :; }
protect_control_plane_rules() { :; }
timeout() {
    shift
    "$@"
}
dig() {
    echo "0.0.0.0"
    return 0
}

source "$project_dir/linux/lib/common.sh"
source "$project_dir/linux/lib/dns-runtime.sh"
awk '/^normalize_check_target\(\) \{/,/^cmd_health\(\) \{/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" | sed '$d' > "$extracted_script"
source "$extracted_script"

cmd_check allowed.example
cmd_check chat.allowed.example
cmd_check lessons.example/games
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$TEST_TMP_DIR" "$whitelist_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Checking: allowed.example"* ]]
    [[ "$output" == *"In whitelist: ✓ YES"* ]]
    [[ "$output" == *"Checking: chat.allowed.example"* ]]
    [[ "$output" == *"Blocked by subdomain: ✓ YES"* ]]
    [[ "$output" == *"Checking: lessons.example/games"* ]]
    [[ "$output" == *"Blocked by path: ✓ YES"* ]]
    [ "$(grep -o "In whitelist: ✓ YES" <<< "$output" | wc -l)" -eq 1 ]
}

@test "read-only commands that need protected config auto-elevate through sudoers" {
    run grep -n 'READ_ONLY_ROOT_COMMANDS=.*status' "$PROJECT_DIR/linux/scripts/runtime/openpath-cmd.sh"
    [ "$status" -eq 0 ]

    run grep -n 'sudo -n' "$PROJECT_DIR/linux/scripts/runtime/openpath-cmd.sh"
    [ "$status" -eq 0 ]
}

@test "reset_cached_whitelist_state clears cached whitelist and remote-disabled markers" {
    local helper_script="$TEST_TMP_DIR/run-reset-cached-whitelist-state.sh"
    local state_dir="$TEST_TMP_DIR/state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/reset-cached-whitelist-state.sh"

export WHITELIST_FILE="$state_dir/whitelist.txt"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export DNSMASQ_CONF_HASH="$state_dir/dnsmasq.hash"
export BROWSER_POLICIES_HASH="$state_dir/browser-policies.hash"

: > "$WHITELIST_FILE"
: > "${WHITELIST_FILE}.etag"
: > "$SYSTEM_DISABLED_FLAG"
: > "$DNSMASQ_CONF_HASH"
: > "$BROWSER_POLICIES_HASH"

awk '/^reset_cached_whitelist_state\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-commands.sh" > "$extracted_script"
source "$extracted_script"

reset_cached_whitelist_state

test ! -e "$WHITELIST_FILE"
test ! -e "${WHITELIST_FILE}.etag"
test ! -e "$SYSTEM_DISABLED_FLAG"
test ! -e "$DNSMASQ_CONF_HASH"
test ! -e "$BROWSER_POLICIES_HASH"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
}

@test "cmd_enroll persists API connectivity but not tokenized whitelist when registration fails" {
    local helper_script="$TEST_TMP_DIR/run-cmd-enroll-registration-failure.sh"
    local state_dir="$TEST_TMP_DIR/enroll-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/cmd-enroll.sh"

export ETC_CONFIG_DIR="$state_dir/etc"
export INSTALL_DIR="$project_dir/linux"
export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
export WHITELIST_FILE="$state_dir/whitelist.txt"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export DNSMASQ_CONF_HASH="$state_dir/dnsmasq.hash"
export BROWSER_POLICIES_HASH="$state_dir/browser.hash"

mkdir -p "$ETC_CONFIG_DIR"

GREEN=""
RED=""
YELLOW=""
BLUE=""
NC=""

source "$project_dir/linux/lib/common.sh"

normalize_machine_name_value() { printf '%s\n' "$1"; }
register_machine() { REGISTER_RESPONSE='{"success":false}'; return 1; }
persist_machine_name() { return 0; }
reset_cached_whitelist_state() { :; }
deactivate_firewall() { return 0; }
restore_dns() { return 0; }
generate_dnsmasq_config() { return 0; }
restart_dnsmasq() { return 0; }
free_port_53() { return 0; }
configure_upstream_dns() { return 0; }
configure_resolv_conf() { return 0; }
create_dns_init_script() { return 0; }
systemctl() { return 0; }
dpkg() { printf 'Version: 4.1.15-1\n'; }
hostname() { printf 'max12\n'; }

{
    awk '/^prepare_registration_connectivity\(\) \{/,/^}/' \
        "$project_dir/linux/lib/runtime-cli-commands.sh"
    awk '/^activate_enrolled_connectivity\(\) \{/,/^}/' \
        "$project_dir/linux/lib/runtime-cli-commands.sh"
    awk '/^cmd_enroll\(\) \{/,/^}/' \
        "$project_dir/linux/lib/runtime-cli-commands.sh"
    awk '/^reset_cached_whitelist_state\(\) \{/,/^}/' \
        "$project_dir/linux/lib/runtime-cli-commands.sh"
} > "$extracted_script"
set +e
(
    source "$extracted_script"
    cmd_enroll --classroom 'Room 101' --api-url 'https://control.example' --classroom-id 'cls_123' --enrollment-token 'enroll-token'
)
status=$?
set -e

printf 'status=%s\n' "$status"
printf 'api_url_exists=%s\n' "$(test -f "$ETC_CONFIG_DIR/api-url.conf" && echo yes || echo no)"
printf 'classroom_exists=%s\n' "$(test -f "$ETC_CONFIG_DIR/classroom.conf" && echo yes || echo no)"
printf 'classroom_id_exists=%s\n' "$(test -f "$ETC_CONFIG_DIR/classroom-id.conf" && echo yes || echo no)"
printf 'whitelist_url_exists=%s\n' "$(test -f "$WHITELIST_URL_CONF" && echo yes || echo no)"
printf 'api_url=%s\n' "$(cat "$ETC_CONFIG_DIR/api-url.conf" 2>/dev/null || true)"
printf 'classroom=%s\n' "$(cat "$ETC_CONFIG_DIR/classroom.conf" 2>/dev/null || true)"
printf 'classroom_id=%s\n' "$(cat "$ETC_CONFIG_DIR/classroom-id.conf" 2>/dev/null || true)"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=1"* ]]
    [[ "$output" == *"api_url_exists=yes"* ]]
    [[ "$output" == *"classroom_exists=yes"* ]]
    [[ "$output" == *"classroom_id_exists=yes"* ]]
    [[ "$output" == *"whitelist_url_exists=no"* ]]
    [[ "$output" == *"api_url=https://control.example"* ]]
    [[ "$output" == *"classroom=Room 101"* ]]
    [[ "$output" == *"classroom_id=cls_123"* ]]
}

@test "activate_enrolled_connectivity detects upstream DNS before configuring dnsmasq" {
    local helper_script="$TEST_TMP_DIR/activate-enrolled-dns.sh"
    local state_dir="$TEST_TMP_DIR/registration-dns-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/activate-enrolled-connectivity.sh"

export ETC_CONFIG_DIR="$state_dir/etc"
export VAR_STATE_DIR="$state_dir/var"
export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
export WHITELIST_FILE="$state_dir/whitelist.txt"
export DNSMASQ_CONF="$state_dir/openpath.conf"
export PRIMARY_DNS=""

mkdir -p "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"

source "$project_dir/linux/lib/common.sh"

detect_primary_dns() {
    printf '%s\n' "9.9.9.9"
}

generate_dnsmasq_config() {
    printf 'primary=%s\n' "$PRIMARY_DNS" > "$DNSMASQ_CONF"
}

free_port_53() { return 0; }
configure_upstream_dns() { return 0; }
configure_resolv_conf() { generate_dnsmasq_config; return 0; }
create_dns_init_script() { return 0; }
restart_dnsmasq() { return 0; }
systemctl() { return 0; }

awk '/^activate_enrolled_connectivity\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-commands.sh" > "$extracted_script"

source "$extracted_script"
activate_enrolled_connectivity

cat "$DNSMASQ_CONF"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"primary=9.9.9.9"* ]]
}

@test "activate_enrolled_connectivity restarts dnsmasq after freeing port 53" {
    local helper_script="$TEST_TMP_DIR/activate-enrolled-dnsmasq.sh"
    local state_dir="$TEST_TMP_DIR/activate-enrolled-dnsmasq-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/activate-enrolled-connectivity.sh"

export CALLS_FILE="$state_dir/calls"
export PRIMARY_DNS="9.9.9.9"

source "$project_dir/linux/lib/common.sh"

record_call() {
    printf '%s\n' "$1" >> "$CALLS_FILE"
}

detect_primary_dns() { record_call "detect_primary_dns"; printf '9.9.9.9\n'; }
free_port_53() { record_call "free_port_53"; return 0; }
configure_upstream_dns() { record_call "configure_upstream_dns"; return 0; }
configure_resolv_conf() { record_call "configure_resolv_conf"; return 0; }
create_dns_init_script() { record_call "create_dns_init_script"; return 0; }
generate_dnsmasq_config() { record_call "generate_dnsmasq_config"; return 0; }
restart_dnsmasq() { record_call "restart_dnsmasq"; return 0; }
systemctl() {
    if [ "${1:-}" = "is-active" ] && [ "${2:-}" = "--quiet" ] && [ "${3:-}" = "dnsmasq" ]; then
        return 0
    fi
    if [ "${1:-}" = "stop" ] && [ "${2:-}" = "dnsmasq" ]; then
        record_call "stop_dnsmasq"
        return 0
    fi
    if [ "${1:-}" = "daemon-reload" ]; then
        record_call "daemon_reload"
        return 0
    fi
    return 0
}

awk '/^activate_enrolled_connectivity\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-commands.sh" > "$extracted_script"

source "$extracted_script"
activate_enrolled_connectivity

cat "$CALLS_FILE"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"stop_dnsmasq"* ]]
    [[ "$output" == *"free_port_53"* ]]
    [[ "$output" == *"configure_upstream_dns"* ]]
    [[ "$output" == *"configure_resolv_conf"* ]]
    [[ "$output" == *"create_dns_init_script"* ]]
    [[ "$output" == *"generate_dnsmasq_config"* ]]
    [[ "$output" == *"restart_dnsmasq"* ]]
}

@test "prepare_registration_connectivity restores the system resolver before registration when dnsmasq is active" {
    local helper_script="$TEST_TMP_DIR/prepare-registration-resolver.sh"
    local state_dir="$TEST_TMP_DIR/registration-resolver-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/prepare-registration-connectivity.sh"

export ETC_CONFIG_DIR="$state_dir/etc"
export VAR_STATE_DIR="$state_dir/var"
export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
export WHITELIST_FILE="$state_dir/whitelist.txt"
export DNSMASQ_CONF="$state_dir/openpath.conf"
export CALLS_FILE="$state_dir/calls"

mkdir -p "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"

source "$project_dir/linux/lib/common.sh"

record_call() {
    printf '%s\n' "$1" >> "$CALLS_FILE"
}

persist_openpath_classroom_runtime_config() {
    record_call "persist:$1:$2:$3"
    return 0
}
deactivate_firewall() { record_call "deactivate_firewall"; return 0; }
restore_dns() { record_call "restore_dns"; return 0; }
generate_dnsmasq_config() { record_call "generate_dnsmasq_config"; return 0; }
restart_dnsmasq() { record_call "restart_dnsmasq"; return 0; }
systemctl() {
    [ "${1:-}" = "is-active" ] && [ "${2:-}" = "--quiet" ] && [ "${3:-}" = "dnsmasq" ]
}

awk '/^prepare_registration_connectivity\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-commands.sh" > "$extracted_script"

source "$extracted_script"
prepare_registration_connectivity "https://control.example" "Room 101" "cls_123"

cat "$CALLS_FILE"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"persist:https://control.example:Room 101:cls_123"* ]]
    [[ "$output" == *"deactivate_firewall"* ]]
    [[ "$output" == *"restore_dns"* ]]
    [[ "$output" != *"generate_dnsmasq_config"* ]]
    [[ "$output" != *"restart_dnsmasq"* ]]
}

@test "prepare_registration_connectivity restores DNS before registration when resolv.conf points to local dnsmasq" {
    local helper_script="$TEST_TMP_DIR/prepare-registration-local-resolver.sh"
    local state_dir="$TEST_TMP_DIR/registration-local-resolver-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/prepare-registration-connectivity.sh"

export ETC_CONFIG_DIR="$state_dir/etc"
export VAR_STATE_DIR="$state_dir/var"
export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
export WHITELIST_FILE="$state_dir/whitelist.txt"
export DNSMASQ_CONF="$state_dir/openpath.conf"
export OPENPATH_RESOLV_CONF="$state_dir/resolv.conf"
export CALLS_FILE="$state_dir/calls"

mkdir -p "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"
printf 'nameserver 127.0.0.1\n' > "$OPENPATH_RESOLV_CONF"

source "$project_dir/linux/lib/common.sh"

record_call() {
    printf '%s\n' "$1" >> "$CALLS_FILE"
}

persist_openpath_classroom_runtime_config() {
    record_call "persist:$1:$2:$3"
    return 0
}
deactivate_firewall() { record_call "deactivate_firewall"; return 0; }
restore_dns() { record_call "restore_dns"; return 0; }
generate_dnsmasq_config() { record_call "generate_dnsmasq_config"; return 0; }
restart_dnsmasq() { record_call "restart_dnsmasq"; return 0; }
systemctl() {
    if [ "${1:-}" = "is-active" ] && [ "${2:-}" = "--quiet" ] && [ "${3:-}" = "dnsmasq" ]; then
        return 3
    fi
    return 0
}

awk '/^prepare_registration_connectivity\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-commands.sh" > "$extracted_script"

source "$extracted_script"
prepare_registration_connectivity "https://control.example" "Room 101" "cls_123"

cat "$CALLS_FILE"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"persist:https://control.example:Room 101:cls_123"* ]]
    [[ "$output" == *"deactivate_firewall"* ]]
    [[ "$output" == *"restore_dns"* ]]
    [[ "$output" != *"generate_dnsmasq_config"* ]]
    [[ "$output" != *"restart_dnsmasq"* ]]
}

@test "cmd_enroll persists api, classroom, and tokenized whitelist together after successful registration" {
    local helper_script="$TEST_TMP_DIR/run-cmd-enroll-success.sh"
    local state_dir="$TEST_TMP_DIR/enroll-success-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/cmd-enroll.sh"

export ETC_CONFIG_DIR="$state_dir/etc"
export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
export WHITELIST_FILE="$state_dir/whitelist.txt"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export DNSMASQ_CONF_HASH="$state_dir/dnsmasq.hash"
export BROWSER_POLICIES_HASH="$state_dir/browser.hash"

mkdir -p "$ETC_CONFIG_DIR"

GREEN=""
RED=""
YELLOW=""
BLUE=""
NC=""

source "$project_dir/linux/lib/common.sh"

normalize_machine_name_value() { printf '%s\n' "$1"; }
register_machine() {
    TOKENIZED_URL='https://control.example/w/token123/whitelist.txt'
    REGISTERED_CLASSROOM_NAME='Room 201'
    REGISTERED_CLASSROOM_ID='cls_201'
    REGISTERED_MACHINE_NAME='max12-scoped'
    return 0
}
persist_machine_name() { printf '%s\n' "$1" > "$ETC_CONFIG_DIR/persisted-machine-name"; return 0; }
reset_cached_whitelist_state() { :; }
deactivate_firewall() { return 0; }
restore_dns() { return 0; }
generate_dnsmasq_config() { return 0; }
restart_dnsmasq() { return 0; }
free_port_53() { return 0; }
configure_upstream_dns() { return 0; }
configure_resolv_conf() { return 0; }
create_dns_init_script() { return 0; }
systemctl() { return 0; }
dpkg() { printf 'Version: 4.1.15-1\n'; }
hostname() { printf 'max12\n'; }

{
    awk '/^prepare_registration_connectivity\(\) \{/,/^}/' \
        "$project_dir/linux/lib/runtime-cli-commands.sh"
    awk '/^activate_enrolled_connectivity\(\) \{/,/^}/' \
        "$project_dir/linux/lib/runtime-cli-commands.sh"
    awk '/^cmd_enroll\(\) \{/,/^}/' \
        "$project_dir/linux/lib/runtime-cli-commands.sh"
    awk '/^reset_cached_whitelist_state\(\) \{/,/^}/' \
        "$project_dir/linux/lib/runtime-cli-commands.sh"
} > "$extracted_script"

set +e
(
    source "$extracted_script"
    cmd_enroll --classroom 'Room 101' --api-url 'https://control.example' --classroom-id 'cls_123' --enrollment-token 'enroll-token'
)
status=$?
set -e

printf 'status=%s\n' "$status"
printf 'api_url=%s\n' "$(cat "$ETC_CONFIG_DIR/api-url.conf")"
printf 'classroom=%s\n' "$(cat "$ETC_CONFIG_DIR/classroom.conf")"
printf 'classroom_id=%s\n' "$(cat "$ETC_CONFIG_DIR/classroom-id.conf")"
printf 'whitelist_url=%s\n' "$(cat "$WHITELIST_URL_CONF")"
printf 'machine_name=%s\n' "$(cat "$ETC_CONFIG_DIR/persisted-machine-name")"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=0"* ]]
    [[ "$output" == *"api_url=https://control.example"* ]]
    [[ "$output" == *"classroom=Room 201"* ]]
    [[ "$output" == *"classroom_id=cls_201"* ]]
    [[ "$output" == *"whitelist_url=https://control.example/w/token123/whitelist.txt"* ]]
    [[ "$output" == *"machine_name=max12-scoped"* ]]
}

# ============== Tests para doctor browser ==============

@test "cmd_doctor is defined in runtime-cli-system.sh" {
    run grep -n "cmd_doctor()" "$PROJECT_DIR/linux/lib/runtime-cli-system.sh"
    [ "$status" -eq 0 ]
}

@test "cmd_doctor_browser is defined in runtime-cli-system.sh" {
    run grep -n "cmd_doctor_browser()" "$PROJECT_DIR/linux/lib/runtime-cli-system.sh"
    [ "$status" -eq 0 ]
}

@test "openpath-cmd.sh dispatches doctor verb to cmd_doctor" {
    run grep -n "cmd_doctor" "$PROJECT_DIR/linux/scripts/runtime/openpath-cmd.sh"
    [ "$status" -eq 0 ]
}

@test "cmd_doctor exits non-zero for unknown sub-target" {
    local helper_script="$TEST_TMP_DIR/doctor-unknown.sh"
    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail
project_dir="$1"
export INSTALL_DIR="$project_dir/linux"

# Minimal stubs for sourced libraries
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
VERSION="test"
ETC_CONFIG_DIR="/nonexistent"
WHITELIST_URL_CONF="/nonexistent"
VAR_STATE_DIR="/nonexistent"

# Extract only cmd_doctor and cmd_doctor_browser
awk '/^cmd_doctor_browser\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" > /tmp/doctor-fns.sh
awk '/^cmd_doctor\(\) \{/,/^}/' \
    "$project_dir/linux/lib/runtime-cli-system.sh" >> /tmp/doctor-fns.sh

source /tmp/doctor-fns.sh
set +e
cmd_doctor "unknown-target" 2>&1
echo "exit_code=$?"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR"
    [[ "$output" == *"exit_code=1"* ]] || [[ "$output" == *"Unknown doctor target"* ]]
}

@test "cmd_doctor_browser emits fact.request_setup key" {
    run grep -n "fact.request_setup" "$PROJECT_DIR/linux/lib/runtime-cli-system.sh"
    [ "$status" -eq 0 ]
}

@test "cmd_doctor_browser emits fact.firefox_registration key" {
    run grep -n "fact.firefox_registration" "$PROJECT_DIR/linux/lib/runtime-cli-system.sh"
    [ "$status" -eq 0 ]
}

@test "cmd_doctor_browser emits fact.firefox_native_host key" {
    run grep -n "fact.firefox_native_host" "$PROJECT_DIR/linux/lib/runtime-cli-system.sh"
    [ "$status" -eq 0 ]
}
