#!/bin/bash

FIREFOX_MANAGED_EXTENSION_ID="${FIREFOX_MANAGED_EXTENSION_ID:-openpath-block-monitor@openpath}"

get_browser_json_helper() {
    if [ -n "${OPENPATH_BROWSER_JSON_HELPER:-}" ]; then
        printf '%s\n' "$OPENPATH_BROWSER_JSON_HELPER"
        return 0
    fi

    local helper_path
    helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/libexec/browser-json.py"

    if [ ! -f "$helper_path" ]; then
        echo "⚠ Browser JSON helper not found: $helper_path" >&2
        return 1
    fi

    printf '%s\n' "$helper_path"
}

run_browser_json_helper() {
    local helper_path
    helper_path="$(get_browser_json_helper)" || return 1
    python3 "$helper_path" "$@"
}

read_firefox_managed_extension_install_url() {
    local policies_file="$1"
    local ext_id="$2"

    run_browser_json_helper \
        read-firefox-managed-install-url \
        --policies-file "$policies_file" \
        --extension-id "$ext_id"
}

ensure_firefox_policies_dir() {
    mkdir -p "$(dirname "$FIREFOX_POLICIES")"
    sync_firefox_distribution_policy_paths
}

firefox_distribution_policy_paths() {
    local firefox_dir=""
    local candidate=""
    local seen=""

    if declare -F detect_firefox_dir >/dev/null 2>&1; then
        firefox_dir="$(detect_firefox_dir 2>/dev/null || true)"
        if [ -n "$firefox_dir" ]; then
            printf '%s\n' "$firefox_dir/distribution/policies.json"
            seen=":$firefox_dir:"
        fi
    fi

    for candidate in /usr/lib/firefox-esr /usr/lib/firefox /opt/firefox; do
        if [ -d "$candidate" ] && [[ "$seen" != *":$candidate:"* ]]; then
            printf '%s\n' "$candidate/distribution/policies.json"
            seen="${seen}:$candidate:"
        fi
    done
}

sync_firefox_distribution_policy_paths() {
    local policy_path=""
    local canonical_real=""
    local policy_real=""

    canonical_real="$(readlink -f "$FIREFOX_POLICIES" 2>/dev/null || true)"

    while IFS= read -r policy_path; do
        [ -n "$policy_path" ] || continue
        [ "$policy_path" != "$FIREFOX_POLICIES" ] || continue

        mkdir -p "$(dirname "$policy_path")" 2>/dev/null || continue

        policy_real="$(readlink -f "$policy_path" 2>/dev/null || true)"
        if [ -n "$canonical_real" ] && [ "$policy_real" = "$canonical_real" ]; then
            continue
        fi

        if [ -L "$policy_path" ] || [ ! -e "$policy_path" ]; then
            rm -f "$policy_path" 2>/dev/null || true
            ln -s "$FIREFOX_POLICIES" "$policy_path" 2>/dev/null || {
                [ -f "$FIREFOX_POLICIES" ] && cp "$FIREFOX_POLICIES" "$policy_path" 2>/dev/null || true
            }
        elif [ -f "$FIREFOX_POLICIES" ]; then
            cp "$FIREFOX_POLICIES" "$policy_path" 2>/dev/null || true
        fi
    done < <(firefox_distribution_policy_paths)
}

mutate_firefox_policies() {
    local action="$1"
    local ext_id="${2:-}"
    local install_entry="${3:-}"
    local install_url="${4:-}"
    local status=0

    ensure_firefox_policies_dir

    # browser-json.py mutate-firefox-policies
    OPENPATH_BLOCKED_PATHS="$(printf '%s\n' "${BLOCKED_PATHS[@]}")" \
    run_browser_json_helper \
        mutate-firefox-policies \
        --policies-file "$FIREFOX_POLICIES" \
        --action "$action" \
        --extension-id "$ext_id" \
        --install-entry "$install_entry" \
        --install-url "$install_url"
    status=$?

    if [ "$status" -eq 0 ]; then
        sync_firefox_distribution_policy_paths
    fi

    return "$status"
}

get_policies_hash() {
    local hash=""
    if [ -f "$FIREFOX_POLICIES" ]; then
        hash="${hash}$(sha256sum "$FIREFOX_POLICIES" 2>/dev/null | cut -d' ' -f1)"
    fi
    if [ -z "$hash" ]; then
        hash="$(printf '' | sha256sum | cut -d' ' -f1)"
    fi
    echo "$hash"
}

cleanup_browser_policies() {
    log "Cleaning up browser policies..."

    local dirs=(
        "$CHROMIUM_POLICIES_BASE"
        "/etc/chromium-browser/policies/managed"
        "/etc/opt/chrome/policies/managed"
    )

    for dir in "${dirs[@]}"; do
        rm -f "$dir/openpath.json" 2>/dev/null || true
        rm -f "$dir/url-whitelist.json" 2>/dev/null || true
        rm -f "$dir/search-engines.json" 2>/dev/null || true
    done

    log "✓ Browser policies cleaned"
}

get_firefox_extensions_root() {
    echo "${FIREFOX_EXTENSIONS_ROOT:-/usr/share/mozilla/extensions}"
}

convert_openpath_file_url() {
    local install_target="$1"

    python3 << PYEOF
from pathlib import Path

print(Path("$install_target").resolve().as_uri())
PYEOF
}

add_extension_to_policies() {
    local ext_id="$1"
    local install_target="$2"
    local install_url="${3:-}"
    local install_entry="$install_target"

    if [ -z "$install_url" ]; then
        if [[ "$install_target" == *://* ]]; then
            install_url="$install_target"
        else
            install_url="$(convert_openpath_file_url "$install_target")"
        fi
    else
        install_entry="$install_url"
    fi

    mutate_firefox_policies "ensure_managed_extension" "$ext_id" "$install_entry" "$install_url"
    log "✓ Extension added to policies.json"
}
