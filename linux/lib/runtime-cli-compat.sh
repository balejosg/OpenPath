#!/bin/bash

################################################################################
# runtime-cli-compat.sh - Explicit compatibility helpers for legacy CLI flows
################################################################################

# shellcheck disable=SC2034
ROTATION_AUTH_TOKEN=""
# shellcheck disable=SC2034
ROTATION_AUTH_SOURCE=""

load_rotation_legacy_secret() {
    if [ -f "$ETC_CONFIG_DIR/api-secret.conf" ]; then
        cat "$ETC_CONFIG_DIR/api-secret.conf"
        return 0
    fi

    return 1
}

rotation_legacy_secret_path() {
    printf '%s\n' "$ETC_CONFIG_DIR/api-secret.conf"
}

resolve_rotation_machine_token() {
    get_machine_token_from_whitelist_url_file 2>/dev/null || true
}

resolve_rotation_auth_with_compat() {
    ROTATION_AUTH_TOKEN="$(resolve_rotation_machine_token)"
    ROTATION_AUTH_SOURCE="machine token"

    if [ -n "$ROTATION_AUTH_TOKEN" ]; then
        return 0
    fi

    ROTATION_AUTH_TOKEN="$(load_rotation_legacy_secret 2>/dev/null || true)"
    if [ -n "$ROTATION_AUTH_TOKEN" ]; then
        ROTATION_AUTH_SOURCE="secreto legacy"
        return 0
    fi

    # shellcheck disable=SC2034
    ROTATION_AUTH_SOURCE=""
    return 1
}
