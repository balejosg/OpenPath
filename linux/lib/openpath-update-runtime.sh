#!/bin/bash

################################################################################
# openpath-update-runtime.sh - Runtime reconciliation and fail-open helpers
################################################################################

cleanup_system() {
    log "=== Activating fail-open mode ==="

    log "Disabling firewall..."
    log "Cleaning browser policies..."
    log "Configuring dnsmasq in passthrough mode..."
    log "Restarting dnsmasq..."
    log "Clearing connections..."

    enter_fail_open_mode "$PRIMARY_DNS"

    log "=== System in fail-open mode ==="
}

force_apply_changes() {
    log "Forcing change application..."
    flush_connections
    flush_dns_cache
    force_browser_close
    log "✓ Changes applied"
}

has_config_changed() {
    if [ ! -f "$DNSMASQ_CONF_HASH" ]; then
        return 0
    fi

    local new_hash
    new_hash=$(sha256sum "$DNSMASQ_CONF" 2>/dev/null | cut -d' ' -f1)
    local old_hash
    old_hash=$(cat "$DNSMASQ_CONF_HASH" 2>/dev/null)
    [ "$new_hash" != "$old_hash" ]
}

sync_runtime_browser_integrations() {
    require_openpath_request_setup_complete "runtime browser integration" || return 1
    generate_chromium_policies
    sync_firefox_managed_extension_policy "/usr/share/openpath/firefox-release" || true
}

resolve_captive_portal_preflight() {
    local captive_portal_state
    captive_portal_state=$(get_captive_portal_state)

    printf 'CAPTIVE_PORTAL_STATE=%s\n' "$captive_portal_state"
    case "$captive_portal_state" in
        PORTAL)
            printf 'CAPTIVE_PORTAL_ACTION=defer_for_authentication\n'
            ;;
        NO_NETWORK)
            printf 'CAPTIVE_PORTAL_ACTION=continue_without_network_confirmation\n'
            ;;
        *)
            printf 'CAPTIVE_PORTAL_ACTION=continue\n'
            ;;
    esac
}

apply_captive_portal_preflight() {
    local captive_portal_action="${1:-continue}"

    case "$captive_portal_action" in
        defer_for_authentication)
            log "⚠ Captive portal detected - disabling firewall for authentication"
            deactivate_firewall
            return 1
            ;;
        continue_without_network_confirmation)
            log "⚠ No connectivity to validate captive portal - keeping current enforcement"
            ;;
    esac

    return 0
}

resolve_whitelist_download_plan() {
    local download_succeeded="${1:-false}"
    local max_age_hours="${WHITELIST_MAX_AGE_HOURS:-24}"

    if [ "$download_succeeded" = true ]; then
        printf 'WHITELIST_DOWNLOAD_PLAN=continue\n'
        return 0
    fi

    if [ ! -f "$WHITELIST_FILE" ]; then
        printf 'WHITELIST_DOWNLOAD_PLAN=fail_open\n'
        return 0
    fi

    if [ "$max_age_hours" -le 0 ] 2>/dev/null; then
        printf 'WHITELIST_DOWNLOAD_PLAN=reuse_cached\n'
        return 0
    fi

    local file_age_seconds
    file_age_seconds=$(( $(date +%s) - $(stat -c %Y "$WHITELIST_FILE" 2>/dev/null || echo 0) ))
    local max_age_seconds=$(( max_age_hours * 3600 ))

    if [ "$file_age_seconds" -ge "$max_age_seconds" ]; then
        printf 'WHITELIST_DOWNLOAD_PLAN=fail_safe\n'
        printf 'WHITELIST_AGE_HOURS=%s\n' "$(( file_age_seconds / 3600 ))"
        printf 'WHITELIST_CONTROL_HOST=%s\n' "$(get_url_host "$WHITELIST_URL")"
        return 0
    fi

    printf 'WHITELIST_DOWNLOAD_PLAN=reuse_cached\n'
    printf 'WHITELIST_REMAINING_HOURS=%s\n' "$(( (max_age_seconds - file_age_seconds) / 3600 ))"
}

apply_whitelist_download_plan() {
    local whitelist_download_plan="${1:-continue}"
    local whitelist_age_hours="${2:-0}"
    local whitelist_remaining_hours="${3:-0}"
    local whitelist_control_host="${4:-}"

    case "$whitelist_download_plan" in
        continue)
            return 0
            ;;
        fail_open)
            log "⚠ Download failed - using existing whitelist"
            log "⚠ No whitelist available - fail-open mode"
            cleanup_system
            return 1
            ;;
        reuse_cached)
            log "⚠ Download failed - using existing whitelist"
            log "Whitelist age OK (expires in ~${whitelist_remaining_hours}h)"
            return 0
            ;;
        fail_safe)
            log "⚠ Download failed - using existing whitelist"
            log_warn "⚠ Whitelist expired: ${whitelist_age_hours}h old (max: ${WHITELIST_MAX_AGE_HOURS:-24}h)"
            log_warn "Entering fail-safe mode — blocking all DNS until fresh whitelist"

            local fail_safe_upstream_dns
            fail_safe_upstream_dns=$(select_usable_upstream_dns "${PRIMARY_DNS:-}")

            cat > "$DNSMASQ_CONF" << EOF
# FAIL-SAFE MODE — whitelist expired (${whitelist_age_hours}h old, max ${WHITELIST_MAX_AGE_HOURS:-24}h)
# Blocks all domains by default with local sinkhole addresses.
no-resolv
resolv-file=/run/dnsmasq/resolv.conf
listen-address=127.0.0.1
bind-interfaces
server=$fail_safe_upstream_dns
EOF

            write_dnsmasq_default_sinkhole_rules "$DNSMASQ_CONF" || return 1

            append_fail_safe_allow_domain "$whitelist_control_host"

            rm -f "$DNSMASQ_CONF_HASH" 2>/dev/null || true
            systemctl restart dnsmasq 2>/dev/null || true
            log "=== System in fail-safe mode (whitelist expired) ==="
            return 1
            ;;
    esac

    log_warn "Unknown whitelist download plan: $whitelist_download_plan"
    return 1
}
