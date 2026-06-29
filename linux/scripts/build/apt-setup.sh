#!/bin/bash
################################################################################
# apt-setup.sh - Set up OpenPath System APT repository on a client machine
#
# Usage (one-liner install):
#   # Stable (recommended):
#   curl -fsSL https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt/apt-setup.sh | sudo bash
#
#   # Unstable (development builds):
#   curl -fsSL https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt/apt-setup.sh | sudo bash -s -- --unstable
#
# After running:
#   sudo apt install openpath-dnsmasq
################################################################################

set -euo pipefail

# Configuration
REPO_URL="${OPENPATH_APT_REPO_URL:-https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt}"
GPG_KEY_URL="$REPO_URL/pubkey.gpg"
KEYRING_PATH="/usr/share/keyrings/openpath.gpg"
SOURCES_PATH="/etc/apt/sources.list.d/openpath.list"
OPENPATH_APT_MIRRORS="${OPENPATH_APT_MIRRORS:-http://azure.archive.ubuntu.com/ubuntu http://archive.ubuntu.com/ubuntu http://mirrors.edge.kernel.org/ubuntu}"
OPENPATH_APT_RETRIES="${OPENPATH_APT_RETRIES:-2}"
OPENPATH_APT_UPDATE_TIMEOUT_SECONDS="${OPENPATH_APT_UPDATE_TIMEOUT_SECONDS:-45}"
OPENPATH_APT_CONNECT_TIMEOUT_SECONDS="${OPENPATH_APT_CONNECT_TIMEOUT_SECONDS:-10}"
OPENPATH_APT_CONF_FILE="${OPENPATH_APT_CONF_FILE:-/etc/apt/apt.conf.d/80openpath-network-retries}"

# Default to stable suite
SUITE="stable"

openpath_apt_attempts() {
    case "$OPENPATH_APT_RETRIES" in
        ''|*[!0-9]*|0)
            printf '%s\n' 2
            ;;
        *)
            printf '%s\n' "$OPENPATH_APT_RETRIES"
            ;;
    esac
}

configure_apt_resilience() {
    mkdir -p "$(dirname "$OPENPATH_APT_CONF_FILE")" 2>/dev/null || return 0

    cat > "$OPENPATH_APT_CONF_FILE" 2>/dev/null <<EOF || true
Acquire::Retries "$(openpath_apt_attempts)";
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "$OPENPATH_APT_CONNECT_TIMEOUT_SECONDS";
Acquire::https::Timeout "$OPENPATH_APT_CONNECT_TIMEOUT_SECONDS";
Acquire::http::No-Cache "true";
Acquire::https::No-Cache "true";
Acquire::http::Max-Age "0";
Acquire::https::Max-Age "0";
APT::Get::Assume-Yes "true";
DPkg::Lock::Timeout "120";
EOF
}

reset_apt_package_indexes() {
    apt-get clean >/dev/null 2>&1 || true
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    mkdir -p /var/lib/apt/lists/partial 2>/dev/null || true
}

rewrite_ubuntu_sources_for_mirror() {
    local mirror="${1%/}"
    local source_file

    [ -n "$mirror" ] || return 0

    for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$source_file" ] || continue
        [ -w "$source_file" ] || continue
        sed -i -E \
            -e "s#https?://([a-z]{2}\\.)?archive\\.ubuntu\\.com/ubuntu/?#${mirror}#g" \
            -e "s#https?://azure\\.archive\\.ubuntu\\.com/ubuntu/?#${mirror}#g" \
            -e "s#https?://security\\.ubuntu\\.com/ubuntu/?#${mirror}#g" \
            -e "s#https?://mirrors\\.edge\\.kernel\\.org/ubuntu/?#${mirror}#g" \
            "$source_file"
    done
}

run_apt_command_with_timeout() {
    local timeout_seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" "$@"
        return $?
    fi

    "$@"
}

openpath_apt_update_output_failed() {
    local output_file="$1"

    grep -Eqi \
        'Failed to fetch|Some index files failed to download|Temporary failure resolving|Could not connect|Connection timed out|Could not resolve|Hash Sum mismatch|Network is unreachable' \
        "$output_file"
}

apt_update_with_retry() {
    local attempt
    local mirror
    local max_attempts
    local output_file

    max_attempts="$(openpath_apt_attempts)"
    configure_apt_resilience

    for mirror in $OPENPATH_APT_MIRRORS; do
        rewrite_ubuntu_sources_for_mirror "$mirror"

        for attempt in $(seq 1 "$max_attempts"); do
            reset_apt_package_indexes

            output_file="$(mktemp)"
            if run_apt_command_with_timeout "$OPENPATH_APT_UPDATE_TIMEOUT_SECONDS" apt-get update -qq >"$output_file" 2>&1; then
                if ! openpath_apt_update_output_failed "$output_file"; then
                    rm -f "$output_file"
                    return 0
                fi
            fi

            [ -s "$output_file" ] && cat "$output_file"
            rm -f "$output_file"

            if [ "$attempt" -lt "$max_attempts" ]; then
                echo "  ! apt-get update failed with ${mirror} (attempt ${attempt}/${max_attempts}); retrying..."
                sleep "$attempt"
            fi
        done

        echo "  ! apt-get update could not use ${mirror}; trying next mirror..."
    done

    echo "ERROR: apt-get update failed after all configured mirrors"
    return 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --unstable)
            SUITE="unstable"
            shift
            ;;
        --stable)
            SUITE="stable"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--stable|--unstable]"
            exit 1
            ;;
    esac
done

echo "=============================================="
echo "  OpenPath System APT Repository Setup"
echo "=============================================="
echo ""
echo "  Suite: $SUITE"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Step 1: Download and install GPG key
echo "[1/3] Downloading GPG key..."
if command -v curl &> /dev/null; then
    curl -fsSL "$GPG_KEY_URL" | gpg --batch --yes --dearmor -o "$KEYRING_PATH"
elif command -v wget &> /dev/null; then
    wget -qO- "$GPG_KEY_URL" | gpg --batch --yes --dearmor -o "$KEYRING_PATH"
else
    echo "ERROR: curl or wget required"
    exit 1
fi
chmod 644 "$KEYRING_PATH"
echo "  ✓ GPG key installed"

# Step 2: Add repository to sources.list
echo "[2/3] Adding repository ($SUITE)..."
cat > "$SOURCES_PATH" << EOF
# OpenPath System APT Repository
# https://github.com/balejosg/openpath
# Suite: $SUITE
deb [signed-by=$KEYRING_PATH] $REPO_URL $SUITE main
EOF
echo "  ✓ Repository added"

# Step 3: Update package lists
echo "[3/3] Updating package lists..."
apt_update_with_retry

echo ""
echo "=============================================="
echo "  ✓ Repository configured successfully!"
echo "=============================================="
echo ""
echo "To install the openpath system:"
echo "  sudo apt install openpath-dnsmasq"
echo ""
if [ "$SUITE" = "unstable" ]; then
    echo "⚠️  You are using the UNSTABLE track."
    echo "   Development builds may contain bugs."
    echo "   To switch to stable: re-run with --stable"
    echo ""
fi
echo "To remove:"
echo "  sudo apt remove openpath-dnsmasq     # Keep configuration"
echo "  sudo apt purge openpath-dnsmasq      # Remove everything"
echo ""
