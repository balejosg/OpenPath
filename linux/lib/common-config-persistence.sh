#!/bin/bash

################################################################################
# common-config-persistence.sh - Shared config persistence helpers
################################################################################

get_registered_machine_name() {
    if [ -n "${OPENPATH_MACHINE_NAME:-}" ]; then
        printf '%s\n' "$OPENPATH_MACHINE_NAME"
        return 0
    fi

    if [ -n "${OPENPATH_MACHINE_ID:-}" ]; then
        printf '%s\n' "$OPENPATH_MACHINE_ID"
        return 0
    fi

    if [ -r "$MACHINE_NAME_CONF" ]; then
        local saved_name
        saved_name=$(tr -d '\r\n' < "$MACHINE_NAME_CONF" 2>/dev/null || true)
        if [ -n "$saved_name" ]; then
            printf '%s\n' "$saved_name"
            return 0
        fi
    fi

    hostname
}

read_single_line_file() {
    local file="$1"

    if [ -r "$file" ]; then
        tr -d '\r\n' < "$file"
        return 0
    fi

    if [ "$EUID" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n test -r "$file" 2>/dev/null; then
        sudo -n cat "$file" 2>/dev/null | tr -d '\r\n'
        return 0
    fi

    return 1
}

is_http_url() {
    local value="${1:-}"
    [[ "$value" =~ ^https?://[^[:space:]]+$ ]]
}

is_tokenized_whitelist_url() {
    local url="$1"
    [[ "$url" =~ /w/[^/]+/whitelist\.txt($|[?#].*) ]]
}

is_openpath_request_setup_complete() {
    local api_url=""
    local whitelist_url=""
    local classroom=""
    local classroom_id=""

    api_url=$(read_single_line_file "$ETC_CONFIG_DIR/api-url.conf" || true)
    whitelist_url=$(read_single_line_file "$WHITELIST_URL_CONF" || true)
    classroom=$(read_single_line_file "$ETC_CONFIG_DIR/classroom.conf" || true)
    classroom_id=$(read_single_line_file "$ETC_CONFIG_DIR/classroom-id.conf" || true)

    is_http_url "$api_url" || return 1
    is_tokenized_whitelist_url "$whitelist_url" || return 1
    [ -n "$classroom" ] || [ -n "$classroom_id" ] || return 1
}

describe_openpath_request_setup_missing() {
    local missing_items=()
    local api_url=""
    local whitelist_url=""
    local classroom=""
    local classroom_id=""

    api_url=$(read_single_line_file "$ETC_CONFIG_DIR/api-url.conf" || true)
    whitelist_url=$(read_single_line_file "$WHITELIST_URL_CONF" || true)
    classroom=$(read_single_line_file "$ETC_CONFIG_DIR/classroom.conf" || true)
    classroom_id=$(read_single_line_file "$ETC_CONFIG_DIR/classroom-id.conf" || true)

    if [ -z "$api_url" ]; then
        missing_items+=("api-url.conf")
    elif ! is_http_url "$api_url"; then
        missing_items+=("valid api-url.conf")
    fi

    if [ -z "$whitelist_url" ]; then
        missing_items+=("whitelist-url.conf")
    elif ! is_tokenized_whitelist_url "$whitelist_url"; then
        missing_items+=("tokenized whitelist-url.conf")
    fi

    [ -n "$classroom" ] || [ -n "$classroom_id" ] || missing_items+=("classroom.conf or classroom-id.conf")

    if [ "${#missing_items[@]}" -eq 0 ]; then
        printf '%s\n' "none"
        return 0
    fi

    local IFS=", "
    printf '%s\n' "${missing_items[*]}"
}

require_openpath_request_setup_complete() {
    local context="${1:-browser request setup}"

    if is_openpath_request_setup_complete; then
        return 0
    fi

    log_error "OpenPath request setup is incomplete for ${context}: $(describe_openpath_request_setup_missing)"
    return 1
}

has_openpath_managed_browser_integration() {
    local managed_policies="${FIREFOX_POLICIES:-/usr/lib/firefox-esr/distribution/policies.json}"
    local native_host=""
    local native_host_dir=""

    if [ -f "$managed_policies" ] && grep -q "openpath-block-monitor@openpath" "$managed_policies" 2>/dev/null; then
        return 0
    fi

    if declare -F get_native_host_install_dir >/dev/null 2>&1; then
        native_host_dir=$(get_native_host_install_dir 2>/dev/null || true)
    fi
    [ -n "$native_host_dir" ] || native_host_dir="/usr/lib/mozilla/native-messaging-hosts"
    native_host="$native_host_dir/whitelist_native_host.json"

    [ -f "$native_host" ]
}

should_require_openpath_request_setup() {
    if is_openpath_request_setup_complete; then
        return 0
    fi

    has_openpath_managed_browser_integration
}

extract_machine_token_from_whitelist_url() {
    local whitelist_url="${1:-}"
    if [ -z "$whitelist_url" ]; then
        return 1
    fi

    local machine_token
    machine_token=$(printf '%s\n' "$whitelist_url" | sed -n 's#.*\/w\/\([^/][^/]*\)\/.*#\1#p')
    if [ -z "$machine_token" ]; then
        return 1
    fi

    printf '%s\n' "$machine_token"
}

get_machine_token_from_whitelist_url_file() {
    if [ ! -r "$WHITELIST_URL_CONF" ]; then
        return 1
    fi

    local whitelist_url
    whitelist_url=$(tr -d '\r\n' < "$WHITELIST_URL_CONF" 2>/dev/null || true)
    if [ -z "$whitelist_url" ]; then
        return 1
    fi

    extract_machine_token_from_whitelist_url "$whitelist_url"
}

normalize_machine_name_value() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

compute_scoped_machine_name() {
    local raw_hostname="$1"
    local classroom_id="$2"
    local base hash suffix max_base_length

    base=$(normalize_machine_name_value "$raw_hostname")
    [ -z "$base" ] && base="machine"

    hash=$(printf '%s' "$classroom_id" | sha256sum | awk '{print $1}' | cut -c1-8)
    suffix="-$hash"
    max_base_length=$((63 - ${#suffix}))
    [ "$max_base_length" -lt 1 ] && max_base_length=1
    base="${base:0:max_base_length}"
    base="${base%-}"
    [ -z "$base" ] && base="machine"

    printf '%s\n' "${base}${suffix}"
}

persist_machine_name() {
    local machine_name="$1"
    [ -z "$machine_name" ] && return 1
    machine_name=$(normalize_machine_name_value "$machine_name")
    [ -z "$machine_name" ] && return 1

    mkdir -p "$ETC_CONFIG_DIR"
    printf '%s' "$machine_name" > "$MACHINE_NAME_CONF"
    chown root:root "$MACHINE_NAME_CONF" 2>/dev/null || true
    chmod 640 "$MACHINE_NAME_CONF" 2>/dev/null || true
}

prepare_openpath_config_dir() {
    mkdir -p "$ETC_CONFIG_DIR"
    chown root:root "$ETC_CONFIG_DIR" 2>/dev/null || true
    chmod 755 "$ETC_CONFIG_DIR" 2>/dev/null || true
}

write_openpath_config_file() {
    local target_file="$1"
    local value="$2"
    local mode="${3:-640}"
    local temp_file

    prepare_openpath_config_dir

    temp_file=$(mktemp "${target_file}.tmp.XXXXXX") || return 1
    if ! printf '%s' "$value" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    chown root:root "$temp_file" 2>/dev/null || true
    chmod "$mode" "$temp_file" 2>/dev/null || true
    mv -f "$temp_file" "$target_file"
}

persist_openpath_whitelist_url() {
    local whitelist_url="$1"

    if ! is_http_url "$whitelist_url"; then
        return 1
    fi

    write_openpath_config_file "$WHITELIST_URL_CONF" "$whitelist_url" 644
}

persist_openpath_health_api_config() {
    local health_api_url="${1:-}"
    local health_api_secret="${2:-}"

    if [ -n "$health_api_url" ] && ! is_http_url "$health_api_url"; then
        return 1
    fi

    if [ -n "$health_api_url" ] && ! write_openpath_config_file "$HEALTH_API_URL_CONF" "$health_api_url" 640; then
        return 1
    fi

    if [ -n "$health_api_secret" ] && ! write_openpath_config_file "$HEALTH_API_SECRET_CONF" "$health_api_secret" 600; then
        return 1
    fi
}

persist_openpath_classroom_runtime_config() {
    local api_url="$1"
    local classroom_name="${2:-}"
    local classroom_id="${3:-}"

    if ! is_http_url "$api_url"; then
        return 1
    fi

    if ! write_openpath_config_file "$ETC_CONFIG_DIR/api-url.conf" "$api_url" 644; then
        return 1
    fi

    if [ -n "$classroom_name" ] && ! write_openpath_config_file "$ETC_CONFIG_DIR/classroom.conf" "$classroom_name" 640; then
        return 1
    fi

    if [ -n "$classroom_id" ] && ! write_openpath_config_file "$ETC_CONFIG_DIR/classroom-id.conf" "$classroom_id" 640; then
        return 1
    fi
}

persist_openpath_enrollment_state() {
    local api_url="$1"
    local classroom_name="${2:-}"
    local classroom_id="${3:-}"
    local whitelist_url="$4"

    if ! is_http_url "$api_url"; then
        return 1
    fi

    if ! is_tokenized_whitelist_url "$whitelist_url"; then
        return 1
    fi

    if ! persist_openpath_classroom_runtime_config "$api_url" "$classroom_name" "$classroom_id"; then
        return 1
    fi

    persist_openpath_whitelist_url "$whitelist_url"
}
