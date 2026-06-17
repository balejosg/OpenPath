#!/usr/bin/env bats
################################################################################
# openpath-update.bats - Tests for scripts/runtime/openpath-update.sh
################################################################################

load 'test_helper'

@test "validate_whitelist_content accepts disabled whitelist content below minimum domain threshold" {
    local whitelist_file="$TEST_TMP_DIR/disabled-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-validate-whitelist.sh"
    cat > "$whitelist_file" <<'EOF'
#DESACTIVADO

## WHITELIST
google.com
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
whitelist_file="$2"
extracted_script="${TMPDIR:-/tmp}/openpath-update-validate.$$.$RANDOM.sh"

log_warn() { :; }

cp "$project_dir/linux/lib/openpath-update-whitelist.sh" "$extracted_script"
source "$extracted_script"

MIN_VALID_DOMAINS=5
MAX_DOMAINS=500

validate_whitelist_content "$whitelist_file"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$whitelist_file"

    [ "$status" -eq 0 ]
}

@test "validate_whitelist_content accepts structured whitelist content below minimum domain threshold" {
    local whitelist_file="$TEST_TMP_DIR/structured-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-validate-structured-whitelist.sh"
    cat > "$whitelist_file" <<'EOF'
## WHITELIST
google.com
github.com
mozilla.org
wikipedia.org
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
whitelist_file="$2"
extracted_script="${TMPDIR:-/tmp}/openpath-update-validate.$$.$RANDOM.sh"

log_warn() { :; }

cp "$project_dir/linux/lib/openpath-update-whitelist.sh" "$extracted_script"
source "$extracted_script"

MIN_VALID_DOMAINS=5
MAX_DOMAINS=500

validate_whitelist_content "$whitelist_file"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$whitelist_file"

    [ "$status" -eq 0 ]
}

@test "validate_whitelist_content rejects zero-domain content without integer expression errors" {
    local whitelist_file="$TEST_TMP_DIR/empty-whitelist.txt"
    local helper_script="$TEST_TMP_DIR/run-validate-empty-whitelist.sh"
    cat > "$whitelist_file" <<'EOF'
not a domain
EOF

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
whitelist_file="$2"
extracted_script="${TMPDIR:-/tmp}/openpath-update-validate.$$.$RANDOM.sh"

log_warn() { printf '%s\n' "$*"; }

cp "$project_dir/linux/lib/openpath-update-whitelist.sh" "$extracted_script"
source "$extracted_script"

MIN_VALID_DOMAINS=5
MAX_DOMAINS=500

validate_whitelist_content "$whitelist_file"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$whitelist_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Downloaded whitelist does not look valid"* ]]
    [[ "$output" != *"integer expression expected"* ]]
}

@test "main falls back to permissive mode when firewall activation fails after DNS recovery" {
    local helper_script="$TEST_TMP_DIR/run-main-firewall-fallback.sh"
    local state_dir="$TEST_TMP_DIR/update-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/openpath-update-main.sh"

export WHITELIST_FILE="$state_dir/whitelist.txt"
export DNSMASQ_CONF="$state_dir/openpath.conf"
export DNSMASQ_CONF_HASH="$state_dir/openpath.conf.hash"
export BROWSER_POLICIES_HASH="$state_dir/browser.hash"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export INSTALL_DIR="$state_dir/install"
export LOG_FILE="$state_dir/openpath.log"

mkdir -p "$state_dir"
: > "$WHITELIST_FILE"
: > "$DNSMASQ_CONF"
mkdir -p "$INSTALL_DIR/lib"
cp "$project_dir/linux/lib/common.sh" "$INSTALL_DIR/lib/"
: > "$INSTALL_DIR/VERSION"
: > "$INSTALL_DIR/lib/defaults.conf"

source "$project_dir/linux/lib/common.sh"

activate_calls=0
deactivate_calls=0

log() { echo "$1"; }
log_warn() { echo "$1"; }
init_directories() { :; }
detect_primary_dns() { echo "8.8.8.8"; }
check_captive_portal() { return 1; }
download_whitelist() { return 0; }
check_emergency_disable() { return 1; }
parse_whitelist_sections() { :; }
check_firewall_status() { echo "inactive"; }
save_checkpoint() { :; }
generate_dnsmasq_config() { :; }
require_openpath_request_setup_complete() { :; }
generate_chromium_policies() { :; }
get_policies_hash() { echo "policies-hash"; }
has_config_changed() { return 0; }
restart_dnsmasq() { return 0; }
verify_dns() { return 0; }
activate_firewall() { activate_calls=$((activate_calls + 1)); return 1; }
deactivate_firewall() { deactivate_calls=$((deactivate_calls + 1)); echo "deactivate_firewall called"; return 0; }
cleanup_system() { :; }
flush_connections() { :; }
force_browser_close() { :; }
sha256sum() { printf 'deadbeef  %s\n' "$1"; }

{
    cat "$project_dir/linux/lib/openpath-update-runtime.sh"
    awk '/^main\(\) \{/,/^}/' \
        "$project_dir/linux/scripts/runtime/openpath-update.sh"
} > "$extracted_script"
source "$extracted_script"

main

printf 'activate_calls=%s\n' "$activate_calls"
printf 'deactivate_calls=%s\n' "$deactivate_calls"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"activate_calls=1"* ]]
    [[ "$output" == *"deactivate_calls=1"* ]]
}

@test "openpath update processes runtime dependency queue before dnsmasq render" {
    local helper_script="$TEST_TMP_DIR/run-main-runtime-dependency-order.sh"
    local state_dir="$TEST_TMP_DIR/update-runtime-dependency-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/openpath-update-main.sh"

export WHITELIST_FILE="$state_dir/whitelist.txt"
export DNSMASQ_CONF="$state_dir/openpath.conf"
export DNSMASQ_CONF_HASH="$state_dir/openpath.conf.hash"
export BROWSER_POLICIES_HASH="$state_dir/browser.hash"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export INSTALL_DIR="$state_dir/install"
export LOG_FILE="$state_dir/openpath.log"

mkdir -p "$state_dir" "$INSTALL_DIR/lib"
cat > "$WHITELIST_FILE" <<'WHITELIST'
## WHITELIST
allowed.example
WHITELIST
: > "$DNSMASQ_CONF"
cp "$project_dir/linux/lib/common.sh" "$INSTALL_DIR/lib/"
: > "$INSTALL_DIR/VERSION"
: > "$INSTALL_DIR/lib/defaults.conf"

source "$project_dir/linux/lib/common.sh"

events=()
log() { :; }
log_warn() { echo "$1"; }
init_directories() { :; }
detect_primary_dns() { echo "8.8.8.8"; }
get_captive_portal_state() { echo "CLEAR"; }
download_whitelist() { return 0; }
check_emergency_disable() { return 1; }
parse_whitelist_sections() { events+=("parse"); WHITELIST_DOMAINS=("allowed.example"); BLOCKED_SUBDOMAINS=(); }
process_runtime_dependency_queue() { events+=("queue"); }
check_firewall_status() { echo "active"; }
save_checkpoint() { :; }
generate_dnsmasq_config() { events+=("dns"); }
sync_runtime_browser_integrations() { :; }
get_policies_hash() { echo "policies-hash"; }
has_config_changed() { return 1; }
restart_dnsmasq() { events+=("restart"); return 0; }
verify_dns() { return 0; }
activate_firewall() { :; }
deactivate_firewall() { :; }
cleanup_system() { :; }
flush_connections() { :; }
force_browser_close() { :; }
sha256sum() { printf 'deadbeef  %s\n' "$1"; }

{
    cat "$project_dir/linux/lib/openpath-update-runtime.sh"
    awk '/^main\(\) \{/,/^}/' \
        "$project_dir/linux/scripts/runtime/openpath-update.sh"
} > "$extracted_script"
source "$extracted_script"

main
printf '%s\n' "${events[*]}"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"parse queue dns"* ]]
}

@test "main keeps enforcement path when captive portal state is NO_NETWORK" {
    local helper_script="$TEST_TMP_DIR/run-main-no-network.sh"
    local state_dir="$TEST_TMP_DIR/update-state-no-network"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/openpath-update-main.sh"

export WHITELIST_FILE="$state_dir/whitelist.txt"
export DNSMASQ_CONF="$state_dir/openpath.conf"
export DNSMASQ_CONF_HASH="$state_dir/openpath.conf.hash"
export BROWSER_POLICIES_HASH="$state_dir/browser.hash"
export SYSTEM_DISABLED_FLAG="$state_dir/system-disabled.flag"
export INSTALL_DIR="$state_dir/install"
export LOG_FILE="$state_dir/openpath.log"

mkdir -p "$state_dir"
: > "$WHITELIST_FILE"
: > "$DNSMASQ_CONF"
mkdir -p "$INSTALL_DIR/lib"
cp "$project_dir/linux/lib/common.sh" "$INSTALL_DIR/lib/"
: > "$INSTALL_DIR/VERSION"
: > "$INSTALL_DIR/lib/defaults.conf"

source "$project_dir/linux/lib/common.sh"

activate_calls=0
deactivate_calls=0
download_calls=0

log() { echo "$1"; }
log_warn() { echo "$1"; }
init_directories() { :; }
detect_primary_dns() { echo "8.8.8.8"; }
get_captive_portal_state() { echo "NO_NETWORK"; }
download_whitelist() { download_calls=$((download_calls + 1)); return 0; }
check_emergency_disable() { return 1; }
parse_whitelist_sections() { :; }
check_firewall_status() { echo "active"; }
save_checkpoint() { :; }
generate_dnsmasq_config() { :; }
generate_chromium_policies() { :; }
sync_firefox_managed_extension_policy() { :; }
get_policies_hash() { echo "policies-hash"; }
has_config_changed() { return 0; }
restart_dnsmasq() { return 0; }
verify_dns() { return 0; }
activate_firewall() { activate_calls=$((activate_calls + 1)); return 0; }
deactivate_firewall() { deactivate_calls=$((deactivate_calls + 1)); echo "deactivate_firewall called"; return 0; }
cleanup_system() { echo "cleanup_system called"; }
flush_connections() { :; }
force_browser_close() { :; }
sha256sum() { printf 'deadbeef  %s\n' "$1"; }

{
    cat "$project_dir/linux/lib/openpath-update-runtime.sh"
    awk '/^main\(\) \{/,/^}/' \
        "$project_dir/linux/scripts/runtime/openpath-update.sh"
} > "$extracted_script"
source "$extracted_script"

main

printf 'activate_calls=%s\n' "$activate_calls"
printf 'deactivate_calls=%s\n' "$deactivate_calls"
printf 'download_calls=%s\n' "$download_calls"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"download_calls=1"* ]]
    [[ "$output" == *"activate_calls=0"* ]]
    [[ "$output" == *"deactivate_calls=0"* ]]
    [[ "$output" != *"cleanup_system called"* ]]
}

@test "cleanup_system preserves Firefox managed extension baseline through reactivation" {
    local helper_script="$TEST_TMP_DIR/run-cleanup-reactivation-firefox.sh"
    local state_dir="$TEST_TMP_DIR/update-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
cleanup_script="$state_dir/openpath-update-cleanup.sh"

export CONFIG_DIR="$state_dir/config"
export INSTALL_DIR="$state_dir/install"
export FIREFOX_POLICIES="$state_dir/firefox/policies/policies.json"
export CHROMIUM_POLICIES_BASE="$state_dir/chromium/policies/managed"
export FIREFOX_EXTENSIONS_ROOT="$state_dir/share/mozilla/extensions"
export DNSMASQ_CONF="$state_dir/openpath.conf"
export DNSMASQ_CONF_HASH="$state_dir/openpath.conf.hash"
export BROWSER_POLICIES_HASH="$state_dir/browser.hash"
export PRIMARY_DNS="8.8.8.8"
export LOG_FILE="$state_dir/openpath.log"

mkdir -p "$CONFIG_DIR" "$INSTALL_DIR/lib" "$(dirname "$FIREFOX_POLICIES")" "$CHROMIUM_POLICIES_BASE" "$FIREFOX_EXTENSIONS_ROOT"

log() { :; }
deactivate_firewall() { :; }
flush_connections() { :; }
systemctl() { :; }

source "$project_dir/linux/lib/browser.sh"
source "$project_dir/linux/lib/common.sh"

add_extension_to_policies \
  "openpath-block-monitor@openpath" \
  "$state_dir/openpath.xpi" \
  "https://downloads.example/openpath-managed.xpi"

cp "$project_dir/linux/lib/openpath-update-runtime.sh" "$cleanup_script"
source "$cleanup_script"

cleanup_system

python3 - <<PYEOF
import json

with open("$FIREFOX_POLICIES", "r", encoding="utf-8") as fh:
    policies = json.load(fh)

policy_root = policies["policies"]
assert "openpath-block-monitor@openpath" in policy_root.get("ExtensionSettings", {})
assert "https://downloads.example/openpath-managed.xpi" not in policy_root.get("Extensions", {}).get("Install", [])
assert "openpath-block-monitor@openpath" in policy_root.get("Extensions", {}).get("Locked", [])
assert "WebsiteFilter" not in policy_root
assert "SearchEngines" not in policy_root
# Fail-open relaxes OpenPath's own firewall/dnsmasq enforcement but deliberately
# leaves the Firefox managed-extension policy intact: cleanup_browser_policies only
# clears Chromium policy files, so the managed extension and its DNS/SafeMode
# hardening baseline persist (the locked DoH-off is benign once dnsmasq is in
# passthrough, and prevents the browser from bypassing system DNS).
assert policy_root.get("DNSOverHTTPS", {}).get("Locked") is True, policy_root.get("DNSOverHTTPS")
PYEOF
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
}

@test "openpath-update reuses shared fail-open transition and runtime reconciliation helpers" {
    run grep -n "enter_fail_open_mode" "$PROJECT_DIR/linux/lib/openpath-update-runtime.sh"
    [ "$status" -eq 0 ]

    run grep -n "build_runtime_reconciliation_plan" "$PROJECT_DIR/linux/scripts/runtime/openpath-update.sh"
    [ "$status" -eq 0 ]

    run grep -n "apply_runtime_reconciliation_plan" "$PROJECT_DIR/linux/scripts/runtime/openpath-update.sh"
    [ "$status" -eq 0 ]
}

@test "openpath-update extracts browser integration synchronization into a dedicated helper" {
    run grep -n "sync_runtime_browser_integrations()" "$PROJECT_DIR/linux/lib/openpath-update-runtime.sh"
    [ "$status" -eq 0 ]
}

@test "openpath-update extracts captive portal preflight into explicit decision helpers" {
    run grep -n "resolve_captive_portal_preflight()" "$PROJECT_DIR/linux/lib/openpath-update-runtime.sh"
    [ "$status" -eq 0 ]

    run grep -n "apply_captive_portal_preflight()" "$PROJECT_DIR/linux/lib/openpath-update-runtime.sh"
    [ "$status" -eq 0 ]
}

@test "openpath-update extracts whitelist download fallback into explicit decision helpers" {
    run grep -n "resolve_whitelist_download_plan()" "$PROJECT_DIR/linux/lib/openpath-update-runtime.sh"
    [ "$status" -eq 0 ]

    run grep -n "apply_whitelist_download_plan()" "$PROJECT_DIR/linux/lib/openpath-update-runtime.sh"
    [ "$status" -eq 0 ]
}

@test "fail-safe whitelist expiry falls back before writing stale loopback upstream" {
    local helper_script="$TEST_TMP_DIR/run-fail-safe-upstream.sh"
    local state_dir="$TEST_TMP_DIR/fail-safe-upstream"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"

export DNSMASQ_CONF="$state_dir/openpath.conf"
export DNSMASQ_CONF_HASH="$state_dir/openpath.conf.hash"
export WHITELIST_MAX_AGE_HOURS="24"
export PRIMARY_DNS="127.0.0.1"
export OPENPATH_FALLBACK_DNS="9.9.9.9"

log() { :; }
log_warn() { :; }
systemctl() { :; }
append_fail_safe_allow_domain() { :; }

source "$project_dir/linux/lib/common.sh"
source "$project_dir/linux/lib/dns.sh"
source "$project_dir/linux/lib/openpath-update-runtime.sh"

set +e
apply_whitelist_download_plan fail_safe 30 0 updates.openpath.local
status=$?
set -e

printf 'status=%s\n' "$status"
cat "$DNSMASQ_CONF"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=1"* ]]
    [[ "$output" == *"server=9.9.9.9"* ]]
    [[ "$output" != *"server=127.0.0.1"* ]]
}

@test "openpath-update relies on shared get_url_host from common.sh" {
    run grep -n "^get_url_host()" "$PROJECT_DIR/linux/scripts/runtime/openpath-update.sh"
    [ "$status" -ne 0 ]
}

@test "runtime dependency queue writes valid dependency into overlay" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-policy.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-overlay.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-queue.sh"

    export VAR_STATE_DIR="$TEST_TMP_DIR/var/lib/openpath"
    export RUNTIME_DEPENDENCY_QUEUE_DIR="$VAR_STATE_DIR/runtime-dependency-queue"
    export RUNTIME_DEPENDENCY_OVERLAY_FILE="$VAR_STATE_DIR/runtime-dependency-overlay.json"
    mkdir -p "$RUNTIME_DEPENDENCY_QUEUE_DIR"
    chmod 1733 "$RUNTIME_DEPENDENCY_QUEUE_DIR"

    WHITELIST_DOMAINS=("allowed.example")
    BLOCKED_SUBDOMAINS=()
    write_runtime_dependency_queue_request "allowed.example" "cdn.example" "fetch"

    run process_runtime_dependency_queue

    [ "$status" -eq 0 ]
    [[ "$output" == *"processed=1"* ]]
    grep -q '"dependencyHost": "cdn.example"' "$RUNTIME_DEPENDENCY_OVERLAY_FILE"
}

@test "runtime dependency overlay prunes expired and blocked entries" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-policy.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-overlay.sh"

    export VAR_STATE_DIR="$TEST_TMP_DIR/var/lib/openpath"
    export RUNTIME_DEPENDENCY_OVERLAY_FILE="$VAR_STATE_DIR/runtime-dependency-overlay.json"
    mkdir -p "$VAR_STATE_DIR"
    cat > "$RUNTIME_DEPENDENCY_OVERLAY_FILE" <<'JSON'
{"version":1,"entries":[
  {"anchorHost":"allowed.example","dependencyHost":"cdn.example","requestTypes":["fetch"],"firstSeen":"2099-01-01T00:00:00Z","lastSeen":"2099-01-01T00:00:00Z","expiresAt":"2099-01-02T00:00:00Z","source":"firefox-webrequest-local"},
  {"anchorHost":"allowed.example","dependencyHost":"blocked.example","requestTypes":["script"],"firstSeen":"2099-01-01T00:00:00Z","lastSeen":"2099-01-01T00:00:00Z","expiresAt":"2099-01-02T00:00:00Z","source":"firefox-webrequest-local"}
]}
JSON
    WHITELIST_DOMAINS=("allowed.example")
    BLOCKED_SUBDOMAINS=("blocked.example")

    run get_runtime_dependency_domains --prune

    [ "$status" -eq 0 ]
    [[ "$output" == *"cdn.example"* ]]
    [[ "$output" != *"blocked.example"* ]]
}

@test "runtime dependency queue rejects or quarantines malformed and unsafe artifacts without losing new files" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-policy.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-overlay.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-queue.sh"

    export VAR_STATE_DIR="$TEST_TMP_DIR/var/lib/openpath"
    export RUNTIME_DEPENDENCY_QUEUE_DIR="$VAR_STATE_DIR/runtime-dependency-queue"
    export RUNTIME_DEPENDENCY_REJECTED_DIR="$VAR_STATE_DIR/runtime-dependency-rejected"
    export RUNTIME_DEPENDENCY_OVERLAY_FILE="$VAR_STATE_DIR/runtime-dependency-overlay.json"
    mkdir -p "$RUNTIME_DEPENDENCY_QUEUE_DIR"
    chmod 1733 "$RUNTIME_DEPENDENCY_QUEUE_DIR"
    printf '{bad json}\n' > "$RUNTIME_DEPENDENCY_QUEUE_DIR/bad.json"
    printf '{"anchorHost":"allowed.example","dependencyHost":"cdn.example","requestType":"fetch","url":"https://cdn.example/private"}\n' > "$RUNTIME_DEPENDENCY_QUEUE_DIR/sensitive.json"
    mkdir "$RUNTIME_DEPENDENCY_QUEUE_DIR/not-a-file.json"
    ln -s /etc/passwd "$RUNTIME_DEPENDENCY_QUEUE_DIR/link.json"
    dd if=/dev/zero of="$RUNTIME_DEPENDENCY_QUEUE_DIR/too-large.json" bs=5000 count=1 2>/dev/null

    WHITELIST_DOMAINS=("allowed.example")
    BLOCKED_SUBDOMAINS=()

    run process_runtime_dependency_queue

    [ "$status" -eq 0 ]
    [[ "$output" == *"rejected="* ]]
    [ ! -e "$RUNTIME_DEPENDENCY_QUEUE_DIR/bad.json" ]
    [ ! -e "$RUNTIME_DEPENDENCY_QUEUE_DIR/sensitive.json" ]
    [ ! -e "$RUNTIME_DEPENDENCY_QUEUE_DIR/not-a-file.json" ]
    [ ! -e "$RUNTIME_DEPENDENCY_QUEUE_DIR/link.json" ]
    [ ! -e "$RUNTIME_DEPENDENCY_QUEUE_DIR/too-large.json" ]
}

@test "runtime dependency queue processes a bounded batch and leaves overflow for convergence" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-policy.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-overlay.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-queue.sh"

    export VAR_STATE_DIR="$TEST_TMP_DIR/var/lib/openpath"
    export RUNTIME_DEPENDENCY_QUEUE_DIR="$VAR_STATE_DIR/runtime-dependency-queue"
    export RUNTIME_DEPENDENCY_OVERLAY_FILE="$VAR_STATE_DIR/runtime-dependency-overlay.json"
    export OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PROCESS_LIMIT=2
    mkdir -p "$RUNTIME_DEPENDENCY_QUEUE_DIR"
    chmod 1733 "$RUNTIME_DEPENDENCY_QUEUE_DIR"

    WHITELIST_DOMAINS=("allowed.example")
    BLOCKED_SUBDOMAINS=()
    write_runtime_dependency_queue_request "allowed.example" "cdn1.example" "fetch"
    write_runtime_dependency_queue_request "allowed.example" "cdn2.example" "fetch"
    write_runtime_dependency_queue_request "allowed.example" "cdn3.example" "fetch"

    run process_runtime_dependency_queue

    [ "$status" -eq 0 ]
    [ "$(find "$RUNTIME_DEPENDENCY_QUEUE_DIR" -maxdepth 1 -type f -name '*.json' | wc -l)" -eq 1 ]
}

@test "sync_runtime_browser_integrations applies managed Firefox sync before browser policy hashing" {
    local helper_script="$TEST_TMP_DIR/run-sync-runtime-browser-integrations.sh"
    local state_dir="$TEST_TMP_DIR/update-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/sync-runtime-browser-integrations.sh"

CALLS=()
record_call() {
    CALLS+=("$1")
}

generate_chromium_policies() { record_call "generate_chromium_policies"; }
sync_firefox_managed_extension_policy() {
    record_call "sync_firefox_managed_extension_policy:$1"
}
require_openpath_request_setup_complete() { record_call "require_openpath_request_setup_complete:$1"; }

cp "$project_dir/linux/lib/openpath-update-runtime.sh" "$extracted_script"
source "$extracted_script"

sync_runtime_browser_integrations

printf '%s\n' "${CALLS[@]}"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "require_openpath_request_setup_complete:runtime browser integration" ]
    [ "${lines[1]}" = "generate_chromium_policies" ]
    [ "${lines[2]}" = "sync_firefox_managed_extension_policy:/usr/share/openpath/firefox-release" ]
}

@test "sync_runtime_browser_integrations aborts before policy writes when request setup is incomplete" {
    local helper_script="$TEST_TMP_DIR/run-sync-runtime-browser-integrations-incomplete.sh"
    local state_dir="$TEST_TMP_DIR/update-state-incomplete"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/sync-runtime-browser-integrations.sh"

CALLS=()
record_call() {
    CALLS+=("$1")
}

generate_chromium_policies() { record_call "generate_chromium_policies"; }
sync_firefox_managed_extension_policy() { record_call "sync_firefox_managed_extension_policy:$1"; }
require_openpath_request_setup_complete() {
    record_call "require_openpath_request_setup_complete:$1"
    return 1
}

cp "$project_dir/linux/lib/openpath-update-runtime.sh" "$extracted_script"
source "$extracted_script"

set +e
sync_runtime_browser_integrations
status=$?
set -e

printf 'status=%s\n' "$status"
printf '%s\n' "${CALLS[@]}"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "status=1" ]
    [ "${lines[1]}" = "require_openpath_request_setup_complete:runtime browser integration" ]
    [ "${#lines[@]}" -eq 2 ]
}
