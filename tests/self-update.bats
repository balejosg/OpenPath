#!/usr/bin/env bats
################################################################################
# self-update.bats - Agent self-update hardening
# (lib/openpath-self-update-metadata.sh, lib/openpath-self-update-package.sh,
#  scripts/runtime/openpath-self-update.sh)
#
# Covers:
#   F-I: cross-origin downloadPath rejection + sha256 verification
#   F-J: compiled-in minimum-supported-version downgrade floor
#   F-L: unguessable root-owned scratch directories
################################################################################

load 'test_helper'

setup() {
    setup_std_lib_layout
    setup_mock_log
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_debug() { :; }
    export -f log_warn log_error log_debug
}

_source_metadata() {
    source "$PROJECT_DIR/linux/lib/openpath-self-update-metadata.sh"
}

_source_package() {
    source "$PROJECT_DIR/linux/lib/openpath-self-update-package.sh"
}

# ============== F-I: cross-origin download guard ==============

@test "download_url_matches_configured_origin accepts a same-origin absolute URL" {
    _source_metadata
    run download_url_matches_configured_origin \
        "https://api.example.com/api/agent/linux/packages/4.2.0" \
        "https://api.example.com"
    [ "$status" -eq 0 ]
}

@test "download_url_matches_configured_origin rejects a cross-origin absolute URL" {
    _source_metadata
    run download_url_matches_configured_origin \
        "https://evil.example.net/payload.deb" \
        "https://api.example.com"
    [ "$status" -eq 1 ]
}

@test "download_url_matches_configured_origin rejects when configured origin is empty" {
    _source_metadata
    run download_url_matches_configured_origin \
        "https://api.example.com/x.deb" \
        ""
    [ "$status" -eq 1 ]
}

@test "refresh_update_metadata rejects a manifest pointing the download at another origin" {
    _source_metadata

    # Minimal globals the function reads.
    API_URL_CONF="$TEST_TMP_DIR/api-url.conf"
    LINUX_AGENT_MANIFEST_PATH="/api/agent/linux/manifest"
    GITHUB_REPO="example/openpath"
    UPDATE_SOURCE=""
    LATEST_VERSION=""
    DOWNLOAD_URL=""
    MANIFEST_SHA256=""
    export OPENPATH_SELF_UPDATE_API="https://api.example.com/api/agent/linux/manifest"

    # Manifest advertises a downloadPath on a DIFFERENT origin.
    curl() {
        cat <<'JSON'
{"version":"4.2.0","downloadPath":"https://evil.example.net/openpath.deb"}
JSON
        return 0
    }
    export -f curl

    run refresh_update_metadata
    [ "$status" -ne 0 ]
    [[ "$output" == *"cross-origin"* ]]
}

@test "refresh_update_metadata accepts a same-origin relative downloadPath" {
    _source_metadata

    API_URL_CONF="$TEST_TMP_DIR/api-url.conf"
    LINUX_AGENT_MANIFEST_PATH="/api/agent/linux/manifest"
    GITHUB_REPO="example/openpath"
    UPDATE_SOURCE=""
    LATEST_VERSION=""
    DOWNLOAD_URL=""
    MANIFEST_SHA256=""
    MIN_SUPPORTED_VERSION=""
    MIN_DIRECT_UPGRADE_VERSION=""
    BRIDGE_VERSIONS=()
    export OPENPATH_SELF_UPDATE_API="https://api.example.com/api/agent/linux/manifest"

    curl() {
        cat <<'JSON'
{"version":"4.2.0","downloadPath":"/api/agent/linux/packages/4.2.0","sha256":"abc123"}
JSON
        return 0
    }
    export -f curl

    run refresh_update_metadata
    [ "$status" -eq 0 ]
    [[ "$output" != *"cross-origin"* ]]
}

# ============== F-I: sha256 verification ==============

@test "verify_downloaded_sha256 is a no-op when no manifest digest is present" {
    _source_package
    MANIFEST_SHA256=""
    local f="$TEST_TMP_DIR/pkg.deb"
    echo "data" > "$f"

    run verify_downloaded_sha256 "$f"
    [ "$status" -eq 0 ]
}

@test "verify_downloaded_sha256 passes on a matching digest" {
    _source_package
    local f="$TEST_TMP_DIR/pkg.deb"
    echo "data" > "$f"
    MANIFEST_SHA256=$(sha256sum "$f" | awk '{print $1}')

    run verify_downloaded_sha256 "$f"
    [ "$status" -eq 0 ]
}

@test "verify_downloaded_sha256 fails closed on a digest mismatch" {
    _source_package
    local f="$TEST_TMP_DIR/pkg.deb"
    echo "data" > "$f"
    MANIFEST_SHA256="0000000000000000000000000000000000000000000000000000000000000000"

    run verify_downloaded_sha256 "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mismatch"* ]]
}

@test "download_url_to_file rejects a package whose sha256 does not match the manifest" {
    _source_package
    DOWNLOAD_AUTH_HEADER=""
    MANIFEST_SHA256="deadbeef"

    # Mocks: curl writes a file, dpkg-deb treats it as a valid package.
    curl() {
        local out=""
        local prev=""
        for a in "$@"; do
            [ "$prev" = "-o" ] && out="$a"
            prev="$a"
        done
        echo "fake-deb" > "$out"
        return 0
    }
    export -f curl
    dpkg-deb() { return 0; }
    export -f dpkg-deb

    run download_url_to_file "https://api.example.com/pkg.deb" "$TEST_TMP_DIR/out.deb"
    [ "$status" -ne 0 ]
    # The corrupt/forged file is removed.
    [ ! -f "$TEST_TMP_DIR/out.deb" ]
}

# ============== F-J: compiled-in downgrade floor ==============

@test "self-update declares a readonly compiled-in minimum-supported-version constant" {
    grep -q 'readonly OPENPATH_COMPILED_MIN_SUPPORTED_VERSION' \
        "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
}

@test "self-update refuses an advertised version below the compiled-in floor" {
    # Source the entrypoint in source-only mode, then drive main() with mocks.
    export OPENPATH_SELF_UPDATE_SOURCE_ONLY=1
    export OPENPATH_COMPILED_MIN_SUPPORTED_VERSION="4.0.0"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    mkdir -p "$INSTALL_DIR"
    printf '4.1.0\n' > "$INSTALL_DIR/VERSION"

    source "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"

    # Manifest advertises a pre-hardening 3.0.0 build (below the 4.0.0 floor).
    refresh_update_metadata() {
        UPDATE_SOURCE="api-manifest"
        LATEST_VERSION="3.0.0"
        DOWNLOAD_URL="https://api.example.com/pkg.deb"
        MIN_SUPPORTED_VERSION="0.0.0"
        MIN_DIRECT_UPGRADE_VERSION="0.0.0"
        BRIDGE_VERSIONS=()
        UPDATE_SEQUENCE=()
        return 0
    }
    read_installed_version() { echo "4.1.0"; }

    run main --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"below the compiled-in minimum"* ]]
}

# ============== F-L: unguessable scratch directories ==============

@test "self-update uses mktemp -d for scratch dirs, not fixed /tmp paths" {
    grep -q 'mktemp -d' "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
    # The fixed predictable paths must be gone as assignments.
    ! grep -qE '^DOWNLOAD_DIR="/tmp/openpath-update"' \
        "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
    ! grep -qE '^BACKUP_DIR="/tmp/openpath-update-backup"' \
        "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
}

@test "ensure_update_workspace_dirs allocates per-run 0700 root-owned scratch dirs" {
    export OPENPATH_SELF_UPDATE_SOURCE_ONLY=1
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    mkdir -p "$INSTALL_DIR"
    export TMPDIR="$TEST_TMP_DIR/scratch"
    mkdir -p "$TMPDIR"

    source "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"

    ensure_update_workspace_dirs
    [ -d "$DOWNLOAD_DIR" ]
    [ -d "$BACKUP_DIR" ]
    # mktemp -d defaults to 0700.
    [ "$(stat -c '%a' "$DOWNLOAD_DIR")" = "700" ]
    [ "$DOWNLOAD_DIR" != "/tmp/openpath-update" ]
    # Idempotent: a second call keeps the same dirs.
    local first="$DOWNLOAD_DIR"
    ensure_update_workspace_dirs
    [ "$DOWNLOAD_DIR" = "$first" ]
}
