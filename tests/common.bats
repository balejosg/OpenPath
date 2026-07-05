#!/usr/bin/env bats
################################################################################
# common.bats - Tests for lib/common.sh
################################################################################

load 'test_helper'

setup() {
    setup_std_lib_layout
    # Load the library to test
    source "$PROJECT_DIR/linux/lib/common.sh"
}

# ============== Whitelist parsing tests ==============

@test "parse_whitelist extracts domains from WHITELIST section" {
    local wl_file=$(create_test_whitelist)
    
    # Simulate parse (the actual function may vary)
    local domains=$(grep -A 100 "## WHITELIST" "$wl_file" | grep -B 100 "## BLOCKED" | grep -v "^#" | grep -v "^$" | head -n -1)
    
    [[ "$domains" == *"google.com"* ]]
    [[ "$domains" == *"github.com"* ]]
}

@test "parse_whitelist extracts blocked subdomains" {
    local wl_file=$(create_test_whitelist)
    
    local blocked=$(sed -n '/## BLOCKED-SUBDOMAINS/,/## BLOCKED-PATHS/p' "$wl_file" | grep -v "^#" | grep -v "^$")
    
    [[ "$blocked" == *"ads.google.com"* ]]
}

@test "detects disabled whitelist" {
    local wl_file=$(create_disabled_whitelist)
    
    if head -1 "$wl_file" | grep -qi "DESACTIVADO"; then
        local is_disabled=true
    else
        local is_disabled=false
    fi
    
    [ "$is_disabled" = true ]
}

@test "normal whitelist is not disabled" {
    local wl_file=$(create_test_whitelist)
    
    if head -1 "$wl_file" | grep -qi "DESACTIVADO"; then
        local is_disabled=true
    else
        local is_disabled=false
    fi
    
    [ "$is_disabled" = false ]
}

# ============== Logging tests ==============

@test "log writes to log file" {
    export LOG_FILE="$TEST_TMP_DIR/test.log"

    log_info "Test message"

    [ -f "$LOG_FILE" ]
    grep -q "Test message" "$LOG_FILE"
}

@test "log functions never abort under set -e when log path is unwritable" {
    local unwritable_dir="$TEST_TMP_DIR/unwritable"
    mkdir -p "$unwritable_dir"
    chmod 500 "$unwritable_dir"

    run bash -c '
        set -euo pipefail
        export LOG_FILE="'"$unwritable_dir"'/openpath.log"
        source "'"$PROJECT_DIR"'/linux/lib/common.sh"
        log_info "hello"
        log_warn "warn"
        log_error "err"
        DEBUG=1 log_debug "debug"
    '

    chmod 700 "$unwritable_dir"
    [ "$status" -eq 0 ]
}

# ============== Validation tests ==============

@test "valid domain passes validation" {
    local domain="google.com"
    
    # Validación básica de dominio
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        local valid=true
    else
        local valid=false
    fi
    
    [ "$valid" = true ]
}

@test "invalid domain fails validation" {
    local domain="invalid domain with spaces"
    
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        local valid=true
    else
        local valid=false
    fi
    
    [ "$valid" = false ]
}

@test "validate_domain accepts shared valid contract fixtures" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"

    while IFS= read -r domain; do
        run validate_domain "$domain"
        [ "$status" -eq 0 ]
    done < <(load_contract_fixture_lines "domain-valid.txt")
}

@test "validate_domain rejects shared invalid contract fixtures" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"

    while IFS= read -r domain; do
        run validate_domain "$domain"
        [ "$status" -eq 1 ]
    done < <(load_contract_fixture_lines "domain-invalid.txt")
}

# ============== Tests de parse_whitelist_sections ==============

@test "parse_whitelist_sections fills arrays correctly" {
    local wl_file=$(create_test_whitelist)
    
    source "$PROJECT_DIR/linux/lib/common.sh"
    # Override log to avoid permission issues
    log() { echo "$1"; }
    
    parse_whitelist_sections "$wl_file"
    
    # Check WHITELIST_DOMAINS array
    [ ${#WHITELIST_DOMAINS[@]} -ge 3 ]
    [[ " ${WHITELIST_DOMAINS[*]} " == *" google.com "* ]]
    [[ " ${WHITELIST_DOMAINS[*]} " == *" github.com "* ]]
}

@test "parse_whitelist_sections extracts blocked subdomains" {
    local wl_file=$(create_test_whitelist)
    
    source "$PROJECT_DIR/linux/lib/common.sh"
    log() { echo "$1"; }
    
    parse_whitelist_sections "$wl_file"
    
    [ ${#BLOCKED_SUBDOMAINS[@]} -eq 2 ]
    [[ " ${BLOCKED_SUBDOMAINS[*]} " == *" ads.google.com "* ]]
}

@test "parse_whitelist_sections extracts blocked paths" {
    local wl_file=$(create_test_whitelist)
    
    source "$PROJECT_DIR/linux/lib/common.sh"
    log() { echo "$1"; }
    
    parse_whitelist_sections "$wl_file"
    
    [ ${#BLOCKED_PATHS[@]} -eq 2 ]
    [[ " ${BLOCKED_PATHS[*]} " == *" example.org/ads "* ]]
}

@test "request setup validator requires api url tokenized whitelist and classroom state" {
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    mkdir -p "$etc_dir"

    export ETC_CONFIG_DIR="$etc_dir"
    export WHITELIST_URL_CONF="$etc_dir/whitelist-url.conf"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run is_openpath_request_setup_complete
    [ "$status" -ne 0 ]

    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/export/group.txt' > "$WHITELIST_URL_CONF"
    printf '%s' 'Room 101' > "$etc_dir/classroom.conf"

    run is_openpath_request_setup_complete
    [ "$status" -ne 0 ]

    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$WHITELIST_URL_CONF"

    run is_openpath_request_setup_complete
    [ "$status" -eq 0 ]

    run describe_openpath_request_setup_missing
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "tokenized whitelist-url.conf is not world-readable (token confidentiality)" {
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    export ETC_CONFIG_DIR="$etc_dir"
    export WHITELIST_URL_CONF="$etc_dir/whitelist-url.conf"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run persist_openpath_enrollment_state \
        'https://control.example' \
        'Room 101' \
        'cls_123' \
        'https://control.example/w/token123/whitelist.txt'
    [ "$status" -eq 0 ]

    [ "$(stat -c '%a' "$etc_dir")" = "755" ]
    [ "$(stat -c '%a' "$etc_dir/api-url.conf")" = "644" ]
    # whitelist-url.conf embeds the machine bearer token in the path, so it must
    # be 640 (root:root, no world bit), not 644. Only root-run scripts read it.
    [ "$(stat -c '%a' "$WHITELIST_URL_CONF")" = "640" ]
}

@test "parse_whitelist_sections preserves protected always-allowed domains and strips their block rules" {
    local wl_file="$TEST_TMP_DIR/protected-whitelist.txt"
    cat > "$wl_file" <<'EOF'
## WHITELIST
safe.example

## BLOCKED-SUBDOMAINS
control.example
aus5.mozilla.org

## BLOCKED-PATHS
downloads.example/blocked
download.mozilla.org/firefox/releases
EOF

    ETC_CONFIG_DIR="$TEST_TMP_DIR/etc"
    WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
    HEALTH_API_URL_CONF="$ETC_CONFIG_DIR/health-api-url.conf"
    mkdir -p "$ETC_CONFIG_DIR"
    echo "https://downloads.example/w/token/whitelist.txt" > "$WHITELIST_URL_CONF"
    echo "https://control.example" > "$HEALTH_API_URL_CONF"

    source "$PROJECT_DIR/linux/lib/common.sh"
    log() { echo "$1"; }
    log_warn() { echo "$1"; }

    parse_whitelist_sections "$wl_file"

    [[ " ${WHITELIST_DOMAINS[*]} " == *" aus5.mozilla.org "* ]]
    [[ " ${WHITELIST_DOMAINS[*]} " == *" download.mozilla.org "* ]]
    [[ " ${BLOCKED_SUBDOMAINS[*]} " != *" aus5.mozilla.org "* ]]
    [[ " ${BLOCKED_PATHS[*]} " != *"download.mozilla.org/firefox/releases"* ]]

    [[ " ${WHITELIST_DOMAINS[*]} " == *" safe.example "* ]]
    [[ " ${WHITELIST_DOMAINS[*]} " == *" control.example "* ]]
    [[ " ${WHITELIST_DOMAINS[*]} " == *" downloads.example "* ]]
    [[ " ${BLOCKED_SUBDOMAINS[*]} " != *" control.example "* ]]
    [[ " ${BLOCKED_PATHS[*]} " != *" downloads.example/blocked "* ]]
}

@test "parse_whitelist_sections handles nonexistent file" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    
    run parse_whitelist_sections "/nonexistent/file.txt"
    [ "$status" -eq 1 ]
}

# ============== Tests de validate_ip ==============

@test "validate_ip acepta IP válida" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    
    run validate_ip "192.168.1.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip acepta DNS Google" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    
    run validate_ip "8.8.8.8"
    [ "$status" -eq 0 ]
}

@test "validate_ip rechaza texto" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    
    run validate_ip "not-an-ip"
    [ "$status" -eq 1 ]
}

@test "validate_ip rechaza IPv6" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    
    run validate_ip "::1"
    [ "$status" -eq 1 ]
}

@test "enter_fail_open_mode applies passthrough runtime and clears hashes" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/openpath.conf"
    export DNSMASQ_CONF_HASH="$TEST_TMP_DIR/dnsmasq.hash"
    export BROWSER_POLICIES_HASH="$TEST_TMP_DIR/browser.hash"
    export PRIMARY_DNS="9.9.9.9"
    : > "$DNSMASQ_CONF_HASH"
    : > "$BROWSER_POLICIES_HASH"

    source "$PROJECT_DIR/linux/lib/common.sh"

    deactivate_firewall() { echo "deactivate_firewall"; }
    cleanup_browser_policies() { echo "cleanup_browser_policies"; }
    flush_connections() { echo "flush_connections"; }
    force_browser_close() { echo "force_browser_close"; }
    systemctl() { echo "systemctl $*"; }
    export -f deactivate_firewall cleanup_browser_policies flush_connections force_browser_close systemctl

    run enter_fail_open_mode "$PRIMARY_DNS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deactivate_firewall"* ]]
    [[ "$output" == *"cleanup_browser_policies"* ]]
    [[ "$output" == *"flush_connections"* ]]
    [[ "$output" != *"force_browser_close"* ]]
    [ ! -f "$DNSMASQ_CONF_HASH" ]
    [ ! -f "$BROWSER_POLICIES_HASH" ]
    grep -q "server=$PRIMARY_DNS" "$DNSMASQ_CONF"
}

@test "enter_disabled_mode closes browsers without clearing hashes" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/openpath.conf"
    export DNSMASQ_CONF_HASH="$TEST_TMP_DIR/dnsmasq.hash"
    export BROWSER_POLICIES_HASH="$TEST_TMP_DIR/browser.hash"
    : > "$DNSMASQ_CONF_HASH"
    : > "$BROWSER_POLICIES_HASH"

    source "$PROJECT_DIR/linux/lib/common.sh"

    deactivate_firewall() { echo "deactivate_firewall"; }
    cleanup_browser_policies() { echo "cleanup_browser_policies"; }
    flush_connections() { echo "flush_connections"; }
    force_browser_close() { echo "force_browser_close"; }
    systemctl() { echo "systemctl $*"; }
    export -f deactivate_firewall cleanup_browser_policies flush_connections force_browser_close systemctl

    run enter_disabled_mode "8.8.4.4"
    [ "$status" -eq 0 ]
    [[ "$output" == *"force_browser_close"* ]]
    [ -f "$DNSMASQ_CONF_HASH" ]
    [ -f "$BROWSER_POLICIES_HASH" ]
    grep -q "server=8.8.4.4" "$DNSMASQ_CONF"
}

@test "build_runtime_reconciliation_plan computes firewall and connection actions" {
    source "$PROJECT_DIR/linux/lib/common.sh"

    run build_runtime_reconciliation_plan false true true false
    [ "$status" -eq 0 ]
    [[ "$output" == *"FIREWALL_ACTION=activate"* ]]
    [[ "$output" == *"FLUSH_CONNECTIONS=true"* ]]
    [[ "$output" == *"FLUSH_REASON=system_reactivated"* ]]
}

@test "apply_runtime_reconciliation_plan deactivates firewall when dns is unhealthy" {
    source "$PROJECT_DIR/linux/lib/common.sh"

    activate_firewall() { echo "activate_firewall"; return 0; }
    deactivate_firewall() { echo "deactivate_firewall"; return 0; }
    flush_connections() { echo "flush_connections"; }
    log() { echo "$1"; }
    export -f activate_firewall deactivate_firewall flush_connections log

    run apply_runtime_reconciliation_plan deactivate false ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"deactivate_firewall"* ]]
    ! grep -qx "activate_firewall" <<< "$output"
    ! grep -qx "flush_connections" <<< "$output"
}

@test "normalize_machine_name_value canonicalizes machine identifiers" {
    source "$PROJECT_DIR/linux/lib/common.sh"

    run normalize_machine_name_value "PC 01__Lab"
    [ "$status" -eq 0 ]
    [ "$output" = "pc-01-lab" ]
}

@test "compute_scoped_machine_name returns deterministic classroom-scoped names" {
    source "$PROJECT_DIR/linux/lib/common.sh"

    run compute_scoped_machine_name "PC 01__Lab" "classroom-123"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^pc-01-lab-[a-f0-9]{8}$ ]]
    [ "${#output}" -le 63 ]
}

@test "persist_machine_name stores the canonicalized machine name" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    ETC_CONFIG_DIR="$TEST_TMP_DIR/etc"
    MACHINE_NAME_CONF="$ETC_CONFIG_DIR/machine-name.conf"

    persist_machine_name "PC 01__Lab"

    [ -f "$MACHINE_NAME_CONF" ]
    [ "$(cat "$MACHINE_NAME_CONF")" = "pc-01-lab" ]
}

@test "parse_machine_registration_response extracts shared registration fields" {
    source "$PROJECT_DIR/linux/lib/common.sh"

    parse_machine_registration_response '{"success":true,"whitelistUrl":"https://api.example.com/w/token/whitelist.txt","classroomName":"Room 101","classroomId":"cls_123","machineHostname":"pc-01-abcd1234"}'

    [ "$TOKENIZED_URL" = "https://api.example.com/w/token/whitelist.txt" ]
    [ "$REGISTERED_CLASSROOM_NAME" = "Room 101" ]
    [ "$REGISTERED_CLASSROOM_ID" = "cls_123" ]
    [ "$REGISTERED_MACHINE_NAME" = "pc-01-abcd1234" ]
}

@test "register_machine reports curl transport errors instead of fake unsuccessful response" {
    local helper_script="$TEST_TMP_DIR/register-machine-curl-error.sh"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
source "$project_dir/linux/lib/common.sh"

curl() {
    printf '%s\n' "curl: (6) Could not resolve host: control.example" >&2
    return 6
}

set +e
register_machine "pc-01" "Room 101" "cls_123" "4.1.0" "https://control.example" "enroll-token"
status=$?
set -e

printf 'status=%s\n' "$status"
printf 'response=%s\n' "$REGISTER_RESPONSE"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=1"* ]]
    [[ "$output" == *"response=curl failed (exit 6): curl: (6) Could not resolve host: control.example"* ]]
    [[ "$output" != *'{"success":false}'* ]]
}

# ============== Tests de init_directories ==============

@test "init_directories creates CONFIG_DIR" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    # Override paths after sourcing - use actual variables the function uses
    ETC_CONFIG_DIR="$TEST_TMP_DIR/etc_config"
    VAR_STATE_DIR="$TEST_TMP_DIR/var_state"
    LOG_FILE="$TEST_TMP_DIR/logs/test.log"
    INSTALL_DIR="$TEST_TMP_DIR/install"
    
    init_directories
    
    [ -d "$ETC_CONFIG_DIR" ]
}

@test "init_directories creates log directory" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    # Override paths after sourcing - use actual variables the function uses
    ETC_CONFIG_DIR="$TEST_TMP_DIR/etc_config2"
    VAR_STATE_DIR="$TEST_TMP_DIR/var_state2"
    LOG_FILE="$TEST_TMP_DIR/logs/openpath.log"
    INSTALL_DIR="$TEST_TMP_DIR/install2"
    
    init_directories
    
    [ -d "$(dirname "$LOG_FILE")" ]
}

# ============== Health reporting tests ==============

@test "send_health_report_to_api succeeds when health endpoint is not configured" {
    HEALTH_API_URL_CONF="$TEST_TMP_DIR/missing-health-api-url.conf"
    HEALTH_API_SECRET_CONF="$TEST_TMP_DIR/missing-health-api-secret.conf"

    run send_health_report_to_api "HEALTHY" "watchdog_ok" "true" "true" "0" "4.1.0"
    [ "$status" -eq 0 ]
}

@test "protected domains include persisted API URL and Firefox system domains before machine registration" {
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    mkdir -p "$etc_dir"

    ETC_CONFIG_DIR="$etc_dir"
    WHITELIST_URL_CONF="$etc_dir/whitelist-url.conf"
    HEALTH_API_URL_CONF="$etc_dir/health-api-url.conf"
    OPENPATH_PROTECTED_DOMAINS_READY=0

    echo "https://classroompath.eu" > "$etc_dir/api-url.conf"

    run get_openpath_protected_domains
    [ "$status" -eq 0 ]
    [[ "$output" == *"classroompath.eu"* ]]
    [[ "$output" == *"aus5.mozilla.org"* ]]
    [[ "$output" == *"download.mozilla.org"* ]]
    [[ "$output" == *"versioncheck.addons.mozilla.org"* ]]
    [[ "$output" != *"incoming.telemetry.mozilla.org"* ]]
    [[ "$output" != *"ads.mozilla.org"* ]]
    [[ "$output" != *"mozilla.cloudflare-dns.com"* ]]
}

@test "send_health_report_to_api prefers machine token auth derived from whitelist URL" {
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local bin_dir="$TEST_TMP_DIR/bin"
    local curl_log="$TEST_TMP_DIR/curl-args.log"

    mkdir -p "$etc_dir" "$bin_dir"

    HEALTH_API_URL_CONF="$etc_dir/health-api-url.conf"
    WHITELIST_URL_CONF="$etc_dir/whitelist-url.conf"
    echo "https://api.example.test" > "$HEALTH_API_URL_CONF"
    echo "https://api.example.test/w/token123/whitelist.txt" > "$WHITELIST_URL_CONF"

    cat > "$bin_dir/curl" << EOF
#!/bin/bash
echo "\$*" >> "$curl_log"
exit 0
EOF
    chmod +x "$bin_dir/curl"
    PATH="$bin_dir:$PATH"

    run send_health_report_to_api "DEGRADED" "watchdog_repair" "true" "false" "2" "4.1.0"
    [ "$status" -eq 0 ]

    for _ in $(seq 1 20); do
        [ -f "$curl_log" ] && break
        sleep 0.1
    done

    [ -f "$curl_log" ]
    grep -q "/trpc/healthReports.submit" "$curl_log"
    grep -q "Authorization: Bearer token123" "$curl_log"
}

@test "send_health_report_to_api includes enforcement fields when firewall/whitelist age provided" {
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local bin_dir="$TEST_TMP_DIR/bin"
    local curl_log="$TEST_TMP_DIR/curl-enforce.log"

    mkdir -p "$etc_dir" "$bin_dir"
    HEALTH_API_URL_CONF="$etc_dir/health-api-url.conf"
    echo "https://api.example.test" > "$HEALTH_API_URL_CONF"

    cat > "$bin_dir/curl" << EOF
#!/bin/bash
echo "\$*" >> "$curl_log"
exit 0
EOF
    chmod +x "$bin_dir/curl"
    PATH="$bin_dir:$PATH"

    run send_health_report_to_api "HEALTHY" "watchdog_ok" "true" "true" "0" "4.1.0" "active" "5"
    [ "$status" -eq 0 ]

    for _ in $(seq 1 20); do [ -f "$curl_log" ] && break; sleep 0.1; done
    [ -f "$curl_log" ]
    grep -q '"firewallState": true' "$curl_log"
    grep -q '"whitelistAgeHours": 5' "$curl_log"
}

@test "send_health_report_to_api omits enforcement fields on a legacy 6-arg call" {
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local bin_dir="$TEST_TMP_DIR/bin"
    local curl_log="$TEST_TMP_DIR/curl-legacy.log"

    mkdir -p "$etc_dir" "$bin_dir"
    HEALTH_API_URL_CONF="$etc_dir/health-api-url.conf"
    echo "https://api.example.test" > "$HEALTH_API_URL_CONF"

    cat > "$bin_dir/curl" << EOF
#!/bin/bash
echo "\$*" >> "$curl_log"
exit 0
EOF
    chmod +x "$bin_dir/curl"
    PATH="$bin_dir:$PATH"

    run send_health_report_to_api "HEALTHY" "watchdog_ok" "true" "true" "0" "4.1.0"
    [ "$status" -eq 0 ]

    for _ in $(seq 1 20); do [ -f "$curl_log" ] && break; sleep 0.1; done
    [ -f "$curl_log" ]
    # Unknown enforcement state must be omitted (server stores null, never false).
    ! grep -q "firewallState" "$curl_log"
    ! grep -q "whitelistAgeHours" "$curl_log"
}

@test "send_health_report_to_api includes allowlisted configPosture from effective flags" {
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local bin_dir="$TEST_TMP_DIR/bin"
    local curl_log="$TEST_TMP_DIR/curl-posture.log"

    mkdir -p "$etc_dir" "$bin_dir"
    HEALTH_API_URL_CONF="$etc_dir/health-api-url.conf"
    echo "https://api.example.test" > "$HEALTH_API_URL_CONF"
    VAR_STATE_DIR="$TEST_TMP_DIR/state"

    cat > "$bin_dir/curl" << EOF
#!/bin/bash
echo "\$*" >> "$curl_log"
echo -n "200"
exit 0
EOF
    chmod +x "$bin_dir/curl"
    PATH="$bin_dir:$PATH"

    # Effective flag values as defaults.conf produces them (1/0) plus an
    # operator-style boolean override ("true") to prove normalization.
    IPV6_FIREWALL_ENABLED="1"
    SINKHOLE_FAST_FAIL="0"
    CAPTIVE_PORTAL_SCOPED_PASSTHROUGH_ENABLED="true"
    ALLOW_SET_EGRESS_ENABLED="1"
    RFC1918_EGRESS_MODE="restricted"
    FAILURE_MODE="protected"

    run send_health_report_to_api "HEALTHY" "watchdog_ok" "true" "true" "0" "4.1.0"
    [ "$status" -eq 0 ]

    for _ in $(seq 1 20); do [ -f "$curl_log" ] && break; sleep 0.1; done
    [ -f "$curl_log" ]
    grep -q '"configPosture"' "$curl_log"
    grep -q '"ipv6FirewallEnabled": "true"' "$curl_log"
    grep -q '"sinkholeFastFail": "false"' "$curl_log"
    grep -q '"captivePortalScopedPassthrough": "true"' "$curl_log"
    grep -q '"rfc1918EgressMode": "restricted"' "$curl_log"
    grep -q '"allowSetEgressEnabled": "true"' "$curl_log"
    grep -q '"failureMode": "protected"' "$curl_log"
    # Windows-only key must be absent on Linux.
    ! grep -q "outboundEgressFloorEnabled" "$curl_log"
    # Zero streak must be omitted.
    ! grep -q "healthReportFailStreak" "$curl_log"
}

@test "send_health_report_to_api logs delivery failure, counts a streak, reports and resets it" {
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local bin_dir="$TEST_TMP_DIR/bin"
    local curl_log="$TEST_TMP_DIR/curl-streak.log"
    local streak_file="$TEST_TMP_DIR/state/health-report-fail-streak"

    mkdir -p "$etc_dir" "$bin_dir"
    HEALTH_API_URL_CONF="$etc_dir/health-api-url.conf"
    echo "https://api.example.test" > "$HEALTH_API_URL_CONF"
    VAR_STATE_DIR="$TEST_TMP_DIR/state"
    LOG_FILE="$TEST_TMP_DIR/openpath.log"

    # First delivery fails (curl transport error).
    cat > "$bin_dir/curl" << EOF
#!/bin/bash
echo "\$*" >> "$curl_log"
echo -n "000"
exit 7
EOF
    chmod +x "$bin_dir/curl"
    PATH="$bin_dir:$PATH"

    run send_health_report_to_api "HEALTHY" "watchdog_ok" "true" "true" "0" "4.1.0"
    [ "$status" -eq 0 ]   # caller is never blocked or failed by delivery

    for _ in $(seq 1 30); do [ -f "$streak_file" ] && break; sleep 0.1; done
    [ -f "$streak_file" ]
    [ "$(cat "$streak_file")" = "1" ]
    grep -q "\[HEALTH\] Report delivery failed" "$LOG_FILE"

    # Second delivery succeeds: payload carries the streak, then it resets.
    cat > "$bin_dir/curl" << EOF
#!/bin/bash
echo "\$*" >> "$curl_log.ok"
echo -n "200"
exit 0
EOF
    chmod +x "$bin_dir/curl"

    run send_health_report_to_api "HEALTHY" "watchdog_ok" "true" "true" "0" "4.1.0"
    [ "$status" -eq 0 ]

    for _ in $(seq 1 30); do [ -f "$curl_log.ok" ] && break; sleep 0.1; done
    [ -f "$curl_log.ok" ]
    grep -q '"healthReportFailStreak": 1' "$curl_log.ok"

    for _ in $(seq 1 30); do [ "$(cat "$streak_file" 2>/dev/null)" = "0" ] && break; sleep 0.1; done
    [ "$(cat "$streak_file")" = "0" ]
}
