#!/bin/bash

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
# install.sh - Instalador del sistema dnsmasq URL Whitelist v3.5
#
# Este script instala y configura el sistema completo de whitelist DNS.
# Divide la funcionalidad en módulos para mejor mantenibilidad.
#
# Uso:
#   sudo ./install.sh
#   sudo ./install.sh --whitelist-url "https://tu-url.com/whitelist.txt"
#   sudo ./install.sh --unattended  (modo desatendido)
#   sudo ./install.sh --no-extension  (sin extensión Firefox)
#   sudo ./install.sh --skip-firefox  (omitir instalación de Firefox)
#   sudo ./install.sh --with-native-host  (incluir native messaging)
#   sudo ./install.sh --skip-preflight  (omitir validación previa)
#
################################################################################

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_SOURCE_DIR="$SCRIPT_DIR"
VERSION=$(cat "$INSTALLER_SOURCE_DIR/../VERSION" 2>/dev/null || echo "4.1.0")
ORIGINAL_ARGS=("$@")

# Directorios de instalación
INSTALL_DIR="/usr/local/lib/openpath"
SCRIPTS_DIR="/usr/local/bin"
CONFIG_DIR="/var/lib/openpath"

# No default URL - must be provided via --whitelist-url or configured in defaults.conf
DEFAULT_WHITELIST_URL=""

# Procesar argumentos
WHITELIST_URL="$DEFAULT_WHITELIST_URL"
UNATTENDED=false
INSTALL_EXTENSION=true
INSTALL_FIREFOX=true
INSTALL_NATIVE_HOST=false
SKIP_PREFLIGHT=false
VERBOSE=false
INSTALLER_STEP_TOTAL=15
HEALTH_API_URL=""
HEALTH_API_SECRET=""
CLASSROOM_NAME=""
API_URL=""
REGISTRATION_TOKEN=""

# shellcheck source=lib/progress.sh
source "$INSTALLER_SOURCE_DIR/lib/progress.sh"
# install-helpers.sh keeps installer progress wired through openpath_show_progress.
# shellcheck source=lib/install-helpers.sh
source "$INSTALLER_SOURCE_DIR/lib/install-helpers.sh"
# shellcheck source=lib/install-core-steps.sh
source "$INSTALLER_SOURCE_DIR/lib/install-core-steps.sh"
# shellcheck source=lib/install-runtime-steps.sh
source "$INSTALLER_SOURCE_DIR/lib/install-runtime-steps.sh"

while [[ $# -gt 0 ]]; do
    case $1 in
        --whitelist-url|--url)
            WHITELIST_URL="$2"
            shift 2
            ;;
        --health-api-url)
            HEALTH_API_URL="$2"
            shift 2
            ;;
        --health-api-secret)
            HEALTH_API_SECRET="$2"
            shift 2
            ;;
        --unattended)
            # shellcheck disable=SC2034  # Used in confirmation prompts
            UNATTENDED=true
            shift
            ;;
        --no-extension)
            INSTALL_EXTENSION=false
            shift
            ;;
        --skip-firefox)
            INSTALL_FIREFOX=false
            shift
            ;;
        --with-native-host)
            INSTALL_NATIVE_HOST=true
            shift
            ;;
        --skip-preflight)
            SKIP_PREFLIGHT=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --classroom)
            CLASSROOM_NAME="$2"
            shift 2
            ;;
        --api-url)
            API_URL="$2"
            shift 2
            ;;
        --registration-token)
            REGISTRATION_TOKEN="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Auto-generate API secret if classroom mode is configured but no secret provided
if [ -n "$CLASSROOM_NAME" ] && [ -n "$API_URL" ] && [ -z "$HEALTH_API_SECRET" ]; then
    # SECURITY: Disable trace before secret handling to prevent leaking in logs
    { set +x; } 2>/dev/null
    # Generate a random 32-character secret using cryptographic entropy
    HEALTH_API_SECRET=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
    log_notice "API Secret generated automatically for classroom mode"
    log_notice "   Secret will be saved to /etc/openpath/api-secret.conf"
    log_notice "   ACTION: Backup this file securely for reinstallation"
fi

# Validate registration token in classroom mode
if [ -n "$CLASSROOM_NAME" ] && [ -n "$API_URL" ]; then
    if [ -z "$REGISTRATION_TOKEN" ]; then
        echo "❌ Error: --registration-token is required in classroom mode"
        echo "   Get the registration token from the central server administrator"
        exit 1
    fi
    
    log_verbose "Validating registration token..."
    VALIDATE_RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"token\":\"$REGISTRATION_TOKEN\"}" \
        "$API_URL/api/setup/validate-token" 2>/dev/null || echo "{\"valid\":false}")
    
    if ! echo "$VALIDATE_RESPONSE" | grep -q '"valid":true'; then
        echo "❌ Error: Invalid registration token"
        echo "   Verify the token with the central server administrator"
        exit 1
    fi
    log_verbose "Registration token validated"
fi

# Auto-elevación con sudo
if [ "$EUID" -ne 0 ]; then
    log_notice "Elevating permissions with sudo..."
    exec sudo "$0" "${ORIGINAL_ARGS[@]}"
fi

if [ "$VERBOSE" = true ]; then
    echo "======================================================"
    echo "  dnsmasq URL Whitelist System v$VERSION - Installation"
    echo "======================================================"
    echo ""
    echo "URL Whitelist: $WHITELIST_URL"
    echo "Firefox extension: $INSTALL_EXTENSION"
    echo "Firefox: $INSTALL_FIREFOX"
    if [ -n "$CLASSROOM_NAME" ]; then
        echo "Classroom mode: $CLASSROOM_NAME"
        echo "API URL: $API_URL"
    fi
    echo ""
else
    log_notice "Installing OpenPath DNS v$VERSION..."
fi

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    if [ "$SKIP_PREFLIGHT" = true ]; then
        log_verbose ""
        log_verbose "[Preflight] Skipped by --skip-preflight"
    else
        show_progress 0 "$INSTALLER_STEP_TOTAL" "Validating prerequisites"
        if [ "$VERBOSE" = true ]; then
            run_pre_install_validation
        else
            run_quietly run_pre_install_validation
        fi
    fi

    run_installer_step 1 "$INSTALLER_STEP_TOTAL" "Installing libraries" step_install_libraries
    run_installer_step 2 "$INSTALLER_STEP_TOTAL" "Installing dependencies" step_install_dependencies
    run_installer_step 3 "$INSTALLER_STEP_TOTAL" "Detecting primary DNS" step_detect_dns
    run_installer_step 4 "$INSTALLER_STEP_TOTAL" "Releasing port 53" step_free_port_53
    run_installer_step 5 "$INSTALLER_STEP_TOTAL" "Installing scripts" step_install_scripts
    run_installer_step 6 "$INSTALLER_STEP_TOTAL" "Configuring sudo permissions" step_configure_sudoers
    run_installer_step 7 "$INSTALLER_STEP_TOTAL" "Creating systemd services" step_create_services
    run_installer_step 8 "$INSTALLER_STEP_TOTAL" "Configuring DNS" step_configure_dns
    run_installer_step 9 "$INSTALLER_STEP_TOTAL" "Configuring dnsmasq" step_configure_dnsmasq
    run_installer_step 10 "$INSTALLER_STEP_TOTAL" "Installing Firefox" step_install_firefox
    run_installer_step 11 "$INSTALLER_STEP_TOTAL" "Verifying browser integrations" step_apply_policies
    run_installer_step 12 "$INSTALLER_STEP_TOTAL" "Installing browser extensions" step_install_extension
    run_installer_step 13 "$INSTALLER_STEP_TOTAL" "Enabling services" step_enable_services
    run_installer_step 14 "$INSTALLER_STEP_TOTAL" "Running smoke tests" run_smoke_tests
    run_installer_step 15 "$INSTALLER_STEP_TOTAL" "Registering machine" run_classroom_registration
    print_summary
}

main
