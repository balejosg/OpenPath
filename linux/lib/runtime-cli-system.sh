#!/bin/bash
################################################################################
# runtime-cli-system.sh - Non-enrollment runtime commands for openpath CLI
################################################################################

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

    echo ""
    echo -e "${YELLOW}Whitelist:${NC}"
    if [ -f "$WHITELIST_FILE" ]; then
        local domains
        domains=$(grep -cv "^#\|^$" "$WHITELIST_FILE" 2>/dev/null || echo "0")
        echo "  Dominios: $domains"
    fi

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

cmd_update() {
    echo -e "${BLUE}Actualizando whitelist...${NC}"
    /usr/local/bin/openpath-update.sh
}

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

cmd_logs() {
    tail -f "$LOG_FILE"
}

cmd_log() {
    local lines="${1:-50}"
    if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: '$lines' is not a valid number of lines${NC}"
        echo "Uso: openpath log [N]"
        exit 1
    fi
    tail -n "$lines" "$LOG_FILE"
}

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

check_target_host() {
    local target="$1"
    target="${target%%/*}"
    printf '%s\n' "$target"
}

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

cmd_force() {
    echo -e "${BLUE}Forcing change application...${NC}"
    echo -e "${YELLOW}Browsers will be closed${NC}"
    echo ""

    flush_connections
    flush_dns_cache
    force_browser_close

    echo -e "${GREEN}✓ Cambios aplicados${NC}"
}

cmd_enable() {
    echo -e "${BLUE}Enabling system...${NC}"
    enable_services
    /usr/local/bin/openpath-update.sh

    force_browser_close
    flush_connections

    echo -e "${GREEN}✓ Sistema habilitado${NC}"
}

cmd_disable() {
    echo -e "${YELLOW}Disabling system...${NC}"

    systemctl stop openpath-dnsmasq.timer
    systemctl stop dnsmasq-watchdog.timer

    enter_disabled_mode "$(head -1 "$ORIGINAL_DNS_FILE" 2>/dev/null || echo "8.8.8.8")"

    echo -e "${GREEN}✓ Sistema deshabilitado${NC}"
}

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
