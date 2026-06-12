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
# captive-portal-detector.sh - Captive portal detector
# Part of the OpenPath DNS system
#
# Detects captive portals (hotel WiFi, airports, etc.)
# and temporarily deactivates the firewall for authentication
################################################################################

# Cargar librerías
INSTALL_DIR="/usr/local/lib/openpath"
source "$INSTALL_DIR/lib/common.sh"
source "$INSTALL_DIR/lib/dns.sh"
source "$INSTALL_DIR/lib/firewall.sh"
source "$INSTALL_DIR/lib/captive-portal.sh"

# Lock file compartido con openpath-update.sh (defined in common.sh as OPENPATH_LOCK_FILE)

CAPTIVE_PORTAL_DETECTED=false
LAST_STATE=""

SLEEP_PID=""

# NOTE: is_network_authenticated() and check_captive_portal() are now
# defined in common.sh to avoid code duplication with openpath-update.sh

wake_now() {
    if [ -n "${SLEEP_PID:-}" ]; then
        kill "$SLEEP_PID" 2>/dev/null || true
    fi
}

trap 'wake_now' USR1

interruptible_sleep() {
    local seconds="$1"
    sleep "$seconds" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
}

# Main loop
main() {
    log "[CAPTIVE] Starting captive portal detector"

    if is_portal_mode_active; then
        if close_expired_portal_mode; then
            log "[CAPTIVE] Expired portal mode marker closed at startup" "WARN"
        else
            log "[CAPTIVE] Portal mode marker detected at startup - keeping fail-open mode until AUTHENTICATED" "WARN"
            CAPTIVE_PORTAL_DETECTED=true
        fi
    fi

    while true; do
        local state
        state=$(get_captive_portal_state)
        update_captive_portal_observation "$state"

        if [ "$state" != "$LAST_STATE" ]; then
            local ssid gw
            ssid=$(get_active_ssid 2>/dev/null || true)
            gw=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}' || true)
            log "[CAPTIVE] Estado: ${LAST_STATE:-INIT} -> $state (ssid=${ssid:-n/a}, gw=${gw:-n/a})" "INFO"
            LAST_STATE="$state"
        fi

        if [ "$state" = "AUTHENTICATED" ]; then
            if [ "$CAPTIVE_PORTAL_DETECTED" = true ] || is_portal_mode_active; then
                # Anti-oscillation: require CAPTIVE_PORTAL_EXIT_THRESHOLD
                # consecutive AUTHENTICATED observations before restoring.
                if should_exit_portal_mode; then
                    if with_openpath_lock exit_portal_mode_locked; then
                        CAPTIVE_PORTAL_DETECTED=false
                    fi
                fi
            fi
        elif [ "$state" = "PORTAL" ]; then
            if [ "$CAPTIVE_PORTAL_DETECTED" = false ] && ! is_portal_mode_active; then
                # Anti-oscillation: require CAPTIVE_PORTAL_ENTER_THRESHOLD
                # consecutive PORTAL observations before going fail-open.
                if should_enter_portal_mode; then
                    if with_openpath_lock enter_portal_mode_locked; then
                        CAPTIVE_PORTAL_DETECTED=true
                    fi
                fi
            elif is_portal_mode_active; then
                # Portal still observed: keep the passthrough deadline alive.
                refresh_portal_mode_expiry || true
            fi
        fi

        # Passthrough must not persist if the portal flow never completes:
        # close an expired marker whenever the portal is no longer observed.
        if [ "$state" != "PORTAL" ] && close_expired_portal_mode; then
            CAPTIVE_PORTAL_DETECTED=false
        fi

        local interval
        if [ "$state" = "AUTHENTICATED" ]; then
            interval="${CAPTIVE_INTERVAL_NORMAL:-60}"
        elif [ "$state" = "PORTAL" ]; then
            interval="${CAPTIVE_INTERVAL_PORTAL_ACTIVE:-10}"
        else
            interval="${CAPTIVE_INTERVAL_NO_NETWORK:-5}"
        fi

        interruptible_sleep "$interval"
    done
}

main "$@"
