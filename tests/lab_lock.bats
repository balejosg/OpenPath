#!/usr/bin/env bats
# Phase 3A G3: lab lock protocol (owner + heartbeat, bounded wait, replacement
# log). The same script runs on the Proxmox host through the CI transport.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    LOCK_SCRIPT="$REPO_ROOT/tests/e2e/ci/controllers/proxmox-lab-lock.sh"
    WORK_DIR="$(mktemp -d)"
    LOCK_DIR="$WORK_DIR/lab.lock"
}

teardown() {
    rm -rf "$WORK_DIR"
}

@test "free lock is acquired with owner, created and heartbeat files" {
    run bash "$LOCK_SCRIPT" acquire "$LOCK_DIR" "run/1/scenario" 1800 5
    [ "$status" -eq 0 ]
    [ "$output" = "acquired" ]
    [ "$(cat "$LOCK_DIR/owner")" = "run/1/scenario" ]
    [ -n "$(cat "$LOCK_DIR/created")" ]
    [ -n "$(cat "$LOCK_DIR/heartbeat")" ]
}

@test "a live lock is waited for and never stolen" {
    bash "$LOCK_SCRIPT" acquire "$LOCK_DIR" "owner-a" 1800 5 >/dev/null
    start=$(date +%s)
    run bash "$LOCK_SCRIPT" acquire "$LOCK_DIR" "owner-b" 1800 2
    elapsed=$(( $(date +%s) - start ))
    [ "$output" = "busy" ]
    [ "$elapsed" -ge 2 ]
    [ "$(cat "$LOCK_DIR/owner")" = "owner-a" ]
    [ ! -f "$LOCK_DIR.replacements.log" ]
}

@test "the same owner re-acquires and refreshes its heartbeat" {
    bash "$LOCK_SCRIPT" acquire "$LOCK_DIR" "owner-a" 1800 5 >/dev/null
    first_heartbeat=$(cat "$LOCK_DIR/heartbeat")
    sleep 1
    run bash "$LOCK_SCRIPT" renew "$LOCK_DIR" "owner-a"
    [ "$output" = "renewed" ]
    [ "$(cat "$LOCK_DIR/heartbeat")" -gt "$first_heartbeat" ]
}

@test "a stale heartbeat (not a stale created) is replaced and recorded" {
    bash "$LOCK_SCRIPT" acquire "$LOCK_DIR" "dead-run/1/scenario" 1800 5 >/dev/null
    long_ago=$(( $(date +%s) - 4000 ))
    echo "$long_ago" > "$LOCK_DIR/created"
    echo "$long_ago" > "$LOCK_DIR/heartbeat"
    run bash "$LOCK_SCRIPT" acquire "$LOCK_DIR" "manual/2" 1800 5
    [ "$output" = "acquired" ]
    [ "$(cat "$LOCK_DIR/owner")" = "manual/2" ]
    run cat "$LOCK_DIR.replacements.log"
    [[ "$output" == *"previous-owner=dead-run/1/scenario"* ]]
    [[ "$output" == *"new-owner=manual/2"* ]]
}

@test "an old created timestamp with a live heartbeat is not stale" {
    bash "$LOCK_SCRIPT" acquire "$LOCK_DIR" "live-run/1/scenario" 1800 5 >/dev/null
    long_ago=$(( $(date +%s) - 4000 ))
    echo "$long_ago" > "$LOCK_DIR/created"
    date +%s > "$LOCK_DIR/heartbeat"
    run bash "$LOCK_SCRIPT" acquire "$LOCK_DIR" "other/1" 1800 1
    [ "$output" = "busy" ]
    [ "$(cat "$LOCK_DIR/owner")" = "live-run/1/scenario" ]
}

@test "release only works for the owner and status reports the live lock" {
    bash "$LOCK_SCRIPT" acquire "$LOCK_DIR" "owner-a" 1800 5 >/dev/null
    run bash "$LOCK_SCRIPT" release "$LOCK_DIR" "owner-b"
    [ "$output" = "not-owner" ]
    run bash "$LOCK_SCRIPT" status "$LOCK_DIR"
    [[ "$output" == owner=owner-a* ]]
    run bash "$LOCK_SCRIPT" release "$LOCK_DIR" "owner-a"
    [ "$output" = "released" ]
    run bash "$LOCK_SCRIPT" status "$LOCK_DIR"
    [ "$output" = "free" ]
}
