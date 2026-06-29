#!/bin/bash

################################################################################
# browser-request-readiness.sh - Browser request readiness facts
################################################################################

FIREFOX_EXTENSION_ID="${FIREFOX_EXTENSION_ID:-${FIREFOX_MANAGED_EXTENSION_ID:-openpath-block-monitor@openpath}}"
# The Firefox application GUID must be initialized without nesting literal curly
# braces inside a parameter expansion default: bash parses the first } it finds
# as the end of the ${...}, appending an extra } to any pre-exported value.
# Use an explicit if-guard so the literal is only assigned when the variable is
# empty, which is safe regardless of the caller-provided export state.
if [ -z "${FIREFOX_APP_ID:-}" ]; then
    FIREFOX_APP_ID="{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
fi
FIREFOX_RELEASE_SOURCE="${FIREFOX_RELEASE_SOURCE:-$INSTALL_DIR/firefox-release}"

openpath_browser_readiness_has_tokenized_whitelist_url() {
    local url="$1"

    [[ "$url" =~ /w/[^/]+/whitelist\.txt($|[?#].*) ]]
}

openpath_browser_request_setup_ready() {
    local api_url_conf="${OPENPATH_API_URL_CONF:-$ETC_CONFIG_DIR/api-url.conf}"
    local whitelist_url_conf="${WHITELIST_URL_CONF:-$ETC_CONFIG_DIR/whitelist-url.conf}"
    local api_url=""
    local whitelist_url=""
    local classroom=""
    local classroom_id=""

    if declare -F is_openpath_request_setup_complete >/dev/null 2>&1; then
        is_openpath_request_setup_complete
        return $?
    fi

    api_url="$(read_single_line_file "$api_url_conf" 2>/dev/null || true)"
    whitelist_url="$(read_single_line_file "$whitelist_url_conf" 2>/dev/null || true)"
    classroom="$(read_single_line_file "$ETC_CONFIG_DIR/classroom.conf" 2>/dev/null || true)"
    classroom_id="$(read_single_line_file "$ETC_CONFIG_DIR/classroom-id.conf" 2>/dev/null || true)"

    [[ "$api_url" =~ ^https?://[^[:space:]]+$ ]] || return 1
    openpath_browser_readiness_has_tokenized_whitelist_url "$whitelist_url" || return 1
    [ -n "$classroom" ] || [ -n "$classroom_id" ]
}

verify_firefox_policy_contract() {
    if [ ! -f "$FIREFOX_POLICIES" ]; then
        log_error "Firefox policies file not found: $FIREFOX_POLICIES"
        return 1
    fi

    if ! grep -q "ExtensionSettings" "$FIREFOX_POLICIES" 2>/dev/null; then
        log_error "Firefox policies missing ExtensionSettings"
        return 1
    fi

    if ! grep -q "$FIREFOX_EXTENSION_ID" "$FIREFOX_POLICIES" 2>/dev/null; then
        log_error "Firefox policies missing managed extension id: $FIREFOX_EXTENSION_ID"
        return 1
    fi

    return 0
}

read_browser_setup_api_base_url() {
    local api_url_conf="${OPENPATH_API_URL_CONF:-$ETC_CONFIG_DIR/api-url.conf}"
    local api_url=""

    api_url="$(read_single_line_file "$api_url_conf" 2>/dev/null || true)"
    api_url="${api_url%/}"
    if [ -z "$api_url" ]; then
        return 1
    fi

    printf '%s\n' "$api_url"
}

read_firefox_policy_install_url() {
    if declare -F read_firefox_managed_extension_install_url >/dev/null 2>&1; then
        read_firefox_managed_extension_install_url "$FIREFOX_POLICIES" "$FIREFOX_EXTENSION_ID"
        return $?
    fi

    run_browser_json_helper \
        read-firefox-managed-install-url \
        --policies-file "$FIREFOX_POLICIES" \
        --extension-id "$FIREFOX_EXTENSION_ID"
}

read_firefox_policy_local_install_entry() {
    run_browser_json_helper \
        read-firefox-local-install-entry \
        --policies-file "$FIREFOX_POLICIES" \
        --extension-id "$FIREFOX_EXTENSION_ID"
}

verify_firefox_managed_api_payload() {
    local api_base_url=""
    local install_url=""
    local expected_install_url=""

    api_base_url="$(read_browser_setup_api_base_url)" || return 1
    install_url="$(read_firefox_policy_install_url 2>/dev/null || true)"
    expected_install_url="${api_base_url}/api/extensions/firefox/openpath.xpi"

    [ "$install_url" = "$expected_install_url" ]
}

verify_firefox_local_policy_payload() {
    local install_entry=""

    install_entry="$(read_firefox_policy_local_install_entry 2>/dev/null || true)"
    if [ -z "$install_entry" ]; then
        return 1
    fi

    [ -d "$install_entry" ] && [ -f "$install_entry/manifest.json" ]
}

# Resolve the Firefox unpacked-extension root. Defined here (guarded) so this lib
# is self-contained: the install path sources it via browser.sh WITHOUT
# openpath-browser-setup.sh -- the only other place this helper is defined -- so
# the readiness check would otherwise call an undefined function, resolve an empty
# root, and report a correctly-staged extension as a missing payload. The guard
# preserves a caller-provided definition (openpath-browser-setup.sh and test mocks).
if ! declare -F resolve_firefox_extensions_root_dir >/dev/null 2>&1; then
    resolve_firefox_extensions_root_dir() {
        if declare -F get_firefox_extensions_root >/dev/null 2>&1; then
            get_firefox_extensions_root
            return 0
        fi
        printf '%s\n' "${FIREFOX_EXTENSIONS_ROOT:-/usr/share/mozilla/extensions}"
    }
fi

verify_firefox_extension_payload() {
    local extensions_root=""
    local unpacked_extension_dir=""

    extensions_root="$(resolve_firefox_extensions_root_dir)"
    unpacked_extension_dir="$extensions_root/$FIREFOX_APP_ID/$FIREFOX_EXTENSION_ID"

    if [ -d "$unpacked_extension_dir" ] && [ -f "$unpacked_extension_dir/manifest.json" ]; then
        return 0
    fi

    if [ -f "$FIREFOX_RELEASE_SOURCE/metadata.json" ]; then
        return 0
    fi

    if verify_firefox_local_policy_payload; then
        return 0
    fi

    if verify_firefox_managed_api_payload; then
        return 0
    fi

    log_error "Firefox extension payload not available after setup"
    return 1
}

verify_firefox_native_host_ready() {
    local native_manifest_dir=""
    local native_script_dir=""
    local native_manifest_path=""
    local native_script_path=""

    if declare -F get_firefox_native_host_dir >/dev/null 2>&1; then
        native_manifest_dir="$(get_firefox_native_host_dir 2>/dev/null || true)"
    else
        native_manifest_dir="${FIREFOX_NATIVE_HOST_DIR:-/usr/lib/mozilla/native-messaging-hosts}"
    fi

    if declare -F get_native_host_install_dir >/dev/null 2>&1; then
        native_script_dir="$(get_native_host_install_dir 2>/dev/null || true)"
    else
        native_script_dir="${OPENPATH_NATIVE_HOST_INSTALL_DIR:-/usr/local/lib/openpath}"
    fi
    native_manifest_path="$native_manifest_dir/${OPENPATH_FIREFOX_NATIVE_HOST_FILENAME:-whitelist_native_host.json}"
    native_script_path="$native_script_dir/${OPENPATH_NATIVE_HOST_SCRIPT_NAME:-openpath-native-host.py}"

    if [ -z "$native_manifest_dir" ] || [ -z "$native_script_dir" ]; then
        log_error "Firefox native host readiness paths could not be resolved"
        return 1
    fi

    if [ ! -r "$native_manifest_path" ]; then
        log_error "Firefox native host manifest not readable: $native_manifest_path"
        return 1
    fi

    if [ ! -x "$native_script_path" ]; then
        log_error "Firefox native host script not executable: $native_script_path"
        return 1
    fi

    return 0
}

openpath_browser_readiness_emit() {
    local ready="$1"
    shift

    printf 'platform=linux\n'
    printf 'ready=%s\n' "$ready"
    printf '%s\n' "$@"
}

collect_openpath_browser_request_readiness() {
    local ready=true
    local facts=()
    local failure_reasons=()

    if openpath_browser_request_setup_ready; then
        facts+=("fact.request_setup=ready")
    else
        ready=false
        facts+=("fact.request_setup=missing")
        failure_reasons+=("failure_reason=request_setup_incomplete")
    fi

    if verify_firefox_extension_payload; then
        facts+=("fact.firefox_payload=ready")
    else
        ready=false
        facts+=("fact.firefox_payload=missing")
        failure_reasons+=("failure_reason=firefox_payload_missing")
    fi

    if verify_firefox_extension_registered; then
        facts+=("fact.firefox_registration=ready")
    else
        ready=false
        facts+=("fact.firefox_registration=missing")
        failure_reasons+=("failure_reason=firefox_registration_missing")
    fi

    if verify_firefox_native_host_ready; then
        facts+=("fact.firefox_native_host=ready")
    else
        ready=false
        facts+=("fact.firefox_native_host=missing")
        failure_reasons+=("failure_reason=firefox_native_host_missing")
    fi

    openpath_browser_readiness_emit "$ready" "${facts[@]}" "${failure_reasons[@]}"
    [ "$ready" = true ]
}

require_openpath_browser_request_readiness() {
    if collect_openpath_browser_request_readiness; then
        return 0
    fi

    log_error "Browser request readiness failed"
    return 1
}
