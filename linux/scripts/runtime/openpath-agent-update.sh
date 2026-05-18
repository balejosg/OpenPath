#!/bin/bash

################################################################################
# openpath-agent-update.sh - Scheduled Linux agent update wrapper
# Part of the OpenPath DNS system
################################################################################

set -euo pipefail

INSTALL_DIR="/usr/local/lib/openpath"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$INSTALL_DIR/lib/common.sh" ]; then
    # shellcheck source=/usr/local/lib/openpath/lib/common.sh
    source "$INSTALL_DIR/lib/common.sh"
elif [ -f "$SCRIPT_DIR/../../lib/common.sh" ]; then
    # shellcheck source=../../lib/common.sh
    source "$SCRIPT_DIR/../../lib/common.sh"
else
    echo "ERROR: common.sh not found" >&2
    exit 1
fi

SELF_UPDATE_SCRIPT="${OPENPATH_SELF_UPDATE_SCRIPT:-$SCRIPTS_DIR/openpath-self-update.sh}"
STATE_FILE="${OPENPATH_AGENT_UPDATE_STATE_FILE:-$VAR_STATE_DIR/agent-update-state.json}"

read_current_version() {
    if [ -r "$INSTALL_DIR/VERSION" ]; then
        tr -d '\r\n' < "$INSTALL_DIR/VERSION"
        return 0
    fi

    printf '%s\n' "${VERSION:-0.0.0}"
}

json_escape() {
    printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

read_previous_success_timestamp() {
    if [ ! -r "$STATE_FILE" ]; then
        return 0
    fi

    grep -oP '"lastSuccessAt":\s*"\K[^"]+' "$STATE_FILE" 2>/dev/null | head -1 || true
}

write_state() {
    local status="$1"
    local message="$2"
    local current_version="$3"
    local checked_at=""
    local last_success_at=""

    checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    last_success_at=$(read_previous_success_timestamp)
    if [ "$status" = "success" ] || [ "$status" = "up-to-date" ]; then
        last_success_at="$checked_at"
    fi

    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
{
  "status": "$(json_escape "$status")",
  "lastCheckAt": "$(json_escape "$checked_at")",
  "lastSuccessAt": "$(json_escape "$last_success_at")",
  "currentVersion": "$(json_escape "$current_version")",
  "lastMessage": "$(json_escape "$message")"
}
EOF
}

main() {
    local current_version=""
    local output=""
    local status="failed"

    current_version=$(read_current_version)

    if [ ! -x "$SELF_UPDATE_SCRIPT" ]; then
        output="Self-update script not found at $SELF_UPDATE_SCRIPT"
        printf '%s\n' "$output" >&2
        write_state "$status" "$output" "$current_version"
        exit 1
    fi

    if output=$("$SELF_UPDATE_SCRIPT" "$@" 2>&1); then
        printf '%s\n' "$output"
        if printf '%s\n' "$output" | grep -q "You already have the latest version"; then
            status="up-to-date"
        else
            status="success"
        fi
        current_version=$(read_current_version)
        write_state "$status" "$output" "$current_version"
        exit 0
    fi

    printf '%s\n' "$output" >&2
    current_version=$(read_current_version)
    write_state "$status" "$output" "$current_version"
    exit 1
}

main "$@"
