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
# captive-portal.sh - Captive portal helpers
# Part of the OpenPath DNS system
#
# Expected dependencies (must be sourced by the caller):
# - common.sh (VAR_STATE_DIR, LOG_FILE, log functions)
# - dns.sh (detect_primary_dns, restart_dnsmasq)
# - firewall.sh (activate_firewall, deactivate_firewall, flush_connections)
################################################################################

# Debian/FHS state paths (overrideable for tests)
CAPTIVE_PORTAL_STATE_FILE="${CAPTIVE_PORTAL_STATE_FILE:-$VAR_STATE_DIR/captive-portal-active.state}"
CAPTIVE_DNSMASQ_BACKUP_FILE="${CAPTIVE_DNSMASQ_BACKUP_FILE:-$VAR_STATE_DIR/openpath.conf.pre-portal}"

is_portal_mode_active() {
    [ -f "$CAPTIVE_PORTAL_STATE_FILE" ]
}

get_portal_mode_start_ts() {
    if [ ! -f "$CAPTIVE_PORTAL_STATE_FILE" ]; then
        return 1
    fi

    local ts
    ts=$(cat "$CAPTIVE_PORTAL_STATE_FILE" 2>/dev/null | head -1)
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        echo "$ts"
        return 0
    fi
    return 1
}

get_active_ssid() {
    if ! command -v nmcli >/dev/null 2>&1; then
        return 1
    fi

    LC_ALL=C nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null \
        | awk -F: '$1=="yes" {print $2; exit}'
}

enter_portal_mode_locked() {
    mkdir -p "$VAR_STATE_DIR" 2>/dev/null || true

    PRIMARY_DNS=$(detect_primary_dns)
    export PRIMARY_DNS

    if [ -f "$DNSMASQ_CONF" ]; then
        cp "$DNSMASQ_CONF" "$CAPTIVE_DNSMASQ_BACKUP_FILE" 2>/dev/null || true
    fi

    log "[CAPTIVE] Captive portal detected - enabling fail-open mode (DNS passthrough + permissive firewall)" "WARN"

    if ! write_dnsmasq_passthrough_config "$PRIMARY_DNS" "$DNSMASQ_CONF"; then
        log "[CAPTIVE] ERROR: Could not write portal-mode DNS configuration" "ERROR"
    fi

    if ! restart_dnsmasq; then
        log "[CAPTIVE] ERROR: dnsmasq did not restart in portal mode" "ERROR"
        if [ -f "$CAPTIVE_DNSMASQ_BACKUP_FILE" ]; then
            log "[CAPTIVE] Restoring previous DNS configuration" "WARN"
            cp "$CAPTIVE_DNSMASQ_BACKUP_FILE" "$DNSMASQ_CONF" 2>/dev/null || true
            restart_dnsmasq 2>/dev/null || true
        fi
    fi

    # deactivate_firewall also relaxes the bypass blocks (DoH ipset rules,
    # VPN interface/port blocks, Tor port blocks) and destroys the
    # openpath-doh-block ipset so portal login pages on HTTPS resolver
    # infrastructure are reachable during the passthrough window.
    deactivate_firewall
    flush_connections 2>/dev/null || true

    date +%s > "$CAPTIVE_PORTAL_STATE_FILE" 2>/dev/null || true
    return 0
}

exit_portal_mode_locked() {
    PRIMARY_DNS=$(detect_primary_dns)
    export PRIMARY_DNS

    local start_ts duration
    duration=""
    if start_ts=$(get_portal_mode_start_ts); then
        duration=$(( $(date +%s) - start_ts ))
    fi

    log "[CAPTIVE] Authentication completed - restoring protections" "INFO"
    if [ -n "$duration" ]; then
        log "[CAPTIVE] Tiempo en modo portal: ${duration}s" "INFO"
    fi

    if [ -f "$DNSMASQ_CONF" ] && grep -q "^# OPENPATH PORTAL MODE" "$DNSMASQ_CONF" 2>/dev/null; then
        if [ -f "$CAPTIVE_DNSMASQ_BACKUP_FILE" ]; then
            cp "$CAPTIVE_DNSMASQ_BACKUP_FILE" "$DNSMASQ_CONF" 2>/dev/null || true
            restart_dnsmasq 2>/dev/null || true
        fi
    fi

    rm -f "$CAPTIVE_DNSMASQ_BACKUP_FILE" 2>/dev/null || true
    rm -f "$CAPTIVE_PORTAL_STATE_FILE" 2>/dev/null || true

    activate_firewall
    flush_connections 2>/dev/null || true
    return 0
}
