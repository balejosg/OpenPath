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
# install-native-host.sh - Dev-mode Firefox native messaging host install.
#
# Thin wrapper over the production Linux registration seam
# (install_native_host in linux/lib/browser-native-host.sh), scoped to the
# current user so no sudo is required. Production installs go through
# linux/install.sh / openpath-update.sh with the system paths instead.
################################################################################

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Per-user dev defaults. Production defaults are the system paths
# (/usr/lib/mozilla/native-messaging-hosts, /usr/local/lib/openpath).
export FIREFOX_NATIVE_HOST_DIR="${FIREFOX_NATIVE_HOST_DIR:-$HOME/.mozilla/native-messaging-hosts}"
export OPENPATH_NATIVE_HOST_INSTALL_DIR="${OPENPATH_NATIVE_HOST_INSTALL_DIR:-$HOME/.local/lib/openpath}"

# Minimal logger; the production caller gets log() from linux/lib/common.sh.
if ! declare -F log >/dev/null 2>&1; then
    log() { printf '%s\n' "$*"; }
fi

# shellcheck source=../../linux/lib/browser.sh
source "$REPO_ROOT/linux/lib/browser.sh"

echo "Installing Firefox native messaging host (dev mode, current user only)..."
install_native_host "$SCRIPT_DIR" ""

echo ""
echo "Native messaging host installed."
echo "  Manifest:    $FIREFOX_NATIVE_HOST_DIR/$OPENPATH_FIREFOX_NATIVE_HOST_FILENAME"
echo "  Host script: $OPENPATH_NATIVE_HOST_INSTALL_DIR/$OPENPATH_NATIVE_HOST_SCRIPT_NAME"
echo ""
echo "Next steps:"
echo "  1. Reload the extension in about:debugging"
echo "  2. Native-host-backed checks are then available from the extension popup"
