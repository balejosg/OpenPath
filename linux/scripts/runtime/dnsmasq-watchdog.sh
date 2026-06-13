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
# dnsmasq-watchdog.sh - Watchdog para dnsmasq
# Parte del sistema OpenPath DNS
#
# Verifica la salud del sistema y recupera automáticamente si hay problemas
################################################################################

# Cargar librerías
INSTALL_DIR="/usr/local/lib/openpath"
source "$INSTALL_DIR/lib/common.sh"
if ! load_libraries; then
    echo "ERROR: Missing required OpenPath libraries" >&2
    exit 1
fi

# Captive-portal helpers: the watchdog auto-closes an expired portal-mode
# passthrough marker so fail-open never outlives its deadline (WEDU lesson).
# shellcheck source=../../lib/captive-portal.sh
source "$INSTALL_DIR/lib/captive-portal.sh"

HEALTH_FILE="$CONFIG_DIR/health-status"
FAIL_COUNT_FILE="$CONFIG_DIR/watchdog-fails"
INTEGRITY_HASH_FILE="$CONFIG_DIR/integrity.sha256"
WATCHDOG_PROTECTED_FLAG="${WATCHDOG_PROTECTED_FLAG:-$CONFIG_DIR/watchdog-protected.flag}"
MAX_CONSECUTIVE_FAILS=3

# Obtener/incrementar contador de fallos
get_fail_count() {
    if [ -f "$FAIL_COUNT_FILE" ]; then
        local count
        count=$(cat "$FAIL_COUNT_FILE")
        if [[ "$count" =~ ^[0-9]+$ ]]; then
            echo "$count"
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

increment_fail_count() {
    local count
    count=$(get_fail_count)
    echo $((count + 1)) > "$FAIL_COUNT_FILE"
}

reset_fail_count() {
    echo "0" > "$FAIL_COUNT_FILE"
}

# Verificaciones
check_dnsmasq_running() {
    systemctl is-active --quiet dnsmasq
}

check_dns_resolving() {
    local probe_domain
    local probe_result

    probe_domain=$(select_allowed_dns_probe_domain)
    probe_result=$(resolve_local_dns_probe "$probe_domain")

    dns_probe_result_is_public "$probe_result"
}

check_upstream_dns() {
    [ -s /run/dnsmasq/resolv.conf ]
}

check_resolv_conf() {
    grep -q "nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null
}

# Generate integrity hashes for critical files
# Called during install to establish baseline
generate_integrity_hashes() {
    local hash_file="$INTEGRITY_HASH_FILE"
    : > "$hash_file"
    for f in "${CRITICAL_FILES[@]}"; do
        if [ -f "$f" ]; then
            sha256sum "$f" >> "$hash_file"
        fi
    done
    chmod 600 "$hash_file"
    log "[INTEGRITY] Baseline hashes generated for ${#CRITICAL_FILES[@]} files"
}

get_stored_integrity_hash() {
    local path="$1"
    [ -n "$path" ] && [ -f "$INTEGRITY_HASH_FILE" ] || return 1

    awk -v path="$path" '$2 == path { print $1; exit }' "$INTEGRITY_HASH_FILE" 2>/dev/null
}

# Verify file integrity against stored hashes
# Returns 0 if all OK, 1 if tampering detected
check_integrity() {
    if [ ! -f "$INTEGRITY_HASH_FILE" ]; then
        # No baseline yet — generate one and return OK
        generate_integrity_hashes
        return 0
    fi

    local tampered=0
    local missing=0

    for f in "${CRITICAL_FILES[@]}"; do
        if [ ! -f "$f" ]; then
            log_warn "[INTEGRITY] MISSING: $f"
            missing=$((missing + 1))
            continue
        fi

        local current_hash
        current_hash=$(sha256sum "$f" | cut -d' ' -f1)
        local stored_hash
        stored_hash=$(get_stored_integrity_hash "$f")

        if [ -z "$stored_hash" ]; then
            log_debug "[INTEGRITY] No baseline entry for $f"
            continue
        fi

        if [ "$current_hash" != "$stored_hash" ]; then
            log_warn "[INTEGRITY] TAMPERED: $f (expected=$stored_hash actual=$current_hash)"
            tampered=$((tampered + 1))
        fi
    done

    if [ $((tampered + missing)) -gt 0 ]; then
        log_error "[INTEGRITY] Tampering detected: $tampered modified, $missing missing"
        return 1
    fi

    log_debug "[INTEGRITY] All ${#CRITICAL_FILES[@]} critical files OK"
    return 0
}

# Recover tampered files by reinstalling from deb package or backup
recover_integrity() {
    log "[INTEGRITY] Attempting recovery..."

    # Try to reinstall package if it is installed
    if dpkg -s openpath-dnsmasq >/dev/null 2>&1; then
        if DEBIAN_FRONTEND=noninteractive apt_install_with_retry "openpath-dnsmasq reinstall" \
            apt-get install --reinstall -y openpath-dnsmasq >/dev/null 2>&1; then
            log "[INTEGRITY] Recovered from deb package"
            generate_integrity_hashes
            return 0
        fi

        # Fallback: use cached .deb if available
        local cached_deb
        cached_deb=$(ls -1 /var/cache/apt/archives/openpath-dnsmasq_*.deb 2>/dev/null | head -1 || true)
        if [ -n "$cached_deb" ] && dpkg -i "$cached_deb" >/dev/null 2>&1; then
            log "[INTEGRITY] Recovered from cached package: $cached_deb"
            generate_integrity_hashes
            return 0
        fi
    fi

    log_error "[INTEGRITY] Cannot auto-recover — manual reinstallation required"
    return 1
}

# Recuperaciones
recover_upstream_dns() {
    log "[WATCHDOG] Recuperando DNS upstream..."
    if [ -x "$SCRIPTS_DIR/dnsmasq-init-resolv.sh" ]; then
        "$SCRIPTS_DIR/dnsmasq-init-resolv.sh"
    else
        mkdir -p /run/dnsmasq
        local dns
        dns=$(head -1 "$ORIGINAL_DNS_FILE" 2>/dev/null)
        [ -z "$dns" ] && dns="8.8.8.8"
        echo "nameserver $dns" > /run/dnsmasq/resolv.conf
        echo "nameserver 8.8.8.8" >> /run/dnsmasq/resolv.conf
    fi
}

recover_resolv_conf() {
    log "[WATCHDOG] Recuperando /etc/resolv.conf..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
options edns0 trust-ad
search lan
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
}

################################################################################
# Protected-mode helpers (ADR 0011)
################################################################################

# Returns 0 if the operator has explicitly requested fail-open behaviour.
# Any value other than "open" is treated as "protected" (the default).
_watchdog_failure_mode_is_open() {
    [ "${FAILURE_MODE:-protected}" = "open" ]
}

# Switch dnsmasq to a restricted critical-domains config without deactivating
# the firewall, then write the protected-mode state marker.
enter_protected_mode() {
    log "[WATCHDOG] Entering protected mode (critical-domains only)"

    local upstream_dns
    upstream_dns=$(select_usable_upstream_dns "${PRIMARY_DNS:-}" 2>/dev/null || echo "8.8.8.8")

    if write_dnsmasq_protected_mode_config "$upstream_dns" "$DNSMASQ_CONF"; then
        if systemctl restart dnsmasq 2>/dev/null; then
            log "[WATCHDOG] dnsmasq restarted with protected-mode config"
        else
            log_warn "[WATCHDOG] dnsmasq restart failed after protected-mode config write"
        fi
    else
        log_warn "[WATCHDOG] write_dnsmasq_protected_mode_config failed; dnsmasq config unchanged"
    fi

    cat > "$WATCHDOG_PROTECTED_FLAG" << EOF
{
    "enteredAt": "$(date -Iseconds)",
    "failCount": $(get_fail_count)
}
EOF
    report_health_to_api "PROTECTED" "protected_mode_activated"
}

# Remove the protected-mode state marker.  Called on recovery.
exit_protected_mode() {
    if [ -f "$WATCHDOG_PROTECTED_FLAG" ]; then
        rm -f "$WATCHDOG_PROTECTED_FLAG"
        log "[WATCHDOG] Protected mode cleared"
    fi
}

# Principal
main() {
    local status="HEALTHY"
    local actions=""
    local recovered_cycle=false
    local fail_count
    fail_count=$(get_fail_count)

    # Auto-close an expired captive-portal passthrough marker (the detector
    # refreshes the deadline while the portal is still observed, so an expired
    # marker means the portal flow never completed or the detector is gone).
    close_expired_portal_mode || true
    
    # Protección contra loop infinito de reinicios
    if [ "$fail_count" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
        log "[WATCHDOG] ALERTA: $fail_count fallos consecutivos"
        
        # First, try to rollback to a previous working checkpoint
        if attempt_rollback_recovery; then
            status="DEGRADED"
            actions="rollback_recovery"
            recovered_cycle=true
            # Don't enter fail-open, rollback succeeded
        else
            # Rollback failed — use failure mode from config.
            if _watchdog_failure_mode_is_open; then
                # Legacy escape hatch: operator has explicitly opted into fail-open.
                log "[WATCHDOG] Entrando en modo fail-open (OPENPATH_FAILURE_MODE=open)"
                deactivate_firewall

                status="FAIL_OPEN"
                cat > "$HEALTH_FILE" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "status": "FAIL_OPEN",
    "message": "Demasiados fallos consecutivos - sistema en modo permisivo (escape hatch activo)",
    "fail_count": $fail_count
}
EOF
                # Report fail-open to central API immediately
                report_health_to_api "FAIL_OPEN" "fail_open_activated"
            else
                # Default: protected mode — keep firewall, restrict dnsmasq to critical domains.
                enter_protected_mode

                status="PROTECTED"
                cat > "$HEALTH_FILE" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "status": "PROTECTED",
    "message": "Demasiados fallos consecutivos - modo protegido activo (solo dominios criticos)",
    "fail_count": $fail_count
}
EOF
            fi

            # No resetear contador - requiere intervención manual
            return 1
        fi
    fi
    
    # Check 1: dnsmasq running
    if ! check_dnsmasq_running; then
        status="CRITICAL"
        actions="dnsmasq_restart"
        log "[WATCHDOG] CRITICAL: dnsmasq is not running"
    fi
    
    # Check 2: upstream DNS config
    if ! check_upstream_dns; then
        [ "$status" = "HEALTHY" ] && status="DEGRADED"
        actions="$actions upstream_dns"
        log "[WATCHDOG] WARNING: /run/dnsmasq/resolv.conf does not exist"
    fi
    
    # Check 3: resolv.conf
    if ! check_resolv_conf; then
        [ "$status" = "HEALTHY" ] && status="DEGRADED"
        actions="$actions resolv_conf"
        log "[WATCHDOG] WARNING: /etc/resolv.conf does not point to localhost"
    fi
    
    # Check 4: file integrity (anti-tampering)
    if ! check_integrity; then
        [ "$status" = "HEALTHY" ] && status="DEGRADED"
        actions="$actions integrity_recovery"
        log "[WATCHDOG] ALERT: File integrity compromised"
    fi
    
    # Run recovery actions.
    if [ -n "$actions" ]; then
        log "[WATCHDOG] Starting recovery: $actions"
        
        for action in $actions; do
            case "$action" in
                upstream_dns)
                    recover_upstream_dns
                    ;;
                resolv_conf)
                    recover_resolv_conf
                    ;;
                integrity_recovery)
                    if recover_integrity; then
                        log "[WATCHDOG] ✓ Integridad restaurada"
                        status="DEGRADED"
                        recovered_cycle=true
                    else
                        status="TAMPERED"
                        report_health_to_api "TAMPERED" "integrity_failure"
                    fi
                    ;;
                dnsmasq_restart)
                    recover_upstream_dns
                    recover_resolv_conf
                    systemctl restart dnsmasq
                    # Esperar a que dnsmasq esté listo (máx 5 segundos)
                    for _ in $(seq 1 5); do
                        if check_dnsmasq_running; then
                            break
                        fi
                        sleep 1
                    done
                    if check_dnsmasq_running; then
                        log "[WATCHDOG] ✓ dnsmasq reiniciado"
                        status="DEGRADED"
                        recovered_cycle=true
                    else
                        status="CRITICAL"
                        increment_fail_count
                    fi
                    ;;
            esac
        done
    fi
    
    # Si está sano o recuperado en este ciclo, resetear contador de fallos y salir del modo protegido
    if [ "$status" = "HEALTHY" ] || [ "$recovered_cycle" = true ]; then
        reset_fail_count
        exit_protected_mode
    fi
    
    # Guardar estado local
    cat > "$HEALTH_FILE" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "status": "$status",
    "dnsmasq_running": $(check_dnsmasq_running && echo "true" || echo "false"),
    "dns_resolving": $(check_dns_resolving && echo "true" || echo "false"),
    "fail_count": $(get_fail_count),
    "actions": "$actions"
}
EOF
    
    # Report health to central API (mandatory)
    report_health_to_api "$status" "$actions"
    
    [ "$status" = "HEALTHY" ] || [ "$recovered_cycle" = true ]
}

# Whole hours since the whitelist cache was last written (empty when unknown),
# so the server can flag a stale/never-applied whitelist.
compute_whitelist_age_hours() {
    local wl="${WHITELIST_FILE:-/var/lib/openpath/whitelist.txt}"
    [ -f "$wl" ] || { echo ""; return 0; }
    local mtime now
    mtime=$(stat -c %Y "$wl" 2>/dev/null) || { echo ""; return 0; }
    now=$(date +%s)
    echo $(( (now - mtime) / 3600 ))
}

# Report health status to central monitoring API (using tRPC)
report_health_to_api() {
    local status="$1"
    local actions="$2"
    local dnsmasq_running dns_resolving fail_count firewall_state whitelist_age_hours
    dnsmasq_running=$(check_dnsmasq_running && echo "true" || echo "false")
    dns_resolving=$(check_dns_resolving && echo "true" || echo "false")
    fail_count=$(get_fail_count)
    # Enforcement telemetry: firewall active|inactive (empty if unavailable so the
    # server records null rather than a false enforcement-down), and whitelist age.
    firewall_state=""
    if declare -F check_firewall_status >/dev/null 2>&1; then
        firewall_state=$(check_firewall_status 2>/dev/null || true)
    fi
    whitelist_age_hours=$(compute_whitelist_age_hours)

    send_health_report_to_api "$status" "$actions" "$dnsmasq_running" "$dns_resolving" \
        "$fail_count" "${VERSION:-1.0.4}" "$firewall_state" "$whitelist_age_hours"
}

# Attempt rollback before entering fail-open mode
attempt_rollback_recovery() {
    log "[WATCHDOG] Intentando restaurar desde checkpoint antes de entrar en modo fail-open..."
    
    if has_checkpoint; then
        local prev
        prev=$(get_previous_checkpoint)
        if [ -n "$prev" ]; then
            restore_checkpoint "$prev"
            
            # Esperar a que el sistema se asiente tras el rollback (máx 5 segundos)
            for _ in $(seq 1 5); do
                if check_dnsmasq_running && check_dns_resolving; then
                    break
                fi
                sleep 1
            done
            
            # Check if rollback fixed the issue, then re-validate the restored
            # runtime state. A restore that brings dnsmasq back but leaves the
            # config/firewall/resolv.conf non-canonical (corrupt or tampered
            # checkpoint) must NOT be treated as recovered: keep the fail count
            # so the next cycle retries, and do not re-enter protected mode here.
            if check_dnsmasq_running && check_dns_resolving; then
                if validate_restored_checkpoint; then
                    log "[WATCHDOG] ✓ Rollback exitoso - sistema recuperado"
                    reset_fail_count
                    return 0
                fi
                log "[WATCHDOG] ⚠ Rollback restauró pero la validación post-restore falló - se mantiene el estado degradado"
                return 1
            fi
        fi
    fi
    
    log "[WATCHDOG] Rollback failed or no checkpoint is available"
    return 1
}

main "$@"
