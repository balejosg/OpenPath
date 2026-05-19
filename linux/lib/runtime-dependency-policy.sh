#!/bin/bash

normalize_runtime_dependency_host() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:].]+//; s/[[:space:].]+$//')"
    [ -n "$value" ] || return 1
    [ "${#value}" -ge 4 ] || return 1
    [ "${#value}" -le 253 ] || return 1
    [[ "$value" != *.local ]] || return 1
    [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || return 1
    printf '%s\n' "$value"
}

runtime_dependency_whitelist_covers_host() {
    local host="$1"
    local domain
    for domain in "${WHITELIST_DOMAINS[@]}"; do
        domain="$(normalize_runtime_dependency_host "$domain" 2>/dev/null || true)"
        [ -n "$domain" ] || continue
        [ "$host" = "$domain" ] && return 0
        [[ "$host" == *".$domain" ]] && return 0
    done
    return 1
}

runtime_dependency_blocked_subdomain_matches() {
    local host="$1"
    local blocked
    for blocked in "${BLOCKED_SUBDOMAINS[@]}"; do
        blocked="$(normalize_runtime_dependency_host "$blocked" 2>/dev/null || true)"
        [ -n "$blocked" ] || continue
        [ "$host" = "$blocked" ] && return 0
        [[ "$host" == *".$blocked" ]] && return 0
    done
    return 1
}

runtime_dependency_is_protected_host() {
    local host="$1"
    local protected
    while IFS= read -r protected; do
        protected="$(normalize_runtime_dependency_host "$protected" 2>/dev/null || true)"
        [ -n "$protected" ] || continue
        [ "$host" = "$protected" ] && return 0
        [[ "$host" == *".$protected" ]] && return 0
    done < <(get_openpath_protected_domains; printf '%s\n' detectportal.firefox.com connectivity-check.ubuntu.com captive.apple.com clients3.google.com time.google.com)
    return 1
}

validate_runtime_dependency_candidate() {
    local anchor_host
    local dependency_host
    local request_type

    anchor_host="$(normalize_runtime_dependency_host "${1:-}" 2>/dev/null || true)"
    dependency_host="$(normalize_runtime_dependency_host "${2:-}" 2>/dev/null || true)"
    request_type="$(printf '%s' "${3:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')"

    if [ -z "$anchor_host" ] || [ -z "$dependency_host" ] || [ -z "$request_type" ]; then
        printf 'success=false\nerror=Invalid runtime dependency payload\n'
        return 1
    fi
    if [ "$request_type" = "main_frame" ]; then
        printf 'success=false\nerror=main_frame dependencies are not supported\n'
        return 1
    fi
    if [ "$anchor_host" = "$dependency_host" ]; then
        printf 'success=true\nskipped=true\nreason=same-host\nanchorHost=%s\ndependencyHost=%s\nrequestType=%s\n' "$anchor_host" "$dependency_host" "$request_type"
        return 2
    fi
    if ! runtime_dependency_whitelist_covers_host "$anchor_host"; then
        printf 'success=false\nerror=Anchor host is not locally whitelisted\nanchorHost=%s\ndependencyHost=%s\nrequestType=%s\n' "$anchor_host" "$dependency_host" "$request_type"
        return 1
    fi
    if runtime_dependency_is_protected_host "$anchor_host" || runtime_dependency_is_protected_host "$dependency_host"; then
        printf 'success=false\nerror=Protected hosts are not accepted as runtime dependencies\nanchorHost=%s\ndependencyHost=%s\nrequestType=%s\n' "$anchor_host" "$dependency_host" "$request_type"
        return 1
    fi
    if runtime_dependency_blocked_subdomain_matches "$dependency_host"; then
        printf 'success=false\nerror=Blocked hosts are not accepted as runtime dependencies\nanchorHost=%s\ndependencyHost=%s\nrequestType=%s\n' "$anchor_host" "$dependency_host" "$request_type"
        return 1
    fi

    printf 'success=true\nanchorHost=%s\ndependencyHost=%s\nrequestType=%s\n' "$anchor_host" "$dependency_host" "$request_type"
}
