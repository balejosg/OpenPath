#!/bin/bash
################################################################################
# runtime-cli-system.sh - Non-enrollment runtime commands for openpath CLI
################################################################################

# Print a multi-section status summary: active services, DNS resolution state,
# bypass-block states, whitelist domain count, enrollment info, and update history.
cmd_status() {
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Sistema dnsmasq URL Whitelist v$VERSION${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    echo -e "${YELLOW}Servicios:${NC}"
    for svc in dnsmasq openpath-dnsmasq.timer openpath-agent-update.timer dnsmasq-watchdog.timer captive-portal-detector openpath-sse-listener; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  $svc: ${GREEN}● active${NC}"
        else
            echo -e "  $svc: ${RED}● inactive${NC}"
        fi
    done

    echo ""
    echo -e "${YELLOW}DNS:${NC}"
    local status_probe_domain
    local status_probe_result
    status_probe_domain=$(select_allowed_dns_probe_domain)
    status_probe_result=$(resolve_local_dns_probe "$status_probe_domain")
    if dns_probe_result_is_public "$status_probe_result"; then
        echo -e "  Resolution: ${GREEN}● working${NC}"
    else
        echo -e "  Resolution: ${RED}● failing${NC}"
    fi

    if [ -f /run/dnsmasq/resolv.conf ]; then
        local upstream
        upstream=$(grep "^nameserver" /run/dnsmasq/resolv.conf | head -1 | awk '{print $2}')
        echo "  DNS upstream: $upstream"
    fi

    if declare -F check_doh_block_status >/dev/null 2>&1; then
        echo ""
        echo -e "${YELLOW}Bypass blocks:${NC}"
        local status_block_label status_block_state
        for status_block_label in DoH VPN Tor; do
            case "$status_block_label" in
                DoH) status_block_state=$(check_doh_block_status 2>/dev/null) || true ;;
                VPN) status_block_state=$(check_vpn_block_status 2>/dev/null) || true ;;
                Tor) status_block_state=$(check_tor_block_status 2>/dev/null) || true ;;
            esac
            case "$status_block_state" in
                active) echo -e "  $status_block_label block: ${GREEN}● active${NC}" ;;
                disabled) echo -e "  $status_block_label block: ${YELLOW}● disabled${NC}" ;;
                *) echo -e "  $status_block_label block: ${RED}● inactive${NC}" ;;
            esac
        done
    fi

    echo ""
    echo -e "${YELLOW}Whitelist:${NC}"
    if [ -f "$WHITELIST_FILE" ]; then
        local domains
        domains=$(grep -cv "^#\|^$" "$WHITELIST_FILE" 2>/dev/null || echo "0")
        echo "  Dominios: $domains"
    fi

    if [ -f "$WHITELIST_FILE" ] && declare -F parse_whitelist_sections >/dev/null 2>&1; then
        parse_whitelist_sections "$WHITELIST_FILE" >/dev/null 2>&1 || true
    fi
    local runtime_dependency_active="0"
    if declare -F get_runtime_dependency_domains >/dev/null 2>&1; then
        runtime_dependency_active=$(get_runtime_dependency_domains --prune 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')
    fi
    local runtime_dependency_pending="0"
    if [ -d "${RUNTIME_DEPENDENCY_QUEUE_DIR:-}" ]; then
        runtime_dependency_pending=$(find "$RUNTIME_DEPENDENCY_QUEUE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d '[:space:]')
    fi
    echo "  Runtime dependencies: ${runtime_dependency_active:-0} active"
    echo "  Runtime dependency queue: ${runtime_dependency_pending:-0} pending"

    local api_url=""
    local classroom=""
    local classroom_id=""
    local whitelist_url=""
    api_url=$(read_single_line_file "$ETC_CONFIG_DIR/api-url.conf" || true)
    classroom=$(read_single_line_file "$ETC_CONFIG_DIR/classroom.conf" || true)
    classroom_id=$(read_single_line_file "$ETC_CONFIG_DIR/classroom-id.conf" || true)
    whitelist_url=$(read_single_line_file "$WHITELIST_URL_CONF" || true)

    echo ""
    echo -e "${YELLOW}Aula:${NC}"

    local enrolled="NO"
    if [ -n "$api_url" ] && [ -n "$whitelist_url" ] && is_tokenized_whitelist_url "$whitelist_url"; then
        if [ -n "$classroom" ] || [ -n "$classroom_id" ]; then
            enrolled="YES"
        fi
    fi

    if [ "$enrolled" = "YES" ]; then
        echo -e "  Enrolled: ${GREEN}✓ YES${NC}"
    else
        echo -e "  Enrolled: ${RED}✗ NO${NC}"
    fi

    if is_openpath_request_setup_complete; then
        echo -e "  Requests: ${GREEN}✓ configured${NC}"
    else
        echo -e "  Requests: ${RED}✗ not configured${NC}"
        echo "  Falta: $(describe_openpath_request_setup_missing)"
    fi

    if [ -n "$classroom" ]; then
        echo "  Aula: $classroom"
    elif [ -n "$classroom_id" ]; then
        echo "  Aula ID: $classroom_id"
    else
        echo "  Aula: no configurada"
    fi

    if [ -n "$api_url" ]; then
        echo "  API URL: $api_url"
    else
        echo "  API URL: no configurada"
    fi

    local agent_update_state_file="$VAR_STATE_DIR/agent-update-state.json"
    echo ""
    echo -e "${YELLOW}Agent Update:${NC}"
    if [ -f "$agent_update_state_file" ]; then
        local update_status=""
        local update_check=""
        local update_success=""
        update_status=$(grep -oP '"status":\s*"\K[^"]+' "$agent_update_state_file" 2>/dev/null | head -1 || true)
        update_check=$(grep -oP '"lastCheckAt":\s*"\K[^"]+' "$agent_update_state_file" 2>/dev/null | head -1 || true)
        update_success=$(grep -oP '"lastSuccessAt":\s*"\K[^"]+' "$agent_update_state_file" 2>/dev/null | head -1 || true)
        echo "  Estado: ${update_status:-desconocido}"
        echo "  Ultimo check: ${update_check:-nunca}"
        echo "  Ultimo exito: ${update_success:-nunca}"
    else
        echo "  Estado: sin historial"
    fi

    if [ -n "$whitelist_url" ]; then
        if is_tokenized_whitelist_url "$whitelist_url"; then
            echo "  Whitelist URL: tokenizada"
        else
            echo "  Whitelist URL: no tokenizada"
        fi
    else
        echo "  Whitelist URL: no configurada"
    fi

    if systemctl is-active --quiet openpath-sse-listener.service 2>/dev/null; then
        echo -e "  SSE listener: ${GREEN}● active${NC}"
    else
        echo -e "  SSE listener: ${YELLOW}● inactive${NC}"
    fi

    echo ""
}

# Trigger an immediate whitelist refresh by running the background update script.
cmd_update() {
    echo -e "${BLUE}Actualizando whitelist...${NC}"
    /usr/local/bin/openpath-update.sh
}

# Resolve one whitelisted and one blocked domain against the local DNS and
# report whether each result matches the expected outcome.
cmd_test() {
    echo -e "${BLUE}Probando DNS...${NC}"
    echo ""

    local allowed_domain
    local allowed_result
    allowed_domain=$(select_allowed_dns_probe_domain)
    allowed_result=$(resolve_local_dns_probe "$allowed_domain")

    echo -n "  Permitido ($allowed_domain): "
    if dns_probe_result_is_public "$allowed_result"; then
        echo -e "${GREEN}✓${NC} ($(printf '%s\n' "$allowed_result" | head -1))"
    else
        echo -e "${RED}✗${NC}"
    fi

    local blocked_domain
    local blocked_result
    blocked_domain=$(select_blocked_dns_probe_domain)
    blocked_result=$(resolve_local_dns_probe "$blocked_domain")

    echo -n "  Bloqueado ($blocked_domain): "
    if dns_probe_result_is_blocked "$blocked_result"; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC} ($(printf '%s\n' "$blocked_result" | head -1))"
    fi
    echo ""
}

# Stream the agent log file in real time (equivalent to following the tail).
cmd_logs() {
    tail -f "$LOG_FILE"
}

# Print the last N lines of the agent log (default 50); reject non-numeric arguments.
cmd_log() {
    local lines="${1:-50}"
    if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: '$lines' is not a valid number of lines${NC}"
        echo "Uso: openpath log [N]"
        exit 1
    fi
    tail -n "$lines" "$LOG_FILE"
}

# List domains from the whitelist file, optionally filtered by a substring.
cmd_domains() {
    local filter="${1:-}"

    if [ ! -f "$WHITELIST_FILE" ]; then
        echo -e "${RED}Whitelist no encontrado${NC}"
        exit 1
    fi

    if [ -n "$filter" ]; then
        grep -i "$filter" "$WHITELIST_FILE" | grep -v "^#" | grep -v "^$" | sort
    else
        grep -v "^#" "$WHITELIST_FILE" | grep -v "^$" | sort
    fi
}

# Strip scheme, query string, fragment, and trailing slashes from a URL or
# domain, then lowercase and collapse repeated slashes to a canonical form.
normalize_check_target() {
    local target="$1"

    target="${target#http://}"
    target="${target#https://}"
    target="${target%%\?*}"
    target="${target%%#*}"
    target="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | sed 's/[[:space:]]//g; s#//*#/#g; s#/$##')"
    target="${target#.}"
    printf '%s\n' "$target"
}

# Extract the host portion from a normalized target by dropping everything
# after the first slash.
check_target_host() {
    local target="$1"
    target="${target%%/*}"
    printf '%s\n' "$target"
}

# Return 0 if any element in the remaining arguments normalizes to the same
# value as the first argument, 1 otherwise.
array_contains_exact() {
    local needle="$1"
    shift
    local candidate=""

    for candidate in "$@"; do
        if [ "$(normalize_check_target "$candidate")" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}

# Look up a domain or URL in the whitelist, blocked-subdomain, and blocked-path
# sets, then perform a live DNS resolution and print the combined result.
cmd_check() {
    local domain="$1"
    local normalized_target=""
    local normalized_host=""
    local in_whitelist=false
    local blocked_subdomain=false
    local blocked_path=false
    local result=""
    [ -z "$domain" ] && { echo "Usage: openpath check <domain>"; exit 1; }

    echo -e "${BLUE}Checking: $domain${NC}"
    echo ""

    normalized_target="$(normalize_check_target "$domain")"
    normalized_host="$(check_target_host "$normalized_target")"

    if [ -f "$WHITELIST_FILE" ]; then
        parse_whitelist_sections "$WHITELIST_FILE" >/dev/null 2>&1 || true
    fi

    if array_contains_exact "$normalized_host" "${WHITELIST_DOMAINS[@]}"; then
        in_whitelist=true
    fi
    if array_contains_exact "$normalized_host" "${BLOCKED_SUBDOMAINS[@]}"; then
        blocked_subdomain=true
    fi
    if array_contains_exact "$normalized_target" "${BLOCKED_PATHS[@]}"; then
        blocked_path=true
    fi

    if [ "$in_whitelist" = true ]; then
        echo -e "  In whitelist: ${GREEN}✓ YES${NC}"
    else
        echo -e "  In whitelist: ${YELLOW}✗ NO${NC}"
    fi
    if [ "$blocked_subdomain" = true ]; then
        echo -e "  Blocked by subdomain: ${GREEN}✓ YES${NC}"
    else
        echo -e "  Blocked by subdomain: ${YELLOW}✗ NO${NC}"
    fi
    if [ "$blocked_path" = true ]; then
        echo -e "  Blocked by path: ${GREEN}✓ YES${NC}"
    else
        echo -e "  Blocked by path: ${YELLOW}✗ NO${NC}"
    fi

    echo -n "  Resolves: "
    result=$(resolve_local_dns_probe "$normalized_host")
    if dns_probe_result_is_public "$result"; then
        echo -e "${GREEN}✓${NC} → $(printf '%s\n' "$result" | head -1)"
    else
        echo -e "${RED}✗${NC}"
    fi
    echo ""
}

# Run a comprehensive health check across DNS resolution, firewall rules,
# bypass-block states, services, whitelist freshness, and browser integrations;
# exit non-zero if any critical check fails.
cmd_health() {
    local failed=0
    local remote_disabled=false

    if [ -f "$SYSTEM_DISABLED_FLAG" ]; then
        remote_disabled=true
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  OpenPath Health Check v$VERSION${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    local whitelisted_domain
    local blocked_domain
    whitelisted_domain=$(select_allowed_dns_probe_domain)
    blocked_domain=$(select_blocked_dns_probe_domain)

    echo -e "${YELLOW}DNS Resolution:${NC}"
    local whitelisted_result
    whitelisted_result=$(resolve_local_dns_probe "$whitelisted_domain")
    if dns_probe_result_is_public "$whitelisted_result"; then
        echo -e "  Whitelisted domain ($whitelisted_domain): ${GREEN}✓ resolves${NC}"
    else
        echo -e "  Whitelisted domain ($whitelisted_domain): ${RED}✗ FAILED${NC}"
        failed=1
    fi

    if [ "$remote_disabled" = true ]; then
        echo -e "  Blocked domain ($blocked_domain): ${YELLOW}⚠ bypassed (system disabled remotely)${NC}"
    else
        local blocked_result
        blocked_result=$(resolve_local_dns_probe "$blocked_domain")
        if dns_probe_result_is_blocked "$blocked_result"; then
            echo -e "  Blocked domain ($blocked_domain): ${GREEN}✓ blocked${NC}"
        else
            echo -e "  Blocked domain ($blocked_domain): ${RED}✗ NOT BLOCKED${NC}"
            failed=1
        fi
    fi
    echo ""

    echo -e "${YELLOW}System State:${NC}"
    if [ "$remote_disabled" = true ]; then
        echo -e "  Enforcement: ${YELLOW}⚠ fail-open (system disabled remotely)${NC}"
    else
        echo -e "  Enforcement: ${GREEN}✓ enforced${NC}"
    fi
    echo ""

    echo -e "${YELLOW}Firewall:${NC}"
    if [ "$remote_disabled" = true ]; then
        echo -e "  DNS blocking rules: ${YELLOW}⚠ bypassed (system disabled remotely)${NC}"
        echo -e "  Loopback rule: ${YELLOW}⚠ bypassed (system disabled remotely)${NC}"
    else
        if check_firewall_status >/dev/null 2>&1; then
            echo -e "  DNS blocking rules: ${GREEN}✓ active${NC}"
        else
            echo -e "  DNS blocking rules: ${RED}✗ MISSING${NC}"
            failed=1
        fi

        if has_firewall_loopback_rule >/dev/null 2>&1; then
            echo -e "  Loopback rule: ${GREEN}✓ present${NC}"
        else
            echo -e "  Loopback rule: ${YELLOW}⚠ not found${NC}"
        fi

        if verify_firewall_rules >/dev/null 2>&1; then
            echo -e "  Critical firewall rules: ${GREEN}✓ complete${NC}"
        else
            echo -e "  Critical firewall rules: ${RED}✗ incomplete${NC}"
            failed=1
        fi

        local doh_block_state vpn_block_state tor_block_state
        doh_block_state=$(check_doh_block_status 2>/dev/null) || true
        vpn_block_state=$(check_vpn_block_status 2>/dev/null) || true
        tor_block_state=$(check_tor_block_status 2>/dev/null) || true

        case "$doh_block_state" in
            active) echo -e "  DoH bypass block: ${GREEN}✓ active${NC}" ;;
            disabled) echo -e "  DoH bypass block: ${YELLOW}⚠ disabled by configuration${NC}" ;;
            *)
                echo -e "  DoH bypass block: ${RED}✗ MISSING${NC}"
                failed=1
                ;;
        esac

        case "$vpn_block_state" in
            active) echo -e "  VPN bypass block: ${GREEN}✓ active${NC}" ;;
            disabled) echo -e "  VPN bypass block: ${YELLOW}⚠ disabled by configuration${NC}" ;;
            *)
                echo -e "  VPN bypass block: ${RED}✗ MISSING${NC}"
                failed=1
                ;;
        esac

        case "$tor_block_state" in
            active) echo -e "  Tor bypass block: ${GREEN}✓ active${NC}" ;;
            disabled) echo -e "  Tor bypass block: ${YELLOW}⚠ disabled by configuration${NC}" ;;
            *)
                echo -e "  Tor bypass block: ${RED}✗ MISSING${NC}"
                failed=1
                ;;
        esac
    fi
    echo ""

    echo -e "${YELLOW}Services:${NC}"
    for svc in dnsmasq openpath-dnsmasq.timer dnsmasq-watchdog.timer captive-portal-detector openpath-sse-listener; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  $svc: ${GREEN}✓ running${NC}"
        else
            echo -e "  $svc: ${RED}✗ NOT running${NC}"
            failed=1
        fi
    done
    echo ""

    echo -e "${YELLOW}Whitelist:${NC}"
    if [ -f "$WHITELIST_FILE" ]; then
        local age
        age=$(($(date +%s) - $(stat -c %Y "$WHITELIST_FILE")))
        local domains
        domains=$(grep -cv "^#\|^$" "$WHITELIST_FILE" 2>/dev/null || echo "0")
        echo "  Domains: $domains"
        if [ "$age" -lt 600 ]; then
            echo -e "  Freshness: ${GREEN}✓ fresh (${age}s old)${NC}"
        else
            echo -e "  Freshness: ${YELLOW}⚠ stale (${age}s old)${NC}"
        fi
    else
        echo -e "  File: ${RED}✗ MISSING${NC}"
        failed=1
    fi
    echo ""

    echo -e "${YELLOW}Browser Integrations:${NC}"
    local request_setup_complete=false
    local browser_etc_dir="${ETC_CONFIG_DIR:-/etc/openpath}"
    local browser_api_url=""
    local browser_whitelist_url=""
    local browser_classroom=""
    local browser_classroom_id=""

    browser_api_url="$(tr -d '\r\n' < "$browser_etc_dir/api-url.conf" 2>/dev/null || true)"
    browser_whitelist_url="$(tr -d '\r\n' < "$browser_etc_dir/whitelist-url.conf" 2>/dev/null || true)"
    browser_classroom="$(tr -d '\r\n' < "$browser_etc_dir/classroom.conf" 2>/dev/null || true)"
    browser_classroom_id="$(tr -d '\r\n' < "$browser_etc_dir/classroom-id.conf" 2>/dev/null || true)"
    if [[ "$browser_api_url" =~ ^https?://[^[:space:]]+$ ]] \
        && [[ "$browser_whitelist_url" =~ /w/[^/]+/whitelist\.txt($|[?#].*) ]] \
        && { [ -n "$browser_classroom" ] || [ -n "$browser_classroom_id" ]; }; then
        request_setup_complete=true
    fi

    if [ "$request_setup_complete" = true ]; then
        local firefox_ready_file="${FIREFOX_EXTENSION_READY_FILE:-$VAR_STATE_DIR/firefox-extension-ready}"
        local firefox_native_manifest="${FIREFOX_NATIVE_HOST_DIR:-/usr/lib/mozilla/native-messaging-hosts}/${OPENPATH_FIREFOX_NATIVE_HOST_FILENAME:-whitelist_native_host.json}"
        local firefox_native_script="${OPENPATH_NATIVE_HOST_INSTALL_DIR:-/usr/local/lib/openpath}/${OPENPATH_NATIVE_HOST_SCRIPT_NAME:-openpath-native-host.py}"

        if [ -f "$firefox_ready_file" ] \
            && grep -q "extension_id=openpath-block-monitor@openpath" "$firefox_ready_file" 2>/dev/null \
            && awk -F= '
                $1 == "target_count" { target = $2 + 0 }
                $1 == "registered_count" { registered = $2 + 0 }
                END { exit !(target > 0 && registered == target) }
            ' "$firefox_ready_file" \
            && ! grep -Eq '\|disabled\||extensions\.json-disabled|active=false|userDisabled=true|signedState=-1' "$firefox_ready_file" 2>/dev/null; then
            echo -e "  Firefox extension: ${GREEN}✓ registered${NC}"
        elif [ -f "$firefox_ready_file" ] \
            && grep -Eq '\|disabled\||extensions\.json-disabled|active=false|userDisabled=true|signedState=-1' "$firefox_ready_file" 2>/dev/null; then
            echo -e "  Firefox extension: ${RED}✗ disabled or unsigned${NC}"
            grep -E 'profile=.*\|disabled\||extensions\.json-disabled|active=false|userDisabled=true|signedState=-1' "$firefox_ready_file" 2>/dev/null | sed 's/^/    /' || true
            failed=1
        elif [ "${OPENPATH_ALLOW_DEFERRED_FIREFOX_REGISTRATION:-0}" = "1" ]; then
            echo -e "  Firefox extension: ${YELLOW}⚠ registration deferred${NC}"
        else
            echo -e "  Firefox extension: ${RED}✗ not registered${NC}"
            failed=1
        fi
        if [ -r "$firefox_native_manifest" ] && [ -x "$firefox_native_script" ]; then
            echo -e "  Firefox native host: ${GREEN}✓ ready${NC}"
        else
            echo -e "  Firefox native host: ${RED}✗ not ready${NC}"
            failed=1
        fi
    fi
    if find /etc/chromium/policies/managed/openpath.json /etc/chromium-browser/policies/managed/openpath.json /etc/google-chrome/policies/managed/openpath.json -maxdepth 0 2>/dev/null | head -1 | grep -q .; then
        echo -e "  Chromium policies: ${GREEN}✓ present${NC}"
    else
        echo -e "  Chromium policies: ${YELLOW}⚠ not found${NC}"
    fi
    echo ""

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    if [ "$failed" -eq 0 ]; then
        echo -e "  Overall status: ${GREEN}✓ HEALTHY${NC}"
    else
        echo -e "  Overall status: ${RED}✗ ISSUES DETECTED${NC}"
    fi
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

    return $failed
}

# Flush active connections, clear the local DNS cache, and close open browser
# windows so pending whitelist changes take effect immediately.
cmd_force() {
    echo -e "${BLUE}Forcing change application...${NC}"
    echo -e "${YELLOW}Browsers will be closed${NC}"
    echo ""

    flush_connections
    flush_dns_cache
    force_browser_close

    echo -e "${GREEN}✓ Cambios aplicados${NC}"
}

# Re-enable the system after a disable: start services, trigger a whitelist
# update, flush connections, and close browsers to restore enforcement.
cmd_enable() {
    echo -e "${BLUE}Enabling system...${NC}"
    enable_services
    /usr/local/bin/openpath-update.sh

    force_browser_close
    flush_connections

    echo -e "${GREEN}✓ Sistema habilitado${NC}"
}

# Stop the update and watchdog timers and switch the system into disabled mode,
# restoring normal DNS forwarding without the whitelist sinkhole.
cmd_disable() {
    echo -e "${YELLOW}Disabling system...${NC}"

    systemctl stop openpath-dnsmasq.timer
    systemctl stop dnsmasq-watchdog.timer

    enter_disabled_mode "$(resolve_persisted_upstream_dns)"

    echo -e "${GREEN}✓ Sistema deshabilitado${NC}"
}

# Restart the DNS daemon and associated timers, wait briefly for the daemon to
# become active, then print a fresh status summary.
cmd_restart() {
    echo -e "${BLUE}Restarting services...${NC}"

    systemctl restart dnsmasq
    systemctl restart openpath-dnsmasq.timer
    systemctl restart dnsmasq-watchdog.timer
    systemctl restart captive-portal-detector.service 2>/dev/null || true
    systemctl restart openpath-sse-listener.service 2>/dev/null || true

    for _ in $(seq 1 5); do
        if systemctl is-active --quiet dnsmasq; then
            break
        fi
        sleep 1
    done

    cmd_status
}

# Print a structured browser-readiness diagnostic: request-setup facts,
# Firefox extension and native-host registration state, policy file presence,
# and detected browser binaries.
cmd_doctor_browser() {
    echo -e "${BLUE}OpenPath Browser Doctor${NC}"
    echo ""

    local api_url=""
    local whitelist_url=""
    local classroom=""
    local classroom_id=""
    api_url="$(tr -d '\r\n' < "${ETC_CONFIG_DIR}/api-url.conf" 2>/dev/null || true)"
    whitelist_url="$(tr -d '\r\n' < "${WHITELIST_URL_CONF:-$ETC_CONFIG_DIR/whitelist-url.conf}" 2>/dev/null || true)"
    classroom="$(tr -d '\r\n' < "${ETC_CONFIG_DIR}/classroom.conf" 2>/dev/null || true)"
    classroom_id="$(tr -d '\r\n' < "${ETC_CONFIG_DIR}/classroom-id.conf" 2>/dev/null || true)"

    local request_setup_ready="false"
    if [[ "$api_url" =~ ^https?://[^[:space:]]+$ ]] \
        && [[ "$whitelist_url" =~ /w/[^/]+/whitelist\.txt($|[?#].*) ]] \
        && { [ -n "$classroom" ] || [ -n "$classroom_id" ]; }; then
        request_setup_ready="true"
    fi

    echo -e "${YELLOW}Request Setup:${NC}"
    if [ "$request_setup_ready" = "true" ]; then
        echo -e "  fact.request_setup: ${GREEN}ready${NC}"
    else
        echo -e "  fact.request_setup: ${RED}missing${NC}"
        [ -z "$api_url" ] && echo "  failure_reason: api_url_missing"
        [ -z "$whitelist_url" ] && echo "  failure_reason: whitelist_url_missing"
        { [ -z "$classroom" ] && [ -z "$classroom_id" ]; } && echo "  failure_reason: classroom_missing"
    fi

    echo ""
    echo -e "${YELLOW}Firefox Extension:${NC}"

    local firefox_ready_file="${FIREFOX_EXTENSION_READY_FILE:-$VAR_STATE_DIR/firefox-extension-ready}"
    local firefox_native_manifest="${FIREFOX_NATIVE_HOST_DIR:-/usr/lib/mozilla/native-messaging-hosts}/${OPENPATH_FIREFOX_NATIVE_HOST_FILENAME:-whitelist_native_host.json}"
    local firefox_native_script="${OPENPATH_NATIVE_HOST_INSTALL_DIR:-/usr/local/lib/openpath}/${OPENPATH_NATIVE_HOST_SCRIPT_NAME:-openpath-native-host.py}"
    local firefox_policies="${FIREFOX_POLICIES:-/etc/firefox/policies/policies.json}"

    if [ -f "$firefox_ready_file" ]; then
        echo -e "  fact.firefox_registration: ${GREEN}ready${NC}"
        echo "  Firefox ready file: $firefox_ready_file"
    else
        echo -e "  fact.firefox_registration: ${RED}missing${NC}"
        echo "  failure_reason: firefox_registration_missing"
    fi

    if [ -r "$firefox_native_manifest" ] && [ -x "$firefox_native_script" ]; then
        echo -e "  fact.firefox_native_host: ${GREEN}ready${NC}"
    else
        echo -e "  fact.firefox_native_host: ${RED}missing${NC}"
        echo "  failure_reason: firefox_native_host_missing"
    fi
    echo "  Native host manifest: $firefox_native_manifest"
    echo "  Native host script: $firefox_native_script"

    echo ""
    echo -e "${YELLOW}Firefox Policy:${NC}"
    if [ -f "$firefox_policies" ]; then
        echo -e "  Policy file: ${GREEN}present${NC} ($firefox_policies)"
        local ext_id="${FIREFOX_EXTENSION_ID:-${FIREFOX_MANAGED_EXTENSION_ID:-openpath-block-monitor@openpath}}"
        if grep -q "ExtensionSettings" "$firefox_policies" 2>/dev/null \
                && grep -q "$ext_id" "$firefox_policies" 2>/dev/null; then
            echo -e "  Extension policy entry: ${GREEN}present${NC}"
        else
            echo -e "  Extension policy entry: ${RED}missing${NC}"
        fi
    else
        echo -e "  Policy file: ${RED}missing${NC} ($firefox_policies)"
    fi

    echo ""
    echo -e "${YELLOW}Browser Inventory:${NC}"
    local firefox_bin
    firefox_bin="$(command -v firefox 2>/dev/null || true)"
    if [ -n "$firefox_bin" ]; then
        echo -e "  Firefox: ${GREEN}found${NC} ($firefox_bin)"
    else
        echo -e "  Firefox: ${YELLOW}not found in PATH${NC}"
    fi

    local chromium_bin
    chromium_bin="$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || true)"
    if [ -n "$chromium_bin" ]; then
        echo -e "  Chromium: ${GREEN}found${NC} ($chromium_bin)"
    else
        echo -e "  Chromium: ${YELLOW}not found in PATH${NC}"
    fi

    if find /etc/chromium/policies/managed/openpath.json \
            /etc/chromium-browser/policies/managed/openpath.json \
            /etc/google-chrome/policies/managed/openpath.json \
            -maxdepth 0 2>/dev/null | head -1 | grep -q .; then
        echo -e "  Chromium policies: ${GREEN}present${NC}"
    else
        echo -e "  Chromium policies: ${YELLOW}not found${NC}"
    fi

    echo ""
    local overall_ready="true"
    [ "$request_setup_ready" != "true" ] && overall_ready="false"
    [ ! -r "$firefox_native_manifest" ] && overall_ready="false"
    [ ! -x "$firefox_native_script" ] && overall_ready="false"

    if [ "$overall_ready" = "true" ]; then
        echo -e "  Browser request readiness: ${GREEN}ready${NC}"
    else
        echo -e "  Browser request readiness: ${RED}not ready${NC}"
    fi
}

# Route to a focused diagnostics sub-command identified by the first argument.
# Prints usage and exits non-zero for unknown or missing targets.
cmd_doctor() {
    local doctor_target="${1:-}"

    case "${doctor_target}" in
        browser)
            cmd_doctor_browser
            ;;
        "")
            echo -e "${RED}Usage: openpath doctor <target>${NC}"
            echo "  Supported targets: browser"
            exit 1
            ;;
        *)
            echo -e "${RED}Unknown doctor target: $doctor_target${NC}"
            echo "  Supported targets: browser"
            exit 1
            ;;
    esac
}

# Print the full command reference with a one-line description for each subcommand.
cmd_help() {
    echo -e "${BLUE}openpath - OpenPath DNS system management v$VERSION${NC}"
    echo ""
    echo "Usage: openpath <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status          System status"
    echo "  update          Force update"
    echo "  test            Test DNS resolution"
    echo "  logs            Show logs in real time"
    echo "  log [N]         Show last N log lines"
    echo "  domains [texto] List domains (optional filter)"
    echo "  check <domain>  Check whether a domain is allowed"
    echo "  health          Check system health"
    echo "  doctor <target> Print focused diagnostics (e.g. browser)"
    echo "  force           Force change application"
    echo "  enable          Enable system"
    echo "  disable         Disable system"
    echo "  restart         Restart services"
    echo "  setup           Setup assistant (Classroom mode only)"
    echo "  rotate-token    Rotate download token (Classroom mode)"
    echo "  enroll          Register machine in a classroom"
    echo "  self-update     Update agent to the latest version"
    echo "  help            Show this help"
    echo ""
}
