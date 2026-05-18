#!/bin/bash

################################################################################
# common-locking.sh - Shared lock and runtime reconciliation helpers
################################################################################

# Acquire the shared OpenPath lock on file descriptor 200.
# Intended for scripts that hold the lock for their entire runtime.
# Returns 0 on success, 1 on failure.
openpath_lock_acquire() {
    local timeout_sec="${1:-30}"

    exec 200>"$OPENPATH_LOCK_FILE"
    if ! timeout "$timeout_sec" flock -x 200; then
        return 1
    fi
    return 0
}

# Remove the lock file on exit (best-effort).
openpath_lock_cleanup() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
}

# Run a command under the shared OpenPath lock (short-lived).
# Uses file descriptor 201 to avoid interfering with scripts holding the lock
# on fd 200.
with_openpath_lock() {
    local timeout_sec="${OPENPATH_LOCK_TIMEOUT_SEC:-30}"

    exec 201>"$OPENPATH_LOCK_FILE"
    if ! timeout "$timeout_sec" flock -x 201; then
        exec 201>&- 2>/dev/null || true
        return 1
    fi

    "$@"
    local rc=$?

    flock -u 201 2>/dev/null || true
    exec 201>&- 2>/dev/null || true
    return "$rc"
}

write_passthrough_dnsmasq_config() {
    local upstream_dns="$1"

    mkdir -p "$(dirname "$DNSMASQ_CONF")"
    cat > "$DNSMASQ_CONF" << EOF
# MODO PASSTHROUGH - Sin restricciones
no-resolv
resolv-file=/run/dnsmasq/resolv.conf
listen-address=127.0.0.1
bind-interfaces
server=$upstream_dns
EOF
}

apply_passthrough_system_mode() {
    local upstream_dns="$1"
    local clear_hashes="${2:-false}"
    local close_browsers="${3:-false}"

    deactivate_firewall
    cleanup_browser_policies
    write_passthrough_dnsmasq_config "$upstream_dns"

    if [ "$clear_hashes" = true ]; then
        rm -f "$DNSMASQ_CONF_HASH" 2>/dev/null || true
        rm -f "$BROWSER_POLICIES_HASH" 2>/dev/null || true
    fi

    systemctl restart dnsmasq 2>/dev/null || true
    flush_connections

    if [ "$close_browsers" = true ]; then
        force_browser_close
    fi
}

enter_fail_open_mode() {
    local upstream_dns="$1"
    apply_passthrough_system_mode "$upstream_dns" true false
}

enter_disabled_mode() {
    local upstream_dns="$1"
    apply_passthrough_system_mode "$upstream_dns" false true
}

build_runtime_reconciliation_plan() {
    local dns_config_changed="${1:-false}"
    local dns_healthy="${2:-false}"
    local firewall_was_inactive="${3:-false}"
    local policies_changed="${4:-false}"
    local firewall_action="none"
    local flush_connections_required="false"
    local flush_reason=""
    local activation_context="none"

    if [ "$dns_healthy" = true ]; then
        if [ "$dns_config_changed" = true ]; then
            firewall_action="activate"
            activation_context="apply"
        elif [ "$firewall_was_inactive" = true ]; then
            firewall_action="activate"
            activation_context="reactivate"
        fi
    else
        firewall_action="deactivate"
    fi

    if [ "$policies_changed" = true ]; then
        flush_connections_required="true"
        flush_reason="policy_change"
    elif [ "$firewall_was_inactive" = true ]; then
        flush_connections_required="true"
        flush_reason="system_reactivated"
    fi

    printf 'FIREWALL_ACTION=%s\n' "$firewall_action"
    printf 'FLUSH_CONNECTIONS=%s\n' "$flush_connections_required"
    printf 'FLUSH_REASON=%s\n' "$flush_reason"
    printf 'ACTIVATION_CONTEXT=%s\n' "$activation_context"
}

apply_runtime_reconciliation_plan() {
    local firewall_action="${1:-none}"
    local flush_connections_required="${2:-false}"
    local flush_reason="${3:-}"
    local activation_context="${4:-none}"

    case "$firewall_action" in
        activate)
            if ! activate_firewall; then
                if [ "$activation_context" = "reactivate" ]; then
                    log "⚠ Failed to reactivate restrictive firewall - keeping permissive mode"
                else
                    log "⚠ Failed to activate restrictive firewall - keeping permissive mode"
                fi
                deactivate_firewall
            fi
            ;;
        deactivate)
            deactivate_firewall
            ;;
    esac

    if [ "$flush_connections_required" = true ]; then
        case "$flush_reason" in
            policy_change)
                log "Policy change detected (without closing browsers)"
                ;;
            system_reactivated)
                log "Sistema reactivado (sin cierre de navegadores)"
                ;;
        esac
        flush_connections
    fi
}
