#!/bin/bash

# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.

################################################################################
# openpath-self-update.sh - Agent self-update mechanism
# Part of the OpenPath DNS system
################################################################################

set -euo pipefail

INSTALL_DIR="/usr/local/lib/openpath"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$INSTALL_DIR/lib/common.sh" ]; then
    # shellcheck source=/usr/local/lib/openpath/lib/common.sh
    source "$INSTALL_DIR/lib/common.sh"
elif [ -f "$SCRIPT_DIR/../../lib/common.sh" ]; then
    # shellcheck source=../../lib/common.sh
    source "$SCRIPT_DIR/../../lib/common.sh"
elif [ -f "/usr/local/lib/openpath/common.sh" ]; then
    # shellcheck source=/usr/local/lib/openpath/common.sh
    source "/usr/local/lib/openpath/common.sh"
else
    echo "ERROR: common.sh not found" >&2
    exit 1
fi

if [ -f "$INSTALL_DIR/lib/apt.sh" ]; then
    # shellcheck source=/usr/local/lib/openpath/lib/apt.sh
    source "$INSTALL_DIR/lib/apt.sh"
elif [ -f "$SCRIPT_DIR/../../lib/apt.sh" ]; then
    # shellcheck source=../../lib/apt.sh
    source "$SCRIPT_DIR/../../lib/apt.sh"
else
    echo "ERROR: apt.sh not found" >&2
    exit 1
fi

if [ -f "$INSTALL_DIR/lib/openpath-self-update-metadata.sh" ]; then
    # shellcheck source=/usr/local/lib/openpath/lib/openpath-self-update-metadata.sh
    source "$INSTALL_DIR/lib/openpath-self-update-metadata.sh"
    # shellcheck source=/usr/local/lib/openpath/lib/openpath-self-update-package.sh
    source "$INSTALL_DIR/lib/openpath-self-update-package.sh"
else
    # shellcheck source=../../lib/openpath-self-update-metadata.sh
    source "$SCRIPT_DIR/../../lib/openpath-self-update-metadata.sh"
    # shellcheck source=../../lib/openpath-self-update-package.sh
    source "$SCRIPT_DIR/../../lib/openpath-self-update-package.sh"
fi

# shellcheck disable=SC2034  # Consumed by sourced helper modules.
GITHUB_REPO="${OPENPATH_GITHUB_REPO:-balejosg/openpath}"
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
DOWNLOAD_DIR="/tmp/openpath-update"
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
BACKUP_DIR="/tmp/openpath-update-backup"
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
CURRENT_VERSION="${VERSION:-0.0.0}"
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
API_URL_CONF="${ETC_CONFIG_DIR}/api-url.conf"
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
LINUX_AGENT_MANIFEST_PATH="${OPENPATH_LINUX_AGENT_MANIFEST_PATH:-/api/agent/linux/manifest}"
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
PACKAGE_CACHE_DIR="${OPENPATH_AGENT_PACKAGE_CACHE_DIR:-$VAR_STATE_DIR/packages}"
LATEST_VERSION=""
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
DOWNLOAD_URL=""
MIN_SUPPORTED_VERSION="0.0.0"
MIN_DIRECT_UPGRADE_VERSION="0.0.0"
UPDATE_SOURCE="github-release"
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
DOWNLOAD_AUTH_HEADER=""
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
UPDATE_API_BASE_URL=""
# shellcheck disable=SC2034  # Consumed by sourced helper modules.
BRIDGE_VERSIONS=()
UPDATE_SEQUENCE=()

# shellcheck disable=SC2034  # Preserve list is consumed by the package helper module.
PRESERVE_FILES=(
    "/etc/openpath/api-url.conf"
    "/etc/openpath/whitelist-url.conf"
    "/etc/openpath/classroom.conf"
    "/etc/openpath/classroom-id.conf"
    "/etc/openpath/machine-name.conf"
    "/etc/openpath/api-secret.conf"
    "/etc/openpath/health-api-url.conf"
    "/etc/openpath/health-api-secret.conf"
    "/etc/openpath/overrides.conf"
    "/etc/openpath/config-overrides.conf"
    "/var/lib/openpath/whitelist.txt"
    "/var/lib/openpath/whitelist-domains.conf"
    "/var/lib/openpath/resolv.conf.backup"
    "/var/lib/openpath/resolv.conf.symlink.backup"
    "/var/lib/openpath/integrity.sha256"
)

usage() {
    echo "Usage: openpath self-update [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --check    Only check for updates, don't install"
    echo "  --force    Force reinstall even if same version"
    echo "  --help     Show this help"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: self-update must be run as root" >&2
        exit 1
    fi
}

main() {
    local mode="update"
    local current_version=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --check) mode="check" ;;
            --force) mode="force" ;;
            --help) usage; exit 0 ;;
            *) echo "Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
    done

    [ "$mode" != "check" ] && require_root

    current_version=$(read_installed_version)

    echo "OpenPath Self-Update"
    echo "  Current version: v${current_version}"
    echo ""

    echo "Checking for updates..."
    refresh_update_metadata || {
        echo "✗ Cannot check for updates (manifest unreachable or invalid)"
        exit 1
    }

    echo "  Source:          ${UPDATE_SOURCE}"
    echo "  Latest version:  v${LATEST_VERSION}"
    echo ""

    local cmp_result=0
    compare_versions "$LATEST_VERSION" "$current_version" || cmp_result=$?

    local min_support_result=0
    compare_versions "$current_version" "$MIN_SUPPORTED_VERSION" || min_support_result=$?
    if [ "$min_support_result" -eq 2 ]; then
        echo "✗ Your version (v) is below the minimum supported version for auto-update (v)"
        exit 1
    fi

    resolve_update_sequence "$current_version" "$LATEST_VERSION"

    local min_direct_result=0
    compare_versions "$current_version" "$MIN_DIRECT_UPGRADE_VERSION" || min_direct_result=$?
    if [ "$min_direct_result" -eq 2 ] && [ "${#UPDATE_SEQUENCE[@]}" -le 1 ]; then
        echo "✗ Your version (v) is below the minimum direct update version (v)"
        echo "  A bridge update or manual recovery is required."
        exit 1
    fi

    if [ "${#UPDATE_SEQUENCE[@]}" -gt 1 ]; then
        echo "  Bridge path:     v$(printf '%s' "${UPDATE_SEQUENCE[0]}")"
        local sequence_index=1
        while [ "$sequence_index" -lt "${#UPDATE_SEQUENCE[@]}" ]; do
            printf ' -> v%s' "${UPDATE_SEQUENCE[$sequence_index]}"
            sequence_index=$((sequence_index + 1))
        done
        echo ""
        echo ""
    fi

    case "$cmp_result" in
        0)
            if [ "$mode" = "force" ]; then
                echo "Same version installed. Forcing reinstall..."
            else
                echo "✓ You already have the latest version (v${current_version})"
                exit 0
            fi
            ;;
        1)
            echo "⬆ Update available: v${current_version} → v${LATEST_VERSION}"
            ;;
        2)
            if [ "$mode" = "force" ]; then
                echo "Current version is newer than release. Forcing reinstall..."
            else
                echo "✓ Your version (v) is newer than the latest release (v)"
                exit 0
            fi
            ;;
    esac

    if [ "$mode" = "check" ]; then
        exit 0
    fi

    local target_version=""
    for target_version in "${UPDATE_SEQUENCE[@]}"; do
        local sequence_cmp=0

        if [ "$mode" = "force" ] && [ "$target_version" = "$LATEST_VERSION" ]; then
            install_update "$target_version" "$current_version"
            current_version=$(read_installed_version)
            continue
        fi

        compare_versions "$target_version" "$current_version" || sequence_cmp=$?
        if [ "$sequence_cmp" -ne 1 ]; then
            continue
        fi

        install_update "$target_version" "$current_version"
        current_version=$(read_installed_version)
    done
}

if [ "${OPENPATH_SELF_UPDATE_SOURCE_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

main "$@"
