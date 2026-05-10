#!/bin/bash

################################################################################
# openpath-browser-setup.sh - Ensure Firefox + managed extension are configured
# Part of the OpenPath DNS system
################################################################################

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/openpath}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_browser_setup_source() {
    local install_source="$1"
    local package_source="$2"

    if [ -d "$install_source" ]; then
        printf '%s\n' "$install_source"
        return 0
    fi

    printf '%s\n' "$package_source"
}

FIREFOX_EXTENSION_SOURCE="${OPENPATH_BROWSER_SETUP_EXTENSION_SOURCE:-$(default_browser_setup_source "$INSTALL_DIR/firefox-extension" "/usr/share/openpath/firefox-extension")}"
FIREFOX_RELEASE_SOURCE="${OPENPATH_BROWSER_SETUP_RELEASE_SOURCE:-$(default_browser_setup_source "$INSTALL_DIR/firefox-release" "/usr/share/openpath/firefox-release")}"
FIREFOX_EXTENSION_ID="${OPENPATH_FIREFOX_EXTENSION_ID:-openpath-block-monitor@openpath}"
export FIREFOX_EXTENSION_SOURCE FIREFOX_RELEASE_SOURCE FIREFOX_EXTENSION_ID
FIREFOX_APP_ID="{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
export FIREFOX_APP_ID
FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="${OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS:-60}"
FIREFOX_EXTENSION_REGISTRATION_MIN_PROBES="${OPENPATH_FIREFOX_EXTENSION_REGISTRATION_MIN_PROBES:-3}"
# First-run managed extension downloads can land near the end of the probe on slow runners.
FIREFOX_ACTIVATION_PROBE_TIMEOUT_SECONDS="${OPENPATH_FIREFOX_ACTIVATION_PROBE_TIMEOUT_SECONDS:-60}"
export FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS FIREFOX_EXTENSION_REGISTRATION_MIN_PROBES FIREFOX_ACTIVATION_PROBE_TIMEOUT_SECONDS
INSTALL_FIREFOX_ONLY=false

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --install-firefox-only)
                INSTALL_FIREFOX_ONLY=true
                ;;
            --help|-h)
                echo "Usage: $0 [--install-firefox-only]"
                exit 0
                ;;
            *)
                echo "ERROR: unknown option: $1" >&2
                exit 1
                ;;
        esac
        shift
    done
}

load_common_runtime() {
    if [ -f "$INSTALL_DIR/lib/common.sh" ]; then
        # shellcheck source=/usr/local/lib/openpath/lib/common.sh
        source "$INSTALL_DIR/lib/common.sh"
        return 0
    fi

    if [ -f "$SCRIPT_DIR/../../lib/common.sh" ]; then
        # shellcheck source=../../lib/common.sh
        source "$SCRIPT_DIR/../../lib/common.sh"
        return 0
    fi

    echo "ERROR: common.sh not found" >&2
    exit 1
}

load_browser_runtime() {
    if [ -f "$INSTALL_DIR/lib/browser.sh" ]; then
        # shellcheck source=/usr/local/lib/openpath/lib/browser.sh
        source "$INSTALL_DIR/lib/browser.sh"
        return 0
    fi

    if [ -f "$SCRIPT_DIR/../../lib/browser.sh" ]; then
        # shellcheck source=../../lib/browser.sh
        source "$SCRIPT_DIR/../../lib/browser.sh"
        return 0
    fi

    log_error "Required browser runtime not found"
    exit 1
}

load_browser_request_readiness_runtime() {
    if declare -F collect_openpath_browser_request_readiness >/dev/null 2>&1; then
        return 0
    fi

    if [ -f "$INSTALL_DIR/lib/browser-request-readiness.sh" ]; then
        # shellcheck source=/usr/local/lib/openpath/lib/browser-request-readiness.sh
        source "$INSTALL_DIR/lib/browser-request-readiness.sh"
        return 0
    fi

    if [ -f "$SCRIPT_DIR/../../lib/browser-request-readiness.sh" ]; then
        # shellcheck source=../../lib/browser-request-readiness.sh
        source "$SCRIPT_DIR/../../lib/browser-request-readiness.sh"
        return 0
    fi

    log_error "Required browser request readiness runtime not found"
    exit 1
}

load_firefox_activation_plan_runtime() {
    if declare -F verify_firefox_extension_registered >/dev/null 2>&1; then
        return 0
    fi

    if [ -f "$INSTALL_DIR/lib/firefox-activation-plan.sh" ]; then
        # shellcheck source=/usr/local/lib/openpath/lib/firefox-activation-plan.sh
        source "$INSTALL_DIR/lib/firefox-activation-plan.sh"
        return 0
    fi

    if [ -f "$SCRIPT_DIR/../../lib/firefox-activation-plan.sh" ]; then
        # shellcheck source=../../lib/firefox-activation-plan.sh
        source "$SCRIPT_DIR/../../lib/firefox-activation-plan.sh"
        return 0
    fi

    log_error "Required Firefox activation plan runtime not found"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Browser setup must run as root"
        exit 1
    fi
}

resolve_firefox_extensions_root_dir() {
    if declare -F get_firefox_extensions_root >/dev/null 2>&1; then
        get_firefox_extensions_root
        return 0
    fi

    printf '%s\n' "${FIREFOX_EXTENSIONS_ROOT:-/usr/share/mozilla/extensions}"
}

resolve_firefox_binary_path() {
    local firefox_dir=""
    local candidate=""

    firefox_dir="$(detect_firefox_dir 2>/dev/null || true)"
    if [ -n "$firefox_dir" ]; then
        for candidate in "$firefox_dir/firefox" "$firefox_dir/firefox-bin"; do
            if [ -x "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    fi

    candidate="$(command -v firefox-esr 2>/dev/null || command -v firefox 2>/dev/null || true)"
    if [ -n "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

verify_firefox_setup() {
    local firefox_dir=""

    firefox_dir="$(detect_firefox_dir 2>/dev/null || true)"
    if [ -z "$firefox_dir" ]; then
        log_error "Firefox installation directory not found after browser setup"
        return 1
    fi

    require_openpath_browser_request_readiness || return 1
}

main() {
    parse_args "$@"
    load_common_runtime
    if ! load_libraries; then
        load_browser_runtime
    fi
    load_browser_request_readiness_runtime
    load_firefox_activation_plan_runtime
    require_root

    log "Ensuring Firefox is installed..."
    if ! install_firefox_esr; then
        log_error "Failed to install Firefox"
        exit 1
    fi

    if [ "$INSTALL_FIREFOX_ONLY" = true ]; then
        log "Firefox installation is ready"
        exit 0
    fi

    require_openpath_request_setup_complete "browser request setup"

    log "Ensuring browser integrations are configured..."
    if ! install_browser_integrations \
        "$FIREFOX_EXTENSION_SOURCE" \
        "$FIREFOX_RELEASE_SOURCE" \
        --native-host \
        --firefox-required \
        --chromium-best-effort \
        --native-host-required; then
        log_error "Failed to configure Firefox browser integrations"
        exit 1
    fi

    if ! verify_firefox_setup; then
        exit 1
    fi

    log "Firefox browser setup is ready"
}

main "$@"
