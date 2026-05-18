#!/bin/bash

################################################################################
# runtime-cli-commands.sh - Runtime command implementations
################################################################################

prepare_registration_connectivity() {
    local api_url="$1"
    local classroom_name="${2:-}"
    local classroom_id="${3:-}"

    if ! persist_openpath_classroom_runtime_config "$api_url" "$classroom_name" "$classroom_id"; then
        return 1
    fi

    # shellcheck disable=SC2034 # Shared state consumed by sourced DNS helpers.
    OPENPATH_PROTECTED_DOMAINS_READY=0

    if command -v systemctl >/dev/null 2>&1; then
        local resolv_conf="${OPENPATH_RESOLV_CONF:-/etc/resolv.conf}"
        local local_resolver_configured=false
        if [ -f "$resolv_conf" ] && awk '$1 == "nameserver" && $2 == "127.0.0.1" { found = 1 } END { exit found ? 0 : 1 }' "$resolv_conf" 2>/dev/null; then
            local_resolver_configured=true
        fi

        if systemctl is-active --quiet dnsmasq 2>/dev/null || [ "$local_resolver_configured" = true ]; then
            deactivate_firewall || true
            restore_dns || return 1
        fi
    fi

    return 0
}

activate_enrolled_connectivity() {
    if command -v systemctl >/dev/null 2>&1; then
        if ! validate_ip "${PRIMARY_DNS:-}"; then
            PRIMARY_DNS=$(detect_primary_dns)
            export PRIMARY_DNS
        fi

        if systemctl is-active --quiet dnsmasq 2>/dev/null; then
            systemctl stop dnsmasq 2>/dev/null || true
        fi

        if ! free_port_53 || ! configure_upstream_dns || ! configure_resolv_conf || ! create_dns_init_script; then
            return 1
        fi

        if ! generate_dnsmasq_config || ! restart_dnsmasq; then
            return 1
        fi

        systemctl daemon-reload 2>/dev/null || true
    fi

    return 0
}

cmd_enroll() {
    local classroom="" classroom_id="" api_url="" token="" enrollment_token="" machine_name=""
    local token_file=""
    local token_from_stdin=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --classroom)  classroom="$2"; shift 2 ;;
            --classroom-id) classroom_id="$2"; shift 2 ;;
            --api-url)    api_url="$2"; shift 2 ;;
            --token)      token="$2"; shift 2 ;;
            --token-file) token_file="$2"; shift 2 ;;
            --token-stdin) token_from_stdin=true; shift ;;
            --enrollment-token) enrollment_token="$2"; shift 2 ;;
            --machine-name) machine_name="$2"; shift 2 ;;
            *)            echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
        esac
    done

    [[ -z "$api_url" ]] && { echo -e "${RED}Error: --api-url is required${NC}"; exit 1; }
    api_url="${api_url%/}"

    local token_source_count=0
    [ -n "$token" ] && token_source_count=$((token_source_count + 1))
    [ -n "$token_file" ] && token_source_count=$((token_source_count + 1))
    [ "$token_from_stdin" = true ] && token_source_count=$((token_source_count + 1))

    if [[ -n "$enrollment_token" ]]; then
        if [ "$token_source_count" -gt 0 ]; then
            echo -e "${RED}Error: --enrollment-token cannot be combined with registration token options${NC}"
            exit 1
        fi
        [[ -z "$classroom_id" ]] && { echo -e "${RED}Error: --classroom-id is required with --enrollment-token${NC}"; exit 1; }
    else
        [[ -z "$classroom" ]] && { echo -e "${RED}Error: --classroom is required${NC}"; exit 1; }
        if [ "$token_source_count" -eq 0 ]; then
            echo -e "${RED}Error: requires --token, --token-file, or --token-stdin${NC}"
            exit 1
        fi
        if [ "$token_source_count" -gt 1 ]; then
            echo -e "${RED}Error: use only one token option (--token, --token-file o --token-stdin)${NC}"
            exit 1
        fi

        if [ -n "$token_file" ]; then
            if [ ! -r "$token_file" ]; then
                echo -e "${RED}Error: cannot read token file: $token_file${NC}"
                exit 1
            fi
            token=$(tr -d '\r\n' < "$token_file")
        fi

        if [ "$token_from_stdin" = true ]; then
            if [ -t 0 ]; then
                echo -e "${RED}Error: --token-stdin requires token on standard input${NC}"
                exit 1
            fi
            IFS= read -r token || true
            token="${token%$'\r'}"
        fi

        [[ -z "$token" ]] && { echo -e "${RED}Error: empty token${NC}"; exit 1; }
    fi

    if ! prepare_registration_connectivity "$api_url" "$classroom" "$classroom_id"; then
        echo -e "${RED}Error: could not prepare API connectivity${NC}"
        exit 1
    fi

    echo -e "${BLUE}Registering in classroom...${NC}"

    if [[ -z "$enrollment_token" ]]; then
        local validate_response
        validate_response=$(curl -fsS -X POST \
            -H "Content-Type: application/json" \
            -d "{\"token\":\"$token\"}" \
            "$api_url/api/setup/validate-token" 2>/dev/null) || {
            echo -e "${RED}Error: Could not validate token (API unreachable)${NC}"
            exit 1
        }

        local is_valid
        is_valid=$(echo "$validate_response" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  print("true" if d.get("valid") is True else "false")
except Exception:
  print("false")
')

        if [[ "$is_valid" != "true" ]]; then
            echo -e "${RED}Error: Invalid registration token${NC}"
            exit 1
        fi
        echo -e "  Token: ${GREEN}valid${NC}"
    fi

    local hostname version
    hostname=$(hostname)
    if [[ -n "$machine_name" ]]; then
        machine_name=$(normalize_machine_name_value "$machine_name")
    else
        machine_name="$hostname"
    fi

    [[ -z "$machine_name" ]] && { echo -e "${RED}Error: nombre de maquina invalid${NC}"; exit 1; }
    version=$(dpkg -s openpath-dnsmasq 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")

    local auth_token=""
    if [[ -n "$enrollment_token" ]]; then
        auth_token="$enrollment_token"
    else
        auth_token="$token"
    fi

    if register_machine "$machine_name" "$classroom" "$classroom_id" "$version" "$api_url" "$auth_token"; then
        if [[ -z "${TOKENIZED_URL:-}" ]] || ! is_tokenized_whitelist_url "$TOKENIZED_URL"; then
            echo -e "${RED}Error: the API did not return a valid tokenized whitelist URL${NC}"
            echo "  Response: ${REGISTER_RESPONSE:-no response}"
            exit 1
        fi

        local persisted_classroom="$classroom"
        local persisted_classroom_id="$classroom_id"
        if [[ -n "$REGISTERED_CLASSROOM_NAME" ]]; then
            persisted_classroom="$REGISTERED_CLASSROOM_NAME"
        fi
        if [[ -n "$REGISTERED_CLASSROOM_ID" ]]; then
            persisted_classroom_id="$REGISTERED_CLASSROOM_ID"
        fi

        if ! persist_openpath_enrollment_state "$api_url" "$persisted_classroom" "$persisted_classroom_id" "$TOKENIZED_URL"; then
            echo -e "${RED}Error: could not persist enrollment state${NC}"
            exit 1
        fi
        persist_machine_name "${REGISTERED_MACHINE_NAME:-$machine_name}" || true

        if ! activate_enrolled_connectivity; then
            echo -e "${RED}Error: could not activate DNS connectivity after registration${NC}"
            exit 1
        fi

        classroom="$persisted_classroom"
        classroom_id="$persisted_classroom_id"

        echo -e "  Registration: ${GREEN}successful${NC}"
        echo "  URL: $TOKENIZED_URL"
    else
        echo -e "${RED}Error registering machine${NC}"
        echo "  Response: $REGISTER_RESPONSE"
        exit 1
    fi

    reset_cached_whitelist_state

    echo -e "  Applying configuration..."
    systemctl restart openpath-sse-listener.service 2>/dev/null || true
    /usr/local/bin/openpath-update.sh || echo -e "${YELLOW}First update failed (the timer will retry)${NC}"
    /usr/local/bin/openpath-browser-setup.sh

    if [[ -n "$classroom" ]]; then
        echo -e "${GREEN}✓ Registered in classroom: $classroom${NC}"
    elif [[ -n "$classroom_id" ]]; then
        echo -e "${GREEN}✓ Registered in classroom ID: $classroom_id${NC}"
    else
        echo -e "${GREEN}✓ Registered in classroom${NC}"
    fi
}

reset_cached_whitelist_state() {
    rm -f \
        "$WHITELIST_FILE" \
        "${WHITELIST_FILE}.etag" \
        "$SYSTEM_DISABLED_FLAG" \
        "$DNSMASQ_CONF_HASH" \
        "$BROWSER_POLICIES_HASH"
}

cmd_setup() {
    local api_url=""
    local classroom=""
    local classroom_id=""
    local token_file=""
    local token_from_stdin=false
    local token_prompt=""
    local enrollment_token=""
    local machine_name=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --api-url)      api_url="$2"; shift 2 ;;
            --classroom)    classroom="$2"; shift 2 ;;
            --classroom-id) classroom_id="$2"; shift 2 ;;
            --token-file)   token_file="$2"; shift 2 ;;
            --token-stdin)  token_from_stdin=true; shift ;;
            --enrollment-token) enrollment_token="$2"; shift 2 ;;
            --machine-name) machine_name="$2"; shift 2 ;;
            --help)
                echo "Usage: openpath setup [--api-url URL] [--classroom CLASSROOM] [--token-file FILE|--token-stdin]"
                echo "   or: openpath setup --api-url URL --classroom-id ID --enrollment-token TOKEN [--machine-name NAME]"
                echo "If you pass no arguments, interactive mode starts."
                return 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                return 1
                ;;
        esac
    done

    if [[ -z "$api_url" ]]; then
        if ! read_prompt_value api_url "API URL (example: https://openpath.school.edu): "; then
            echo -e "${RED}Error: no interactive input available to request API URL${NC}"
            echo "  Use --api-url or run in an interactive terminal"
            return 1
        fi
    fi
    api_url="${api_url%/}"
    [[ -z "$api_url" ]] && { echo -e "${RED}Error: empty API URL${NC}"; return 1; }

    if [[ -z "$classroom" ]] && [[ -z "$enrollment_token" ]]; then
        if ! read_prompt_value classroom "Classroom name (example: Room-101): "; then
            echo -e "${RED}Error: no interactive input available to request classroom${NC}"
            echo "  Use --classroom or run in an interactive terminal"
            return 1
        fi
    fi

    if [[ -n "$enrollment_token" ]]; then
        if [[ -z "$classroom_id" ]]; then
            echo -e "${RED}Error: --classroom-id is required with --enrollment-token${NC}"
            return 1
        fi
        if [ -n "$token_file" ] || [ "$token_from_stdin" = true ]; then
            echo -e "${RED}Error: --enrollment-token cannot be combined with --token-file/--token-stdin${NC}"
            return 1
        fi

        if [ -n "$machine_name" ]; then
            "$0" enroll --api-url "$api_url" --classroom-id "$classroom_id" --enrollment-token "$enrollment_token" --machine-name "$machine_name"
            return $?
        fi
        "$0" enroll --api-url "$api_url" --classroom-id "$classroom_id" --enrollment-token "$enrollment_token"
        return $?
    fi

    [[ -z "$classroom" ]] && { echo -e "${RED}Error: empty classroom${NC}"; return 1; }

    local token_source_count=0
    [ -n "$token_file" ] && token_source_count=$((token_source_count + 1))
    [ "$token_from_stdin" = true ] && token_source_count=$((token_source_count + 1))

    if [ "$token_source_count" -gt 1 ]; then
        echo -e "${RED}Error: use only one token option (--token-file o --token-stdin)${NC}"
        return 1
    fi

    if [ "$token_source_count" -eq 0 ]; then
        if ! read_prompt_secret token_prompt "Registration token: "; then
            echo -e "${RED}Error: no interactive terminal; use --token-file or --token-stdin${NC}"
            return 1
        fi

        if [[ -z "$token_prompt" ]]; then
            echo -e "${RED}Error: empty token${NC}"
            return 1
        fi

        local token_tmp
        token_tmp=$(mktemp)
        chmod 600 "$token_tmp"
        printf '%s' "$token_prompt" > "$token_tmp"

        if [ -n "$machine_name" ]; then
            "$0" enroll --classroom "$classroom" --api-url "$api_url" --token-file "$token_tmp" --machine-name "$machine_name"
        else
            "$0" enroll --classroom "$classroom" --api-url "$api_url" --token-file "$token_tmp"
        fi
        local enroll_status=$?
        rm -f "$token_tmp"
        return $enroll_status
    fi

    if [ -n "$token_file" ]; then
        if [ -n "$machine_name" ]; then
            "$0" enroll --classroom "$classroom" --api-url "$api_url" --token-file "$token_file" --machine-name "$machine_name"
            return $?
        fi
        "$0" enroll --classroom "$classroom" --api-url "$api_url" --token-file "$token_file"
        return $?
    fi

    if [ -n "$machine_name" ]; then
        "$0" enroll --classroom "$classroom" --api-url "$api_url" --token-stdin --machine-name "$machine_name"
        return $?
    fi

    "$0" enroll --classroom "$classroom" --api-url "$api_url" --token-stdin
}

cmd_rotate_token() {
    if [ ! -f "$ETC_CONFIG_DIR/api-url.conf" ]; then
        echo -e "${RED}Error: Classroom mode is not configured${NC}"
        echo "  Only machines registered in a classroom can rotate their token"
        exit 1
    fi

    local api_url
    api_url=$(cat "$ETC_CONFIG_DIR/api-url.conf")
    local hostname
    hostname=$(get_registered_machine_name)
    local auth_token="" auth_source=""
    resolve_rotation_auth_with_compat || true
    auth_token="$ROTATION_AUTH_TOKEN"
    auth_source="$ROTATION_AUTH_SOURCE"

    if [ -z "$auth_token" ]; then
        echo -e "${RED}Error: Could not find a credential to rotate the token${NC}"
        echo "  Expected a token derivable from $WHITELIST_URL_CONF"
        echo "  Fallback legacy: $(rotation_legacy_secret_path)"
        exit 1
    fi

    echo -e "${BLUE}Rotating download token...${NC}"
    echo "  Authentication: $auth_source"

    local response
    response=$(timeout 30 curl -s -X POST \
        -H "Authorization: Bearer $auth_token" \
        -H "Content-Type: application/json" \
        "$api_url/api/machines/$hostname/rotate-download-token" 2>/dev/null)

    if echo "$response" | grep -q '"success":true'; then
        local new_url
        new_url=$(echo "$response" | grep -o '"whitelistUrl":"[^"]*"' | sed 's/"whitelistUrl":"//;s/"$//')
        if [ -n "$new_url" ] && is_tokenized_whitelist_url "$new_url" && persist_openpath_whitelist_url "$new_url"; then
            echo -e "${GREEN}✓ Token rotated successfully${NC}"
            echo "  New URL saved in $WHITELIST_URL_CONF"
        else
            echo -e "${RED}✗ Rotation succeeded but no new URL was received${NC}"
            exit 1
        fi
    else
        echo -e "${RED}✗ Error rotating token${NC}"
        echo "  Response: $response"
        exit 1
    fi
}

resolve_rotation_auth_token() {
    resolve_rotation_machine_token
}
