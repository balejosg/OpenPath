#!/bin/bash
set -o pipefail

# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

################################################################################
# openpath-update.sh - Whitelist update script
# Part of the OpenPath DNS system
################################################################################

INSTALL_DIR="/usr/local/lib/openpath"
source "$INSTALL_DIR/lib/common.sh"

trap openpath_lock_cleanup EXIT

if ! openpath_lock_acquire 30; then
    echo "Could not acquire lock after 30s - another process may be stuck"
    exit 1
fi

if ! load_libraries; then
    echo "ERROR: Could not load required OpenPath libraries"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$INSTALL_DIR/lib/openpath-update-whitelist.sh" ]; then
    # shellcheck source=/usr/local/lib/openpath/lib/openpath-update-whitelist.sh
    source "$INSTALL_DIR/lib/openpath-update-whitelist.sh"
    # shellcheck source=/usr/local/lib/openpath/lib/openpath-update-runtime.sh
    source "$INSTALL_DIR/lib/openpath-update-runtime.sh"
else
    # shellcheck source=../../lib/openpath-update-whitelist.sh
    source "$SCRIPT_DIR/../../lib/openpath-update-whitelist.sh"
    # shellcheck source=../../lib/openpath-update-runtime.sh
    source "$SCRIPT_DIR/../../lib/openpath-update-runtime.sh"
fi

# shellcheck disable=SC2034  # WHITELIST_URL is consumed by sourced helper modules.
WHITELIST_URL=$(get_whitelist_url)

main() {
    log "=== Starting whitelist update ==="

    init_directories
    # shellcheck disable=SC2034  # PRIMARY_DNS is consumed by sourced helper modules.
    PRIMARY_DNS=$(detect_primary_dns)

    local CAPTIVE_PORTAL_ACTION="continue"
    # shellcheck disable=SC1090,SC2154
    eval "$(resolve_captive_portal_preflight)"
    if ! apply_captive_portal_preflight "$CAPTIVE_PORTAL_ACTION"; then
        return 0
    fi

    local download_succeeded=false
    local WHITELIST_DOWNLOAD_PLAN="continue"
    local WHITELIST_AGE_HOURS=0
    local WHITELIST_REMAINING_HOURS=0
    local WHITELIST_CONTROL_HOST=""
    if download_whitelist; then
        download_succeeded=true
    fi

    # shellcheck disable=SC1090,SC2154
    eval "$(resolve_whitelist_download_plan "$download_succeeded")"
    if ! apply_whitelist_download_plan \
        "$WHITELIST_DOWNLOAD_PLAN" \
        "${WHITELIST_AGE_HOURS:-0}" \
        "${WHITELIST_REMAINING_HOURS:-0}" \
        "${WHITELIST_CONTROL_HOST:-}"; then
        return 0
    fi

    if check_emergency_disable; then
        if [ ! -f "$SYSTEM_DISABLED_FLAG" ]; then
            log "=== SISTEMA DESACTIVADO REMOTAMENTE ==="
            cleanup_system
            log "Closing browsers because the system is disabled..."
            force_browser_close
            touch "$SYSTEM_DISABLED_FLAG"
        else
            log "Sistema ya desactivado - sin cambios"
        fi
        return
    fi

    if [ -f "$SYSTEM_DISABLED_FLAG" ]; then
        log "System reactivating from disabled mode"
        rm -f "$SYSTEM_DISABLED_FLAG"
    fi

    parse_whitelist_sections "$WHITELIST_FILE"

    local firewall_was_inactive=false
    if [ "$(check_firewall_status)" != "active" ]; then
        firewall_was_inactive=true
    fi

    save_checkpoint "pre-update"
    generate_dnsmasq_config
    if ! sync_runtime_browser_integrations; then
        log_warn "Browser request setup is incomplete; skipping runtime browser integration"
        return 1
    fi

    local new_policies_hash
    new_policies_hash=$(get_policies_hash)
    local old_policies_hash=""
    if [ -f "$BROWSER_POLICIES_HASH" ]; then
        old_policies_hash=$(cat "$BROWSER_POLICIES_HASH" 2>/dev/null)
    fi

    local policies_changed=false
    if [ "$old_policies_hash" != "$new_policies_hash" ]; then
        policies_changed=true
        log "Browser policy changes detected"
        echo "$new_policies_hash" > "$BROWSER_POLICIES_HASH"
    fi

    local dns_config_changed=false
    local dns_healthy=false

    if has_config_changed; then
        dns_config_changed=true
        log "DNS configuration changes detected - applying..."

        if restart_dnsmasq; then
            sha256sum "$DNSMASQ_CONF" | cut -d' ' -f1 > "$DNSMASQ_CONF_HASH"

            if verify_dns; then
                dns_healthy=true
                log "✓ DNS functional"
            else
                log "⚠ DNS not functional - permissive mode"
            fi
        else
            log "ERROR: Failed to restart dnsmasq"
            cleanup_system
            return
        fi
    else
        if verify_dns; then
            dns_healthy=true
        else
            log "⚠ DNS not functional - keeping firewall permissive"
        fi
    fi

    # shellcheck disable=SC1090,SC2154
    eval "$(build_runtime_reconciliation_plan "$dns_config_changed" "$dns_healthy" "$firewall_was_inactive" "$policies_changed")"
    apply_runtime_reconciliation_plan \
        "$FIREWALL_ACTION" \
        "$FLUSH_CONNECTIONS" \
        "$FLUSH_REASON" \
        "$ACTIVATION_CONTEXT"

    log "=== Update completed ==="
}

main "$@"
