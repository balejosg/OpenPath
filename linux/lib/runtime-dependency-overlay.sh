#!/bin/bash

get_runtime_dependency_overlay_file() {
    printf '%s\n' "${RUNTIME_DEPENDENCY_OVERLAY_FILE:-${VAR_STATE_DIR:-/var/lib/openpath}/runtime-dependency-overlay.json}"
}

get_runtime_dependency_overlay_ttl_days() {
    printf '%s\n' "${OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_TTL_DAYS:-7}"
}

get_runtime_dependency_overlay_capacity() {
    printf '%s\n' "${OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_CAPACITY:-300}"
}

get_runtime_dependency_protected_hosts_arg() {
    if declare -F get_openpath_protected_domains >/dev/null 2>&1; then
        get_openpath_protected_domains | tr '\n' ' '
    fi
}

get_runtime_dependency_overlay_helper() {
    local helper="${INSTALL_DIR:-/usr/local/lib/openpath}/libexec/runtime-dependency-overlay.py"
    if [ -f "$helper" ]; then
        printf '%s\n' "$helper"
        return 0
    fi
    helper="$(dirname "${BASH_SOURCE[0]}")/../libexec/runtime-dependency-overlay.py"
    [ -f "$helper" ] || return 1
    printf '%s\n' "$helper"
}

update_runtime_dependency_overlay_from_requests() {
    local request_file="$1"
    local overlay_file
    local helper
    overlay_file="$(get_runtime_dependency_overlay_file)"
    helper="$(get_runtime_dependency_overlay_helper)"
    mkdir -p "$(dirname "$overlay_file")"

    python3 "$helper" \
        update \
        --overlay "$overlay_file" \
        --requests "$request_file" \
        --ttl-days "$(get_runtime_dependency_overlay_ttl_days)" \
        --capacity "$(get_runtime_dependency_overlay_capacity)" \
        --whitelist "${WHITELIST_DOMAINS[*]}" \
        --protected-hosts "$(get_runtime_dependency_protected_hosts_arg)" \
        --blocked-subdomains "${BLOCKED_SUBDOMAINS[*]}"
}

get_runtime_dependency_domains() {
    local prune=false
    [ "${1:-}" = "--prune" ] && prune=true
    local overlay_file
    local helper
    overlay_file="$(get_runtime_dependency_overlay_file)"
    helper="$(get_runtime_dependency_overlay_helper)"

    python3 "$helper" \
        domains \
        --overlay "$overlay_file" \
        --prune "$prune" \
        --whitelist "${WHITELIST_DOMAINS[*]}" \
        --protected-hosts "$(get_runtime_dependency_protected_hosts_arg)" \
        --blocked-subdomains "${BLOCKED_SUBDOMAINS[*]}"
}
