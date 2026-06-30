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
# common.sh - Common variables and functions
# Part of the OpenPath DNS system
################################################################################

# System version - read from central VERSION file or fallback
_VERSION_FILE="${INSTALL_DIR:-/usr/local/lib/openpath}/VERSION"
_SCRIPT_VERSION_FILE="$(dirname "${BASH_SOURCE[0]}")/../../VERSION"
if [ -f "$_VERSION_FILE" ]; then
    VERSION=$(cat "$_VERSION_FILE")
elif [ -f "$_SCRIPT_VERSION_FILE" ]; then
    VERSION=$(cat "$_SCRIPT_VERSION_FILE")
else
    VERSION="4.1.0"
fi
export VERSION

# Source configurable defaults (must be early, before other variables)
# Try installed location first, then source directory
if [ -f "/usr/local/lib/openpath/lib/defaults.conf" ]; then
    # shellcheck source=defaults.conf
    source "/usr/local/lib/openpath/lib/defaults.conf"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/defaults.conf" ]; then
    # shellcheck source=defaults.conf
    source "$(dirname "${BASH_SOURCE[0]}")/defaults.conf"
fi

# Directories and files - exported for use by other scripts
export INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/openpath}"
export SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/local/bin}"

# Debian FHS compliant paths:
# - /etc/ for configuration (preserved on upgrade)
# - /var/lib/ for state/cache (can be regenerated)
# Use defaults if not set (allows override for testing)
ETC_CONFIG_DIR="${ETC_CONFIG_DIR:-/etc/openpath}"
VAR_STATE_DIR="${VAR_STATE_DIR:-/var/lib/openpath}"
LOG_FILE="${LOG_FILE:-/var/log/openpath.log}"

# Configuration files (in /etc/, preserved on upgrade) - exported for use by other scripts
export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
export HEALTH_API_URL_CONF="$ETC_CONFIG_DIR/health-api-url.conf"
export HEALTH_API_SECRET_CONF="$ETC_CONFIG_DIR/health-api-secret.conf"
export MACHINE_NAME_CONF="$ETC_CONFIG_DIR/machine-name.conf"
export ORIGINAL_DNS_FILE="$ETC_CONFIG_DIR/original-dns.conf"

# State/cache files (in /var/lib/, regenerated) - exported for use by other scripts
# Use default if not set (allows override for testing)
export DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.d/openpath.conf}"
export DNSMASQ_CONF_HASH="${DNSMASQ_CONF_HASH:-$VAR_STATE_DIR/dnsmasq.hash}"
export BROWSER_POLICIES_HASH="${BROWSER_POLICIES_HASH:-$VAR_STATE_DIR/browser-policies.hash}"
export SYSTEM_DISABLED_FLAG="${SYSTEM_DISABLED_FLAG:-$VAR_STATE_DIR/system-disabled.flag}"
export WHITELIST_FILE="${WHITELIST_FILE:-$VAR_STATE_DIR/whitelist.txt}"
export RUNTIME_DEPENDENCY_QUEUE_DIR="${RUNTIME_DEPENDENCY_QUEUE_DIR:-$VAR_STATE_DIR/runtime-dependency-queue}"
export RUNTIME_DEPENDENCY_REJECTED_DIR="${RUNTIME_DEPENDENCY_REJECTED_DIR:-$VAR_STATE_DIR/runtime-dependency-rejected}"
export RUNTIME_DEPENDENCY_OVERLAY_FILE="${RUNTIME_DEPENDENCY_OVERLAY_FILE:-$VAR_STATE_DIR/runtime-dependency-overlay.json}"
export OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PROCESS_LIMIT="${OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PROCESS_LIMIT:-100}"

# Legacy compatibility (for migration) - exported for use by other scripts
export CONFIG_DIR="$VAR_STATE_DIR"

# Browser policies - exported for use by other scripts
export FIREFOX_POLICIES="${FIREFOX_POLICIES:-/etc/firefox/policies/policies.json}"
export CHROMIUM_POLICIES_BASE="${CHROMIUM_POLICIES_BASE:-/etc/chromium/policies/managed}"
export FIREFOX_EXTENSION_READY_FILE="${FIREFOX_EXTENSION_READY_FILE:-$VAR_STATE_DIR/firefox-extension-ready}"

# Default URL (must be provided via defaults.conf or environment)
# Empty default forces explicit configuration
DEFAULT_WHITELIST_URL="${DEFAULT_WHITELIST_URL:-}"

# Lock file for mutual exclusion between scripts that modify firewall/dnsmasq
export OPENPATH_LOCK_FILE="${OPENPATH_LOCK_FILE:-/var/run/openpath.lock}"

# shellcheck disable=SC2034 # Used from sourced protected-domain helpers.
OPENPATH_PROTECTED_DOMAINS=()
# shellcheck disable=SC2034 # Used from sourced protected-domain helpers.
OPENPATH_PROTECTED_DOMAINS_READY=0

# shellcheck source=common-connectivity.sh
source "$(dirname "${BASH_SOURCE[0]}")/common-connectivity.sh"

# shellcheck source=common-registration.sh
source "$(dirname "${BASH_SOURCE[0]}")/common-registration.sh"

# shellcheck source=common-locking.sh
source "$(dirname "${BASH_SOURCE[0]}")/common-locking.sh"

# shellcheck source=common-config-persistence.sh
source "$(dirname "${BASH_SOURCE[0]}")/common-config-persistence.sh"

# shellcheck source=common-protected-domains.sh
source "$(dirname "${BASH_SOURCE[0]}")/common-protected-domains.sh"

# Global variables (initialized at runtime) - exported for use by other scripts
# Preserve test/runtime overrides when this file is sourced more than once.
export PRIMARY_DNS="${PRIMARY_DNS:-}"
export GATEWAY_IP="${GATEWAY_IP:-}"
export DNS_CHANGED="${DNS_CHANGED:-false}"

# Arrays for whitelist parsing
WHITELIST_DOMAINS=()
BLOCKED_SUBDOMAINS=()
BLOCKED_PATHS=()
ALLOWED_PATHS=()

# Logging function with levels
# Includes PID and caller for structured debugging in fleet deployments
# Usage: log "message" or log_info/log_warn/log_error/log_debug "message"
log() {
    local level="${2:-INFO}"
    local caller="${FUNCNAME[1]:-main}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] [${caller}] [$$] ${1}"

    # Always print to stdout (journald/console) and best-effort append to file.
    # IMPORTANT: logging must never abort installers or services running under `set -e`.
    printf '%s\n' "$line" || true

    if [ -n "${LOG_FILE:-}" ]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi

    return 0
}

log_info() {
    log "$1" "INFO"
    return 0
}

log_warn() {
    log "$1" "WARN"
    return 0
}

log_error() {
    log "$1" "ERROR"
    return 0
}

log_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
        log "$1" "DEBUG"
    fi
    return 0
}

# Create necessary directories
init_directories() {
    mkdir -p "$ETC_CONFIG_DIR"
    mkdir -p "$VAR_STATE_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$INSTALL_DIR/lib"
}

get_url_host() {
    local url="$1"
    local without_scheme="${url#*://}"
    local host_port="${without_scheme%%/*}"

    host_port="${host_port##*@}"
    echo "${host_port%%:*}"
}

is_openpath_domain_format() {
    local domain="$1"

    if declare -F validate_domain >/dev/null 2>&1; then
        validate_domain "$domain"
        return $?
    fi

    [ -z "$domain" ] && return 1
    [ ${#domain} -lt 4 ] && return 1
    [ ${#domain} -gt 253 ] && return 1

    local check_domain="$domain"
    if [[ "$domain" == \*.* ]]; then
        check_domain="${domain:2}"
    fi

    [[ "$domain" == "*." ]] && return 1
    [[ "$domain" == "*" ]] && return 1
    [[ "$check_domain" =~ \.local$ ]] && return 1
    [[ "$check_domain" =~ \.\. ]] && return 1
    [[ "$check_domain" != *.* ]] && return 1

    IFS='.' read -ra labels <<< "$check_domain"
    [ ${#labels[@]} -lt 2 ] && return 1

    local label index last_index
    last_index=$((${#labels[@]} - 1))
    for index in "${!labels[@]}"; do
        label="${labels[$index]}"
        [ -z "$label" ] && return 1
        [ ${#label} -gt 63 ] && return 1
        [[ "$label" == -* ]] && return 1
        [[ "$label" == *- ]] && return 1

        if [ "$index" -eq "$last_index" ]; then
            [ ${#label} -lt 2 ] && return 1
            [[ ! "$label" =~ ^[a-zA-Z]+$ ]] && return 1
        else
            [[ ! "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] && return 1
        fi
    done

    return 0
}

# Parse whitelist file sections
parse_whitelist_sections() {
    local file="$1"

    WHITELIST_DOMAINS=()
    BLOCKED_SUBDOMAINS=()
    BLOCKED_PATHS=()
    ALLOWED_PATHS=()

    if [ ! -f "$file" ]; then
        log "Whitelist file not found: $file"
        return 1
    fi

    local entry_type=""
    local entry_value=""
    while IFS=$'\t' read -r entry_type entry_value; do
        case "$entry_type" in
            "whitelist")
                WHITELIST_DOMAINS+=("$entry_value")
                ;;
            "blocked_sub")
                BLOCKED_SUBDOMAINS+=("$entry_value")
                ;;
            "blocked_path")
                BLOCKED_PATHS+=("$entry_value")
                ;;
            "allowed_path")
                ALLOWED_PATHS+=("$entry_value")
                ;;
        esac
    done < <(
        awk '
            BEGIN { section = "whitelist" }
            /^[[:space:]]*##[[:space:]]*WHITELIST[[:space:]]*$/ { section = "whitelist"; next }
            /^[[:space:]]*##[[:space:]]*BLOCKED-SUBDOMAINS[[:space:]]*$/ { section = "blocked_sub"; next }
            /^[[:space:]]*##[[:space:]]*BLOCKED-PATHS[[:space:]]*$/ { section = "blocked_path"; next }
            /^[[:space:]]*##[[:space:]]*ALLOWED-PATHS[[:space:]]*$/ { section = "allowed_path"; next }
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            {
                line = $0
                sub(/\r$/, "", line)
                print section "\t" line
            }
        ' "$file"
    )

    protect_control_plane_rules

    log "Parsed: ${#WHITELIST_DOMAINS[@]} domains, ${#BLOCKED_SUBDOMAINS[@]} blocked subdomains, ${#BLOCKED_PATHS[@]} blocked paths, ${#ALLOWED_PATHS[@]} allowed paths"
}

# Check if script is running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: This script must be run as root"
        exit 1
    fi
}

# Critical files for integrity checks (single source of truth)
# Used by install.sh, dnsmasq-watchdog.sh, and openpath-self-update.sh
# shellcheck disable=SC2034  # Used by scripts that source common.sh
CRITICAL_FILES=(
    "$INSTALL_DIR/lib/common.sh"
    "$INSTALL_DIR/lib/apt.sh"
    "$INSTALL_DIR/lib/dns.sh"
    "$INSTALL_DIR/lib/dns-validation.sh"
    "$INSTALL_DIR/lib/dns-runtime.sh"
    "$INSTALL_DIR/lib/dns-dnsmasq.sh"
    "$INSTALL_DIR/lib/firewall.sh"
    "$INSTALL_DIR/lib/firewall-rule-helpers.sh"
    "$INSTALL_DIR/lib/firewall-snapshot.sh"
    "$INSTALL_DIR/lib/firewall-runtime.sh"
    "$INSTALL_DIR/lib/captive-portal.sh"
    "$INSTALL_DIR/lib/browser.sh"
    "$INSTALL_DIR/lib/browser-process.sh"
    "$INSTALL_DIR/lib/browser-firefox.sh"
    "$INSTALL_DIR/lib/browser-native-host.sh"
    "$INSTALL_DIR/lib/browser-request-readiness.sh"
    "$INSTALL_DIR/lib/chromium-managed-extension.sh"
    "$INSTALL_DIR/lib/firefox-policy.sh"
    "$INSTALL_DIR/lib/firefox-managed-extension.sh"
    "$INSTALL_DIR/lib/openpath-update-whitelist.sh"
    "$INSTALL_DIR/lib/openpath-update-runtime.sh"
    "$INSTALL_DIR/lib/runtime-dependency-policy.sh"
    "$INSTALL_DIR/lib/runtime-dependency-overlay.sh"
    "$INSTALL_DIR/lib/runtime-dependency-queue.sh"
    "$INSTALL_DIR/lib/openpath-self-update-metadata.sh"
    "$INSTALL_DIR/lib/openpath-self-update-package.sh"
    "$INSTALL_DIR/libexec/browser-json.py"
    "$INSTALL_DIR/libexec/browser-policy-spec.json"
    "$INSTALL_DIR/libexec/runtime-dependency-overlay.py"
    "$INSTALL_DIR/lib/services.sh"
    "$INSTALL_DIR/lib/rollback.sh"
    "$SCRIPTS_DIR/openpath-update.sh"
    "$SCRIPTS_DIR/dnsmasq-watchdog.sh"
    "$SCRIPTS_DIR/openpath-browser-setup.sh"
    "$SCRIPTS_DIR/openpath"
)

# Load all libraries
load_libraries() {
    local lib_dir="${1:-$INSTALL_DIR/lib}"
    local libexec_dir
    local lib
    local helper_lib

    libexec_dir="$(cd "$lib_dir/.." && pwd)/libexec"

    for helper_lib in \
        chromium-managed-extension.sh \
        firefox-policy.sh \
        firefox-managed-extension.sh \
        browser-request-readiness.sh \
        browser-process.sh \
        browser-firefox.sh \
        browser-native-host.sh \
        dns-validation.sh \
        dns-runtime.sh \
        dns-dnsmasq.sh \
        firewall-rule-helpers.sh \
        firewall-snapshot.sh \
        firewall-runtime.sh \
        openpath-update-whitelist.sh \
        openpath-update-runtime.sh \
        runtime-dependency-policy.sh \
        runtime-dependency-overlay.sh \
        runtime-dependency-queue.sh \
        openpath-self-update-metadata.sh \
        openpath-self-update-package.sh; do
        if [ ! -f "$lib_dir/$helper_lib" ]; then
            log_error "Required library not found: $lib_dir/$helper_lib"
            return 1
        fi
    done

    for helper_runtime in browser-json.py browser-policy-spec.json runtime-dependency-overlay.py; do
        if [ ! -f "$libexec_dir/$helper_runtime" ]; then
            log_error "Required helper not found: $libexec_dir/$helper_runtime"
            return 1
        fi
    done

    for lib in apt.sh runtime-dependency-policy.sh runtime-dependency-overlay.sh runtime-dependency-queue.sh dns.sh firewall.sh browser.sh services.sh rollback.sh; do
        if [ ! -f "$lib_dir/$lib" ]; then
            log_error "Required library not found: $lib_dir/$lib"
            return 1
        fi

        # shellcheck disable=SC1090  # Dynamic source path is intentional
        source "$lib_dir/$lib"
    done

    return 0
}
