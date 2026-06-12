#!/bin/bash

# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

################################################################################
# rollback.sh - Checkpoint and rollback functionality
# Part of the OpenPath DNS system
#
# Provides save/restore checkpoint functionality for automatic recovery
################################################################################

# Ensure common.sh variables are available
# This script requires: VAR_STATE_DIR, DNSMASQ_CONF, FIREFOX_POLICIES, WHITELIST_FILE
if [ -z "${VAR_STATE_DIR:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/common.sh" ]; then
        # shellcheck source=common.sh
        source "$SCRIPT_DIR/common.sh"
    fi
fi

# Checkpoint directory - uses VAR_STATE_DIR from common.sh
CHECKPOINT_DIR="${VAR_STATE_DIR:-/var/lib/openpath}/checkpoints"
# Maximum checkpoints to retain.  Configurable via OPENPATH_MAX_CHECKPOINTS
# (defaults.conf) or the environment.  Mirrors the Windows MaxCheckpoints=3
# default in Save-OpenPathWhitelistCheckpoint.
MAX_CHECKPOINTS="${OPENPATH_MAX_CHECKPOINTS:-${MAX_CHECKPOINTS:-3}}"

# Files to checkpoint - uses variables from common.sh for consistency
CHECKPOINT_FILES=(
    "${DNSMASQ_CONF:-/etc/dnsmasq.d/openpath.conf}"
    "${FIREFOX_POLICIES:-/etc/firefox/policies/policies.json}"
    "${WHITELIST_FILE:-/var/lib/openpath/whitelist.txt}"
)

# Initialize checkpoint directory
init_checkpoints() {
    mkdir -p "$CHECKPOINT_DIR"
}

# Get current checkpoint number (0, 1, or 2)
get_current_checkpoint() {
    local current_file="$CHECKPOINT_DIR/.current"
    if [ -f "$current_file" ]; then
        cat "$current_file"
    else
        echo "0"
    fi
}

read_checkpoint_metadata_field() {
    local metadata_file="$1"
    local field="$2"

    [ -n "$metadata_file" ] && [ -f "$metadata_file" ] || return 1
    [ -n "$field" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    python3 - "$metadata_file" "$field" <<'PYEOF'
import json
import sys

metadata_file = sys.argv[1]
field = sys.argv[2]

try:
    with open(metadata_file, "r", encoding="utf-8") as handle:
        value = json.load(handle).get(field, "")
except (OSError, json.JSONDecodeError):
    sys.exit(1)

if value is None:
    value = ""

print(str(value))
PYEOF
}

# Save a checkpoint with all critical files
# Usage: save_checkpoint [optional_label]
save_checkpoint() {
    local label="${1:-auto}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local current
    current=$(get_current_checkpoint)
    local next=$(( (current + 1) % MAX_CHECKPOINTS ))
    local checkpoint_name="checkpoint-${next}"
    local checkpoint_path="$CHECKPOINT_DIR/$checkpoint_name"
    
    init_checkpoints
    
    # Remove old checkpoint if exists
    rm -rf "$checkpoint_path"
    mkdir -p "$checkpoint_path"
    
    # Save each file
    local saved=0
    for file in "${CHECKPOINT_FILES[@]}"; do
        if [ -f "$file" ]; then
            local dest_dir
            dest_dir="$checkpoint_path$(dirname "$file")"
            mkdir -p "$dest_dir"
            cp -p "$file" "$dest_dir/" 2>/dev/null && saved=$((saved + 1))
        fi
    done
    
    # Save metadata (using timestamp variable for checkpoint identification)
    cat > "$checkpoint_path/metadata.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "timestamp_id": "$timestamp",
    "label": "$label",
    "files_saved": $saved,
    "version": "${VERSION:-4.1.0}"
}
EOF
    
    # Update current pointer
    echo "$next" > "$CHECKPOINT_DIR/.current"
    
    log_info "[ROLLBACK] Checkpoint saved: $checkpoint_name ($saved files)"
    return 0
}

# Restore from the most recent valid checkpoint
# Usage: restore_checkpoint [checkpoint_number]
restore_checkpoint() {
    local target="${1:-}"
    local checkpoint_path

    if [ -n "$target" ]; then
        checkpoint_path="$CHECKPOINT_DIR/checkpoint-$target"
    else
        # Find most recent checkpoint
        local current
        current=$(get_current_checkpoint)
        checkpoint_path="$CHECKPOINT_DIR/checkpoint-$current"
    fi
    
    if [ ! -d "$checkpoint_path" ]; then
        log_error "[ROLLBACK] No checkpoint found at $checkpoint_path"
        return 1
    fi
    
    log_info "[ROLLBACK] Restoring from $checkpoint_path..."
    
    # Stop dnsmasq before restoring
    systemctl stop dnsmasq 2>/dev/null || true
    
    # Restore each file
    local restored=0
    for file in "${CHECKPOINT_FILES[@]}"; do
        local src="$checkpoint_path$file"
        if [ -f "$src" ]; then
            local dest_dir
            dest_dir=$(dirname "$file")
            mkdir -p "$dest_dir"
            cp -p "$src" "$file" 2>/dev/null && restored=$((restored + 1))
        fi
    done
    
    # Restart dnsmasq
    systemctl start dnsmasq 2>/dev/null
    
    log_info "[ROLLBACK] Restored $restored files from checkpoint"
    return 0
}

# List available checkpoints
list_checkpoints() {
    init_checkpoints
    
    echo "Available checkpoints:"
    for i in $(seq 0 $((MAX_CHECKPOINTS - 1))); do
        local cp_path="$CHECKPOINT_DIR/checkpoint-$i"
        if [ -d "$cp_path" ] && [ -f "$cp_path/metadata.json" ]; then
            local ts
            ts=$(read_checkpoint_metadata_field "$cp_path/metadata.json" "timestamp" || true)
            local label
            label=$(read_checkpoint_metadata_field "$cp_path/metadata.json" "label" || true)
            local current
            current=$(get_current_checkpoint)
            local marker=""
            [ "$i" = "$current" ] && marker=" <- current"
            echo "  [$i] $ts ($label)$marker"
        fi
    done
}

# Check if any checkpoint exists
has_checkpoint() {
    init_checkpoints
    local i
    for i in $(seq 0 $((MAX_CHECKPOINTS - 1))); do
        [ -d "$CHECKPOINT_DIR/checkpoint-$i" ] && return 0
    done
    return 1
}

# Get previous checkpoint (for rollback)
get_previous_checkpoint() {
    local current
    current=$(get_current_checkpoint)
    local previous=$(( (current - 1 + MAX_CHECKPOINTS) % MAX_CHECKPOINTS ))
    
    if [ -d "$CHECKPOINT_DIR/checkpoint-$previous" ]; then
        echo "$previous"
    else
        echo ""
    fi
}
