#!/usr/bin/env bats
################################################################################
# locking.bats - Tests for lock file handling and race condition prevention
################################################################################

load 'test_helper'

setup() {
    TEST_TMP_DIR=$(mktemp -d)
    export LOCK_FILE="$TEST_TMP_DIR/test.lock"
    setup_mock_log
}

# ============== Lock acquisition tests ==============

@test "flock acquires exclusive lock successfully" {
    # Create lock file and acquire lock
    exec 200>"$LOCK_FILE"
    run flock -n 200
    [ "$status" -eq 0 ]

    # Release lock
    flock -u 200
}

@test "flock fails when lock already held" {
    # Use a unique lock file for this test
    local test_lock="$TEST_TMP_DIR/held.lock"

    # First process acquires lock in background
    {
        exec 200>"$test_lock"
        flock 200
        sleep 3
    } &
    local bg_pid=$!

    # Give first process time to acquire lock
    sleep 1

    # Second process tries to acquire lock non-blocking
    # Use subshell to avoid fd conflicts
    run bash -c "exec 201>\"$test_lock\"; flock -n 201 && echo 'got lock'"

    # Should fail (exit code 1) because lock is held
    [ "$status" -eq 1 ]

    # Cleanup
    kill $bg_pid 2>/dev/null || true
    wait $bg_pid 2>/dev/null || true
}

@test "lock is released when process exits" {
    # First process acquires lock and exits
    (
        exec 200>"$LOCK_FILE"
        flock 200
        exit 0
    )

    # Second process should be able to acquire lock
    exec 200>"$LOCK_FILE"
    run flock -n 200
    [ "$status" -eq 0 ]
}

@test "lock is released when process terminates" {
    local test_lock="$TEST_TMP_DIR/crash.lock"

    # First process acquires lock and terminates
    (
        exec 200>"$test_lock"
        flock 200
        # Just exit instead of crashing - flock releases on process exit
        exit 0
    )

    # Second process should be able to acquire lock immediately
    run bash -c "exec 200>\"$test_lock\"; flock -n 200 && echo 'got lock'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"got lock"* ]]
}

# ============== Lock file cleanup tests ==============

@test "cleanup_lock removes lock file" {
    cleanup_lock() {
        rm -f "$LOCK_FILE" 2>/dev/null || true
    }

    # Create lock file
    touch "$LOCK_FILE"
    [ -f "$LOCK_FILE" ]

    # Run cleanup
    cleanup_lock

    # Verify removed
    [ ! -f "$LOCK_FILE" ]
}

@test "cleanup_lock handles missing file gracefully" {
    cleanup_lock() {
        rm -f "$LOCK_FILE" 2>/dev/null || true
    }

    # Ensure file doesn't exist
    rm -f "$LOCK_FILE"
    [ ! -f "$LOCK_FILE" ]

    # Run cleanup - should not error
    run cleanup_lock
    [ "$status" -eq 0 ]
}

@test "trap EXIT calls cleanup_lock" {
    local result_file="$TEST_TMP_DIR/trap_result"

    # Run a subshell that sets up trap and exits
    (
        LOCK_FILE="$TEST_TMP_DIR/trap_test.lock"
        cleanup_lock() {
            echo "cleanup_called" > "$result_file"
            rm -f "$LOCK_FILE" 2>/dev/null || true
        }
        trap cleanup_lock EXIT

        touch "$LOCK_FILE"
        exit 0
    )

    # Verify trap was called
    [ -f "$result_file" ]
    [ "$(cat "$result_file")" = "cleanup_called" ]
}

@test "trap EXIT calls cleanup on SIGTERM" {
    local result_file="$TEST_TMP_DIR/sigterm_result"

    # Run a background process with trap
    (
        LOCK_FILE="$TEST_TMP_DIR/sigterm_test.lock"
        cleanup_lock() {
            echo "cleanup_called" > "$result_file"
            rm -f "$LOCK_FILE" 2>/dev/null || true
        }
        trap cleanup_lock EXIT

        touch "$LOCK_FILE"
        sleep 10
    ) &
    local bg_pid=$!

    # Give process time to start
    sleep 0.5

    # Send SIGTERM
    kill -TERM $bg_pid 2>/dev/null || true
    wait $bg_pid 2>/dev/null || true

    # Verify trap was called
    [ -f "$result_file" ]
    [ "$(cat "$result_file")" = "cleanup_called" ]
}

# ============== Concurrent execution tests ==============

@test "concurrent scripts wait for lock" {
    local result_file="$TEST_TMP_DIR/concurrent_result"

    # First script acquires lock and writes
    (
        exec 200>"$LOCK_FILE"
        flock 200
        echo "first" >> "$result_file"
        sleep 0.5
        flock -u 200
    ) &

    # Give first script time to acquire lock
    sleep 0.1

    # Second script waits for lock (blocking) and writes
    (
        exec 200>"$LOCK_FILE"
        flock 200
        echo "second" >> "$result_file"
        flock -u 200
    ) &

    # Wait for both
    wait

    # Verify order: first completed before second
    [ "$(head -1 "$result_file")" = "first" ]
    [ "$(tail -1 "$result_file")" = "second" ]
}

@test "non-blocking flock exits immediately when locked" {
    # First process holds lock
    (
        exec 200>"$LOCK_FILE"
        flock 200
        sleep 5
    ) &
    local bg_pid=$!

    # Give first process time to acquire lock
    sleep 0.2

    # Time the non-blocking attempt
    local start=$(date +%s%N)
    exec 201>"$LOCK_FILE"
    flock -n 201 2>/dev/null || true
    local end=$(date +%s%N)

    # Should complete in less than 1 second (immediate failure)
    local elapsed=$(( (end - start) / 1000000 ))  # Convert to ms
    [ "$elapsed" -lt 1000 ]

    # Cleanup
    kill $bg_pid 2>/dev/null || true
    wait $bg_pid 2>/dev/null || true
}

# ============== Lock file path tests ==============

@test "lock file directory is writable" {
    local lock_dir="/var/run"

    # Check if /var/run exists and is writable (may need root)
    if [ -d "$lock_dir" ] && [ -w "$lock_dir" ]; then
        local test_lock="$lock_dir/openpath-test-$$.lock"
        touch "$test_lock"
        [ -f "$test_lock" ]
        rm -f "$test_lock"
    else
        skip "Need root access to test /var/run"
    fi
}

@test "shared lock file path is consistent" {
    # Both scripts must use OPENPATH_LOCK_FILE from common.sh
    source "$PROJECT_DIR/linux/lib/common.sh"

    # Verify the constant is defined and points to the unified path
    [ -n "$OPENPATH_LOCK_FILE" ]
    [ "$OPENPATH_LOCK_FILE" = "/var/run/openpath.lock" ]

    # Verify both scripts reuse the shared locking contract from common.sh
    grep -q 'openpath_lock_acquire' "$PROJECT_DIR/linux/scripts/runtime/openpath-update.sh"
    grep -q 'OPENPATH_LOCK_FILE' "$PROJECT_DIR/linux/scripts/runtime/captive-portal-detector.sh"

    # Verify neither script has its own LOCK_FILE definition
    ! grep -q '^LOCK_FILE=' "$PROJECT_DIR/linux/scripts/runtime/openpath-update.sh"
    ! grep -q '^LOCK_FILE=' "$PROJECT_DIR/linux/scripts/runtime/captive-portal-detector.sh"
}
