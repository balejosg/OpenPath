#!/bin/bash

# Generate Chromium/Chrome policies
generate_chromium_policies() {
    log "Generating Chromium policies..."

    local dirs=(
        "$CHROMIUM_POLICIES_BASE"
        "/etc/chromium-browser/policies/managed"
        "/etc/opt/chrome/policies/managed"
    )

    # The managed extension id is persisted at install time. When present we
    # emit a non-removable ExtensionInstallForcelist entry so the extension
    # cannot be disabled from chrome://extensions.
    local managed_ext_id=""
    local ext_id_file
    ext_id_file="$(get_chromium_extension_id_file)"
    if [ -f "$ext_id_file" ]; then
        managed_ext_id="$(tr -d '\r\n' < "$ext_id_file" 2>/dev/null || true)"
    fi

    local forcelist_args=()
    if [ -n "$managed_ext_id" ]; then
        forcelist_args=(--extension-id "$managed_ext_id")
        if [ -n "${CHROMIUM_EXTENSION_UPDATE_URL:-}" ]; then
            forcelist_args+=(--extension-update-url "$CHROMIUM_EXTENSION_UPDATE_URL")
        fi
    fi

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"

        # browser-json.py write-chromium-policy
        OPENPATH_BLOCKED_PATHS="$(printf '%s\n' "${BLOCKED_PATHS[@]}")" \
        run_browser_json_helper \
            write-chromium-policy \
            --output "$dir/openpath.json" \
            "${forcelist_args[@]}"
    done

    log "✓ Chromium policies generated"
}

get_chrome_external_extensions_dir() {
    echo "${CHROME_EXTERNAL_EXTENSIONS_DIR:-/usr/share/google-chrome/extensions}"
}

get_edge_external_extensions_dir() {
    echo "${EDGE_EXTERNAL_EXTENSIONS_DIR:-/usr/share/microsoft-edge/extensions}"
}

get_chromium_native_host_dir() {
    echo "${CHROMIUM_NATIVE_HOST_DIR:-/etc/chromium/native-messaging-hosts}"
}

get_chrome_native_host_dir() {
    echo "${CHROME_NATIVE_HOST_DIR:-/etc/opt/chrome/native-messaging-hosts}"
}

get_edge_native_host_dir() {
    echo "${EDGE_NATIVE_HOST_DIR:-/etc/opt/edge/native-messaging-hosts}"
}

get_chromium_extension_artifacts_dir() {
    echo "${OPENPATH_CHROMIUM_EXTENSION_DIR:-$VAR_STATE_DIR/browser-extension}"
}

get_chromium_extension_id_file() {
    local artifacts_dir
    artifacts_dir="$(get_chromium_extension_artifacts_dir)"
    echo "$artifacts_dir/extension-id"
}

detect_chromium_packager() {
    local candidates=(
        google-chrome
        google-chrome-stable
        chromium-browser
        chromium
        microsoft-edge
        microsoft-edge-stable
        microsoft-edge-beta
        microsoft-edge-dev
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done

    return 1
}

get_extension_version() {
    local ext_source="$1"

    run_browser_json_helper \
        get-extension-version \
        --manifest "$ext_source/manifest.json"
}

prepare_chromium_extension_source() {
    local ext_source="$1"
    local package_dir="$2"

    rm -rf "$package_dir"
    mkdir -p "$package_dir"

    cp -r "$ext_source/dist" "$package_dir/"
    cp -r "$ext_source/popup" "$package_dir/"
    cp -r "$ext_source/icons" "$package_dir/"
    cp -r "$ext_source/blocked" "$package_dir/"

    # browser-json.py rewrite-chromium-manifest
    run_browser_json_helper \
        rewrite-chromium-manifest \
        --source-manifest "$ext_source/manifest.json" \
        --target-manifest "$package_dir/manifest.json"
}

derive_chromium_extension_id_from_key() {
    local key_path="$1"

    if [ ! -f "$key_path" ]; then
        return 1
    fi

    openssl rsa -pubout -outform DER -in "$key_path" 2>/dev/null | python3 -c '
import hashlib
import sys

public_key = sys.stdin.buffer.read()
if not public_key:
    raise SystemExit(1)

alphabet = "abcdefghijklmnop"
digest = hashlib.sha256(public_key).hexdigest()[:32]
print("".join(alphabet[int(char, 16)] for char in digest))
'
}

build_chromium_extension_artifacts() {
    local ext_source="$1"
    local artifacts_dir="${2:-$(get_chromium_extension_artifacts_dir)}"

    if [ ! -d "$ext_source" ]; then
        log "⚠ Extension directory not found: $ext_source"
        return 1
    fi

    local packager
    packager="$(detect_chromium_packager)" || {
        log "⚠ No Chromium-compatible browser detected for CRX packaging"
        return 1
    }

    mkdir -p "$artifacts_dir"

    local package_dir="$artifacts_dir/openpath-chromium-extension"
    local crx_path="$artifacts_dir/openpath-chromium-extension.crx"
    local key_path="$artifacts_dir/openpath-chromium-extension.pem"
    local version
    version="$(get_extension_version "$ext_source")"

    prepare_chromium_extension_source "$ext_source" "$package_dir"

    if [ -f "$key_path" ]; then
        "$packager" --pack-extension="$package_dir" --pack-extension-key="$key_path" >/dev/null 2>&1 || {
            log "⚠ Failed to package Chromium extension"
            rm -rf "$package_dir"
            return 1
        }
    else
        "$packager" --pack-extension="$package_dir" >/dev/null 2>&1 || {
            log "⚠ Failed to package Chromium extension"
            rm -rf "$package_dir"
            return 1
        }
    fi

    rm -rf "$package_dir"

    if [ ! -f "$crx_path" ] || [ ! -f "$key_path" ]; then
        log "⚠ Chromium extension artifacts were not created"
        return 1
    fi

    local ext_id
    ext_id="$(derive_chromium_extension_id_from_key "$key_path")" || {
        log "⚠ Failed to derive Chromium extension ID"
        return 1
    }

    cat << EOF
EXT_ID=$ext_id
CRX_PATH=$crx_path
VERSION=$version
EOF
}

install_chromium_extension_preferences() {
    local ext_id="$1"
    local crx_path="$2"
    local version="$3"

    if [ -z "$ext_id" ] || [ -z "$crx_path" ] || [ -z "$version" ]; then
        log "⚠ Missing Chromium extension metadata"
        return 1
    fi

    local chrome_dir
    chrome_dir="$(get_chrome_external_extensions_dir)"
    local edge_dir
    edge_dir="$(get_edge_external_extensions_dir)"

    for dir in "$chrome_dir" "$edge_dir"; do
        mkdir -p "$dir"
        cat > "$dir/$ext_id.json" << EOF
{
  "external_crx": "$crx_path",
  "external_version": "$version"
}
EOF
    done

    log "✓ Chromium extension descriptors installed"
    return 0
}

install_chromium_extension() {
    local ext_source="${1:-$INSTALL_DIR/firefox-extension}"
    local artifacts_dir
    artifacts_dir="$(get_chromium_extension_artifacts_dir)"

    local metadata
    metadata="$(build_chromium_extension_artifacts "$ext_source" "$artifacts_dir")" || return 1

    local ext_id=""
    local crx_path=""
    local version=""
    while IFS='=' read -r key value; do
        case "$key" in
            EXT_ID) ext_id="$value" ;;
            CRX_PATH) crx_path="$value" ;;
            VERSION) version="$value" ;;
        esac
    done <<< "$metadata"

    if [ -z "$ext_id" ] || [ -z "$crx_path" ] || [ -z "$version" ]; then
        log "⚠ Chromium extension metadata incomplete"
        return 1
    fi

    install_chromium_extension_preferences "$ext_id" "$crx_path" "$version" || return 1
    printf '%s\n' "$ext_id" > "$(get_chromium_extension_id_file)"

    log "✓ Chromium extension prepared ($ext_id)"
    return 0
}
