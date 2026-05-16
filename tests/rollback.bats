#!/usr/bin/env bats

load test_helper

setup() {
    # Setup standard temp dirs
    TEST_TMP_DIR=$(mktemp -d)
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    export ETC_CONFIG_DIR="$TEST_TMP_DIR/etc"
    export VAR_STATE_DIR="$TEST_TMP_DIR/var/lib"
    export LOG_FILE="$TEST_TMP_DIR/log/openpath.log"
    export CHECKPOINT_DIR="$VAR_STATE_DIR/checkpoints"
    
    mkdir -p "$INSTALL_DIR/lib"
    mkdir -p "$ETC_CONFIG_DIR"
    mkdir -p "$VAR_STATE_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$CHECKPOINT_DIR"
    
    # Copy libraries
    cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/"
    
    # Source the library
    source "$INSTALL_DIR/lib/common.sh"
    source "$INSTALL_DIR/lib/rollback.sh"
}

teardown() {
    rm -rf "$TEST_TMP_DIR"
}

@test "rollback: should identify if no checkpoints exist" {
    run has_checkpoint
    [ "$status" -ne 0 ]
}

@test "rollback: should identify when checkpoints exist" {
    mkdir -p "$CHECKPOINT_DIR/checkpoint-0"
    run has_checkpoint
    [ "$status" -eq 0 ]
}

@test "rollback: should list available checkpoints" {
    mkdir -p "$CHECKPOINT_DIR/checkpoint-0"
    echo '{"timestamp": "2025-01-01T00:00:00Z", "label": "test"}' > "$CHECKPOINT_DIR/checkpoint-0/metadata.json"
    run list_checkpoints
    [ "$status" -eq 0 ]
    [[ "${lines[1]}" == *"2025-01-01T00:00:00Z"* ]]
}

@test "rollback: list_checkpoints parses escaped checkpoint metadata with python json" {
    mkdir -p "$CHECKPOINT_DIR/checkpoint-0"
    cat > "$CHECKPOINT_DIR/checkpoint-0/metadata.json" <<'EOF'
{
  "label": "pre-update: \"quoted\"",
  "timestamp": "2025-01-01T00:00:00Z"
}
EOF

    run list_checkpoints

    [ "$status" -eq 0 ]
    [[ "${lines[1]}" == *'2025-01-01T00:00:00Z (pre-update: "quoted")'* ]]
}

@test "rollback: metadata parser returns nonzero for malformed json" {
    local metadata_file="$CHECKPOINT_DIR/bad-metadata.json"
    printf '{"timestamp": ' > "$metadata_file"

    run read_checkpoint_metadata_field "$metadata_file" "timestamp"

    [ "$status" -ne 0 ]
}

@test "rollback: CHECKPOINT_DIR should use VAR_STATE_DIR" {
    [[ "$CHECKPOINT_DIR" == "${VAR_STATE_DIR}/checkpoints" ]]
}

@test "rollback: CHECKPOINT_FILES should NOT contain legacy url-whitelist paths" {
    for file in "${CHECKPOINT_FILES[@]}"; do
        [[ "$file" != *"url-whitelist"* ]]
    done
}

@test "rollback: CHECKPOINT_FILES should include openpath.conf path" {
    local found=false
    for file in "${CHECKPOINT_FILES[@]}"; do
        if [[ "$file" == *"openpath.conf"* ]]; then
            found=true
            break
        fi
    done
    [ "$found" = "true" ]
}

@test "rollback: CHECKPOINT_FILES should include /var/lib/openpath/ path" {
    local found=false
    for file in "${CHECKPOINT_FILES[@]}"; do
        if [[ "$file" == *"/var/lib/openpath/"* ]] || [[ "$file" == "$VAR_STATE_DIR"* ]]; then
            found=true
            break
        fi
    done
    [ "$found" = "true" ]
}
