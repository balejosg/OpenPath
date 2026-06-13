#!/usr/bin/env bats
################################################################################
# checkpoint-parity.bats - Linux checkpoint/rollback parity tests (T5)
#
# Verifies: checkpoint creation, pruning to MAX_CHECKPOINTS, restore path,
# corrupted-whitelist scenario, and configurable max-checkpoints knob.
# Mirrors the behaviour specified for Save-OpenPathWhitelistCheckpoint /
# Restore-OpenPathLatestCheckpoint on Windows.
################################################################################

load 'test_helper'

# ---------------------------------------------------------------------------
# Per-test setup: isolated temp dirs with enough stubs to source rollback.sh
# ---------------------------------------------------------------------------

setup() {
    TEST_TMP_DIR=$(mktemp -d)

    export VAR_STATE_DIR="$TEST_TMP_DIR/var/lib/openpath"
    export CHECKPOINT_DIR="$VAR_STATE_DIR/checkpoints"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    export LOG_FILE="$TEST_TMP_DIR/openpath.log"

    # Fake dnsmasq conf and whitelist that rollback.sh checkpoints
    export DNSMASQ_CONF="$TEST_TMP_DIR/etc/dnsmasq.d/openpath.conf"
    export FIREFOX_POLICIES="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    export WHITELIST_FILE="$VAR_STATE_DIR/whitelist.txt"

    mkdir -p "$VAR_STATE_DIR" "$CHECKPOINT_DIR" "$INSTALL_DIR/lib" \
             "$(dirname "$DNSMASQ_CONF")" \
             "$(dirname "$FIREFOX_POLICIES")" \
             "$(dirname "$LOG_FILE")"

    cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/"

    # Minimal stubs required by common.sh before rollback.sh
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/lib/common.sh"
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/lib/rollback.sh"
}

teardown() {
    rm -rf "$TEST_TMP_DIR"
}

# ---------------------------------------------------------------------------
# Helper: write distinguishable content to the checkpointed files
# ---------------------------------------------------------------------------
_write_source_files() {
    local tag="${1:-v1}"
    printf 'dnsmasq-conf-%s\n' "$tag" > "$DNSMASQ_CONF"
    printf 'firefox-policies-%s\n' "$tag" > "$FIREFOX_POLICIES"
    printf 'whitelist-%s\n' "$tag" > "$WHITELIST_FILE"
}

# ===========================================================================
# 1. Checkpoint creation
# ===========================================================================

@test "checkpoint: save_checkpoint creates checkpoint directory with metadata" {
    _write_source_files "initial"

    save_checkpoint "pre-update"

    local current
    current=$(get_current_checkpoint)
    local cp_dir="$CHECKPOINT_DIR/checkpoint-$current"

    [ -d "$cp_dir" ]
    [ -f "$cp_dir/metadata.json" ]
}

@test "checkpoint: save_checkpoint copies whitelist file into checkpoint" {
    _write_source_files "initial"

    save_checkpoint "pre-update"

    local current
    current=$(get_current_checkpoint)
    local cp_dir="$CHECKPOINT_DIR/checkpoint-$current"

    # The whitelist must be present under the checkpoint's mirrored path
    local stored_whitelist="$cp_dir$WHITELIST_FILE"
    [ -f "$stored_whitelist" ]
    grep -q "whitelist-initial" "$stored_whitelist"
}

@test "checkpoint: save_checkpoint copies dnsmasq config into checkpoint" {
    _write_source_files "initial"

    save_checkpoint "pre-update"

    local current
    current=$(get_current_checkpoint)
    local stored="$CHECKPOINT_DIR/checkpoint-$current$DNSMASQ_CONF"

    [ -f "$stored" ]
    grep -q "dnsmasq-conf-initial" "$stored"
}

@test "checkpoint: metadata.json contains expected label and timestamp fields" {
    _write_source_files "initial"

    save_checkpoint "pre-update"

    local current
    current=$(get_current_checkpoint)
    local meta="$CHECKPOINT_DIR/checkpoint-$current/metadata.json"

    [ -f "$meta" ]
    grep -q '"label"' "$meta"
    grep -q '"pre-update"' "$meta"
    grep -q '"timestamp"' "$meta"
}

@test "checkpoint: has_checkpoint returns true after first save" {
    _write_source_files "initial"
    save_checkpoint "pre-update"

    run has_checkpoint
    [ "$status" -eq 0 ]
}

# ===========================================================================
# 2. Pruning to MAX_CHECKPOINTS
# ===========================================================================

@test "checkpoint: MAX_CHECKPOINTS default is 3" {
    [ "$MAX_CHECKPOINTS" -eq 3 ]
}

@test "checkpoint: MAX_CHECKPOINTS is overridable via OPENPATH_MAX_CHECKPOINTS" {
    # Re-source rollback.sh with the env var set
    local helper="$TEST_TMP_DIR/check-max.sh"
    cat > "$helper" << 'HELPER'
#!/bin/bash
export VAR_STATE_DIR="$1"
export OPENPATH_MAX_CHECKPOINTS=5
source "$2"
printf '%s\n' "$MAX_CHECKPOINTS"
HELPER
    chmod +x "$helper"

    run "$helper" "$VAR_STATE_DIR" "$PROJECT_DIR/linux/lib/rollback.sh"

    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "checkpoint: after N+1 saves only N slots exist" {
    _write_source_files "a"

    # With MAX_CHECKPOINTS=3, after 4 saves slot 0 is overwritten
    local i
    for i in 1 2 3 4; do
        _write_source_files "iter-$i"
        save_checkpoint "cycle-$i"
    done

    # Count actual checkpoint directories
    local count
    count=$(find "$CHECKPOINT_DIR" -maxdepth 1 -type d -name 'checkpoint-*' | wc -l)
    [ "$count" -eq "$MAX_CHECKPOINTS" ]
}

@test "checkpoint: save_checkpoint advances the .current pointer on each call" {
    _write_source_files "a"
    save_checkpoint "first"
    local after_first
    after_first=$(get_current_checkpoint)

    _write_source_files "b"
    save_checkpoint "second"
    local after_second
    after_second=$(get_current_checkpoint)

    [ "$after_first" -ne "$after_second" ]
}

# ===========================================================================
# 3. Restore path
# ===========================================================================

@test "checkpoint: restore_checkpoint restores whitelist from latest checkpoint" {
    # Save a known-good state
    _write_source_files "good"
    save_checkpoint "good-state"
    local saved_slot
    saved_slot=$(get_current_checkpoint)

    # Overwrite whitelist with corrupted content
    printf 'CORRUPTED\n' > "$WHITELIST_FILE"

    # Restore and verify
    systemctl() { return 0; }
    export -f systemctl

    restore_checkpoint "$saved_slot"

    grep -q "whitelist-good" "$WHITELIST_FILE"
}

@test "checkpoint: restore_checkpoint restores dnsmasq config from checkpoint" {
    _write_source_files "good"
    save_checkpoint "good-state"
    local saved_slot
    saved_slot=$(get_current_checkpoint)

    printf 'BAD CONFIG\n' > "$DNSMASQ_CONF"

    systemctl() { return 0; }
    export -f systemctl

    restore_checkpoint "$saved_slot"

    grep -q "dnsmasq-conf-good" "$DNSMASQ_CONF"
}

@test "checkpoint: restore_checkpoint returns non-zero when no checkpoint directory exists" {
    systemctl() { return 0; }
    export -f systemctl

    run restore_checkpoint "99"

    [ "$status" -ne 0 ]
}

@test "checkpoint: get_previous_checkpoint returns slot before current" {
    _write_source_files "a"
    save_checkpoint "first"
    _write_source_files "b"
    save_checkpoint "second"

    local current
    current=$(get_current_checkpoint)
    local prev
    prev=$(get_previous_checkpoint)

    [ -n "$prev" ]
    [ "$prev" -ne "$current" ]
}

# ===========================================================================
# 4. Corrupted-whitelist scenario
# ===========================================================================

@test "checkpoint: corrupted whitelist is replaced by checkpoint restore" {
    # Save a valid whitelist
    _write_source_files "valid"
    save_checkpoint "pre-update"
    local saved_slot
    saved_slot=$(get_current_checkpoint)

    # Corrupt the whitelist (simulate a bad download applied to disk)
    dd if=/dev/urandom of="$WHITELIST_FILE" bs=64 count=1 2>/dev/null

    systemctl() { return 0; }
    export -f systemctl

    restore_checkpoint "$saved_slot"

    # After restore the whitelist must contain the original content
    grep -q "whitelist-valid" "$WHITELIST_FILE"
}

@test "checkpoint: watchdog attempt_rollback_recovery restores previous checkpoint" {
    # Build a minimal harness that sources rollback.sh and the watchdog's
    # attempt_rollback_recovery, then simulates a health-check scenario.
    #
    # attempt_rollback_recovery uses get_previous_checkpoint, which resolves the
    # slot *before* current.  We must save two checkpoints so a valid previous
    # slot exists:
    #   slot 1 = good state (first save advances from 0 to 1)
    #   slot 2 = corrupted state (second save advances to 2)
    # get_previous_checkpoint then returns slot 1, which holds the good state.
    local harness="$TEST_TMP_DIR/rollback-watchdog-harness.sh"
    cat > "$harness" << 'HARNESS'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
whitelist_file="$3"

export VAR_STATE_DIR="$state_dir"
export CHECKPOINT_DIR="$state_dir/checkpoints"
export DNSMASQ_CONF="$state_dir/openpath.conf"
export FIREFOX_POLICIES="$state_dir/firefox/policies.json"
export WHITELIST_FILE="$whitelist_file"
export LOG_FILE="$state_dir/openpath.log"
export FAIL_COUNT_FILE="$state_dir/watchdog-fails"

mkdir -p "$CHECKPOINT_DIR" "$(dirname "$DNSMASQ_CONF")" \
         "$(dirname "$FIREFOX_POLICIES")" "$(dirname "$LOG_FILE")"

# Minimal log stubs
log()       { echo "[LOG] $*"; }
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }

# systemctl stub — no-op in tests
systemctl() { return 0; }

source "$project_dir/linux/lib/rollback.sh"

# --- Checkpoint 1: known-good state ---
printf 'good-whitelist-content\n' > "$WHITELIST_FILE"
printf 'good-dnsmasq-config\n'   > "$DNSMASQ_CONF"
save_checkpoint "good"

# --- Checkpoint 2: corrupted state (simulates a bad update that was saved) ---
printf 'CORRUPTED\n'        > "$WHITELIST_FILE"
printf 'BAD DNSMASQ CONF\n' > "$DNSMASQ_CONF"
save_checkpoint "bad-update"

# The watchdog calls attempt_rollback_recovery which uses get_previous_checkpoint
# to roll back to the state *before* the last save — i.e., the good checkpoint.

# Extract attempt_rollback_recovery from the watchdog
extracted="$state_dir/rollback-recovery.sh"
awk '
    /^attempt_rollback_recovery\(\) \{/ { cap=1; depth=0 }
    cap && /\{/ { depth++ }
    cap && /\}/ { depth--; if (depth==0) { print; cap=0; next } }
    cap { print }
' "$project_dir/linux/scripts/runtime/dnsmasq-watchdog.sh" > "$extracted"

# Stubs for watchdog deps
check_dnsmasq_running() { return 0; }
check_dns_resolving()   { return 0; }
reset_fail_count()      { echo "0" > "$FAIL_COUNT_FILE"; }
# Post-restore validation passes (its own logic is unit-tested in rollback.bats).
validate_restored_checkpoint() { return 0; }

source "$extracted"

set +e
attempt_rollback_recovery
rc=$?
set -e

printf 'status=%s\n' "$rc"
printf 'whitelist=%s\n' "$(cat "$WHITELIST_FILE")"
HARNESS
    chmod +x "$harness"

    run "$harness" "$PROJECT_DIR" "$VAR_STATE_DIR" "$WHITELIST_FILE"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=0"* ]]
    [[ "$output" == *"whitelist=good-whitelist-content"* ]]
}

@test "checkpoint: rollback recovery keeps fail count when post-restore validation fails" {
    local harness="$TEST_TMP_DIR/rollback-validate-fail.sh"
    cat > "$harness" << 'HARNESS'
#!/bin/bash
set -uo pipefail

project_dir="$1"
state_dir="$2"
export FAIL_COUNT_FILE="$state_dir/watchdog-fails"
mkdir -p "$state_dir"
echo "3" > "$FAIL_COUNT_FILE"

log() { :; }

# Stub the watchdog deps so only the post-restore validation gate is exercised.
has_checkpoint()          { return 0; }
get_previous_checkpoint() { echo "1"; }
restore_checkpoint()      { return 0; }
check_dnsmasq_running()   { return 0; }
check_dns_resolving()     { return 0; }
# A corrupt/tampered restore: dnsmasq is back but the state is not canonical.
validate_restored_checkpoint() { return 1; }
reset_fail_count()        { echo "RESET_CALLED" > "$state_dir/reset-marker"; }

extracted="$state_dir/rollback-recovery.sh"
awk '
    /^attempt_rollback_recovery\(\) \{/ { cap=1; depth=0 }
    cap && /\{/ { depth++ }
    cap && /\}/ { depth--; if (depth==0) { print; cap=0; next } }
    cap { print }
' "$project_dir/linux/scripts/runtime/dnsmasq-watchdog.sh" > "$extracted"
source "$extracted"

attempt_rollback_recovery
printf 'status=%s\n' "$?"
printf 'reset=%s\n' "$( [ -f "$state_dir/reset-marker" ] && echo yes || echo no )"
printf 'failcount=%s\n' "$(cat "$FAIL_COUNT_FILE")"
HARNESS
    chmod +x "$harness"

    run "$harness" "$PROJECT_DIR" "$TEST_TMP_DIR/state"

    [ "$status" -eq 0 ]
    [[ "$output" == *"status=1"* ]]    # recovery reports failure, not success
    [[ "$output" == *"reset=no"* ]]    # fail count must NOT be reset
    [[ "$output" == *"failcount=3"* ]] # preserved so the next cycle retries
}
