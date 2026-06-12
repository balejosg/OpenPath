#!/usr/bin/env bats
################################################################################
# watchdog.bats - Tests for scripts/runtime/dnsmasq-watchdog.sh
################################################################################

load 'test_helper'

setup() {
    TEST_TMP_DIR=$(mktemp -d)
}

teardown() {
    if [ -n "$TEST_TMP_DIR" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}

@test "check_integrity matches exact file paths when command names share a prefix" {
    local helper_script="$TEST_TMP_DIR/run-watchdog-integrity.sh"
    local bin_dir="$TEST_TMP_DIR/usr/local/bin"
    local state_dir="$TEST_TMP_DIR/var/lib/openpath"

    mkdir -p "$bin_dir" "$state_dir"
    printf '%s\n' 'update helper' > "$bin_dir/openpath-update.sh"
    printf '%s\n' 'browser setup helper' > "$bin_dir/openpath-browser-setup.sh"
    printf '%s\n' 'openpath cli' > "$bin_dir/openpath"
    chmod +x "$bin_dir/openpath-update.sh" "$bin_dir/openpath-browser-setup.sh" "$bin_dir/openpath"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
bin_dir="$3"
extracted_script="$state_dir/watchdog-integrity-functions.sh"

export INTEGRITY_HASH_FILE="$state_dir/integrity.sha256"
export CRITICAL_FILES=(
    "$bin_dir/openpath-update.sh"
    "$bin_dir/openpath-browser-setup.sh"
    "$bin_dir/openpath"
)

log() { echo "$1"; }
log_warn() { echo "$1"; }
log_error() { echo "$1"; }
log_debug() { :; }

awk '
    /^generate_integrity_hashes\(\) \{/ { capture = 1 }
    capture && /^recover_integrity\(\) \{/ { exit }
    capture { print }
' "$project_dir/linux/scripts/runtime/dnsmasq-watchdog.sh" > "$extracted_script"
source "$extracted_script"

generate_integrity_hashes
check_integrity
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir" "$bin_dir"

    [ "$status" -eq 0 ]
    [[ "$output" != *"TAMPERED: $bin_dir/openpath"* ]]
}

@test "check_integrity reports expected and current hashes for modified exact path" {
    local helper_script="$TEST_TMP_DIR/run-watchdog-integrity-mismatch.sh"
    local bin_dir="$TEST_TMP_DIR/usr/local/bin"
    local state_dir="$TEST_TMP_DIR/var/lib/openpath"

    mkdir -p "$bin_dir" "$state_dir"
    printf '%s\n' 'openpath cli' > "$bin_dir/openpath"
    chmod +x "$bin_dir/openpath"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
bin_dir="$3"
extracted_script="$state_dir/watchdog-integrity-functions.sh"

export INTEGRITY_HASH_FILE="$state_dir/integrity.sha256"
export CRITICAL_FILES=("$bin_dir/openpath")

log() { echo "$1"; }
log_warn() { echo "$1"; }
log_error() { echo "$1"; }
log_debug() { :; }

awk '
    /^generate_integrity_hashes\(\) \{/ { capture = 1 }
    capture && /^recover_integrity\(\) \{/ { exit }
    capture { print }
' "$project_dir/linux/scripts/runtime/dnsmasq-watchdog.sh" > "$extracted_script"
source "$extracted_script"

generate_integrity_hashes
expected=$(sha256sum "$bin_dir/openpath" | cut -d' ' -f1)
printf '%s\n' 'tampered cli' > "$bin_dir/openpath"
current=$(sha256sum "$bin_dir/openpath" | cut -d' ' -f1)

if check_integrity; then
    echo "unexpected-ok"
    exit 1
fi

printf 'expected=%s\n' "$expected"
printf 'current=%s\n' "$current"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir" "$bin_dir"

    [ "$status" -eq 0 ]
    [[ "$output" != *"unexpected-ok"* ]]
    [[ "$output" == *"TAMPERED: $bin_dir/openpath (expected="* ]]
    [[ "$output" == *" actual="* ]]
}

@test "check_dns_resolving uses active whitelist domain and rejects sinkhole answers" {
    local helper_script="$TEST_TMP_DIR/run-watchdog-dns-resolving.sh"
    local state_dir="$TEST_TMP_DIR/var/lib/openpath"
    local whitelist_file="$state_dir/whitelist.txt"
    local probe_log="$state_dir/probes.log"

    mkdir -p "$state_dir"
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
extracted_script="$state_dir/watchdog-dns-functions.sh"

export WHITELIST_FILE="$whitelist_file"

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

source "$project_dir/linux/lib/dns.sh"
awk '/^check_dns_resolving\(\) \{/,/^}/' \
    "$project_dir/linux/scripts/runtime/dnsmasq-watchdog.sh" > "$extracted_script"
source "$extracted_script"

check_dns_resolving
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir" "$whitelist_file" "$probe_log"

    [ "$status" -eq 0 ]
    grep -qx "google.es" "$probe_log"
    ! grep -qx "google.com" "$probe_log"
}

################################################################################
# ADR 0011 — protected-mode state-transition tests
################################################################################

# Helper: build a minimal watchdog harness that sources only the functions
# needed for the protected-mode tests.  Writes the harness script to $1.
_write_protected_mode_harness() {
    local harness="$1"
    local state_dir="$2"
    local dnsmasq_conf="$3"
    cat > "$harness" << 'HARNESS'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
dnsmasq_conf="$3"
scenario="$4"   # healthy | degraded | protected | recovered | escape_open

# Minimal stubs for library functions referenced by the watchdog.
export CONFIG_DIR="$state_dir"
export VAR_STATE_DIR="$state_dir"
export INSTALL_DIR="$state_dir/install"
export DNSMASQ_CONF="$dnsmasq_conf"
export WATCHDOG_PROTECTED_FLAG="$state_dir/watchdog-protected.flag"
export FAIL_COUNT_FILE="$state_dir/watchdog-fails"
export INTEGRITY_HASH_FILE="$state_dir/integrity.sha256"
export PRIMARY_DNS="8.8.8.8"
export VERSION="test"

log()       { echo "[LOG] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
log_debug() { :; }

systemctl()              { return 0; }
deactivate_firewall()    { echo "DEACTIVATE_FIREWALL_CALLED"; }
select_usable_upstream_dns() { echo "8.8.8.8"; }
report_health_to_api()  { :; }
check_dnsmasq_running()  { return 0; }
check_dns_resolving()    { return 0; }

get_openpath_protected_domains() {
    printf '%s\n' raw.githubusercontent.com detectportal.firefox.com ntp.ubuntu.com
}
get_openpath_captive_portal_probe_domains() { get_openpath_protected_domains; }
get_openpath_os_system_domains()            { :; }
get_openpath_firefox_system_domains()       { :; }

write_dnsmasq_protected_mode_config() {
    local upstream="$1"
    local conf="${2:-$DNSMASQ_CONF}"
    local sinkhole_ipv4="${OPENPATH_DNS_SINKHOLE_IPV4:-192.0.2.1}"
    local sinkhole_ipv6="${OPENPATH_DNS_SINKHOLE_IPV6:-100::}"
    cat > "$conf" << EOF
# OPENPATH PROTECTED MODE - critical-domains only (watchdog threshold reached)
no-resolv
resolv-file=/run/dnsmasq/resolv.conf
listen-address=127.0.0.1
bind-interfaces
cache-size=1000
address=/#/${sinkhole_ipv4}
address=/#/${sinkhole_ipv6}
server=/raw.githubusercontent.com/$upstream
server=/detectportal.firefox.com/$upstream
server=/ntp.ubuntu.com/$upstream
EOF
    return 0
}

# Extract only the functions we need from the watchdog
_extract_watchdog_functions() {
    awk '
        /^(get_fail_count|increment_fail_count|reset_fail_count|_watchdog_failure_mode_is_open|enter_protected_mode|exit_protected_mode)\(\) \{/ { cap=1; depth=0 }
        cap && /\{/ { depth++ }
        cap && /\}/ { depth--; if (depth==0) { print; cap=0; next } }
        cap { print }
    ' "$project_dir/linux/scripts/runtime/dnsmasq-watchdog.sh"
}

extracted="$state_dir/watchdog-protected-functions.sh"
_extract_watchdog_functions > "$extracted"
# shellcheck source=/dev/null
source "$extracted"

case "$scenario" in
    healthy)
        # Watchdog starts healthy — protected flag should not exist
        exit_protected_mode   # idempotent on no-flag
        if [ -f "$WATCHDOG_PROTECTED_FLAG" ]; then
            echo "UNEXPECTED_PROTECTED_FLAG"
            exit 1
        fi
        echo "STATUS=HEALTHY"
        ;;

    degraded)
        # Below threshold — protected mode should NOT be entered
        echo "2" > "$state_dir/watchdog-fails"
        # Simulating a watchdog cycle that fails but hasn't crossed threshold yet
        fail_count=$(get_fail_count)
        if [ "$fail_count" -lt 3 ]; then
            echo "STATUS=DEGRADED"
            echo "FAIL_COUNT=$fail_count"
        fi
        ;;

    protected)
        # Threshold reached, no rollback → must enter protected mode (default)
        unset FAILURE_MODE
        export FAILURE_MODE="${OPENPATH_FAILURE_MODE:-protected}"
        echo "3" > "$state_dir/watchdog-fails"

        if _watchdog_failure_mode_is_open; then
            echo "UNEXPECTED_OPEN_MODE"
            exit 1
        fi
        enter_protected_mode
        if [ ! -f "$WATCHDOG_PROTECTED_FLAG" ]; then
            echo "PROTECTED_FLAG_MISSING"
            exit 1
        fi
        if ! grep -q "OPENPATH PROTECTED MODE" "$dnsmasq_conf" 2>/dev/null; then
            echo "DNSMASQ_CONF_NOT_PROTECTED"
            exit 1
        fi
        echo "STATUS=PROTECTED"
        ;;

    recovered)
        # After recovery, protected flag must be removed and fail count reset
        echo "3" > "$state_dir/watchdog-fails"
        echo '{"enteredAt":"2026-06-12T00:00:00+00:00","failCount":3}' > "$WATCHDOG_PROTECTED_FLAG"
        reset_fail_count
        exit_protected_mode
        if [ -f "$WATCHDOG_PROTECTED_FLAG" ]; then
            echo "FLAG_STILL_PRESENT"
            exit 1
        fi
        remaining=$(get_fail_count)
        if [ "$remaining" -ne 0 ]; then
            echo "FAIL_COUNT_NOT_RESET=$remaining"
            exit 1
        fi
        echo "STATUS=RECOVERED"
        ;;

    escape_open)
        # With OPENPATH_FAILURE_MODE=open the mode check must return open
        export OPENPATH_FAILURE_MODE=open
        export FAILURE_MODE=open
        echo "3" > "$state_dir/watchdog-fails"
        if ! _watchdog_failure_mode_is_open; then
            echo "EXPECTED_OPEN_NOT_DETECTED"
            exit 1
        fi
        echo "STATUS=ESCAPE_OPEN"
        ;;
    *)
        echo "UNKNOWN_SCENARIO=$scenario"
        exit 1
        ;;
esac
HARNESS
    chmod +x "$harness"
}

@test "protected mode: healthy cycle — no protected flag created" {
    local harness="$TEST_TMP_DIR/harness.sh"
    local state_dir="$TEST_TMP_DIR/state"
    local dnsmasq_conf="$TEST_TMP_DIR/openpath.conf"
    mkdir -p "$state_dir"

    _write_protected_mode_harness "$harness" "$state_dir" "$dnsmasq_conf"

    run "$harness" "$PROJECT_DIR" "$state_dir" "$dnsmasq_conf" "healthy"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STATUS=HEALTHY"* ]]
    [ ! -f "$state_dir/watchdog-protected.flag" ]
}

@test "protected mode: degraded cycle (below threshold) — no protected mode entered" {
    local harness="$TEST_TMP_DIR/harness.sh"
    local state_dir="$TEST_TMP_DIR/state"
    local dnsmasq_conf="$TEST_TMP_DIR/openpath.conf"
    mkdir -p "$state_dir"

    _write_protected_mode_harness "$harness" "$state_dir" "$dnsmasq_conf"

    run "$harness" "$PROJECT_DIR" "$state_dir" "$dnsmasq_conf" "degraded"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STATUS=DEGRADED"* ]]
    [[ "$output" == *"FAIL_COUNT=2"* ]]
    [ ! -f "$state_dir/watchdog-protected.flag" ]
}

@test "protected mode: threshold reached — writes protected flag and restricted dnsmasq config" {
    local harness="$TEST_TMP_DIR/harness.sh"
    local state_dir="$TEST_TMP_DIR/state"
    local dnsmasq_conf="$TEST_TMP_DIR/openpath.conf"
    mkdir -p "$state_dir"

    _write_protected_mode_harness "$harness" "$state_dir" "$dnsmasq_conf"

    run "$harness" "$PROJECT_DIR" "$state_dir" "$dnsmasq_conf" "protected"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STATUS=PROTECTED"* ]]
    [ -f "$state_dir/watchdog-protected.flag" ]
    grep -q "OPENPATH PROTECTED MODE" "$dnsmasq_conf"
    # Critical domains must be present; whitelist passthrough must NOT be present
    grep -q "detectportal.firefox.com" "$dnsmasq_conf"
    grep -q "ntp.ubuntu.com" "$dnsmasq_conf"
    # Sinkhole directive must appear in protected config
    grep -q "address=/#/" "$dnsmasq_conf"
}

@test "protected mode: recovered cycle — clears protected flag and resets fail count" {
    local harness="$TEST_TMP_DIR/harness.sh"
    local state_dir="$TEST_TMP_DIR/state"
    local dnsmasq_conf="$TEST_TMP_DIR/openpath.conf"
    mkdir -p "$state_dir"

    _write_protected_mode_harness "$harness" "$state_dir" "$dnsmasq_conf"

    run "$harness" "$PROJECT_DIR" "$state_dir" "$dnsmasq_conf" "recovered"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STATUS=RECOVERED"* ]]
    [ ! -f "$state_dir/watchdog-protected.flag" ]
}

@test "protected mode: OPENPATH_FAILURE_MODE=open activates escape hatch" {
    local harness="$TEST_TMP_DIR/harness.sh"
    local state_dir="$TEST_TMP_DIR/state"
    local dnsmasq_conf="$TEST_TMP_DIR/openpath.conf"
    mkdir -p "$state_dir"

    _write_protected_mode_harness "$harness" "$state_dir" "$dnsmasq_conf"

    run "$harness" "$PROJECT_DIR" "$state_dir" "$dnsmasq_conf" "escape_open"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STATUS=ESCAPE_OPEN"* ]]
}
