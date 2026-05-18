#!/bin/bash

################################################################################
# browser-native-host.sh - Browser integration and native host helpers
################################################################################

install_browser_integrations() {
    local ext_source="${1:-$INSTALL_DIR/firefox-extension}"
    local release_source="${2:-$INSTALL_DIR/firefox-release}"
    local install_native_host_enabled=false
    local firefox_best_effort=false
    local chromium_best_effort=true
    local native_host_best_effort=false
    local chromium_ext_id=""

    shift 2 || true

    while [ $# -gt 0 ]; do
        case "$1" in
            --native-host) install_native_host_enabled=true ;;
            --skip-native-host) install_native_host_enabled=false ;;
            --firefox-best-effort) firefox_best_effort=true ;;
            --firefox-required) firefox_best_effort=false ;;
            --chromium-best-effort) chromium_best_effort=true ;;
            --chromium-required) chromium_best_effort=false ;;
            --native-host-best-effort) native_host_best_effort=true ;;
            --native-host-required) native_host_best_effort=false ;;
            *)
                log "⚠ Unknown browser integration option: $1"
                return 1
                ;;
        esac
        shift
    done

    if ! install_firefox_extension "$ext_source" "$release_source"; then
        if [ "$firefox_best_effort" = true ]; then
            echo "⚠ Firefox extension not installed (can retry later)"
        else
            return 1
        fi
    fi

    if install_chromium_extension "$ext_source"; then
        chromium_ext_id="$(cat "$(get_chromium_extension_id_file)" 2>/dev/null || true)"
    else
        if [ "$chromium_best_effort" = true ]; then
            echo "⚠ Chrome/Edge extension not installed (can retry later)"
        else
            return 1
        fi
    fi

    if [ "$install_native_host_enabled" = true ]; then
        if ! install_native_host "$ext_source/native" "$chromium_ext_id"; then
            if [ "$native_host_best_effort" = true ]; then
                echo "⚠ Native host not installed (can retry later)"
            else
                return 1
            fi
        fi
    fi

    return 0
}

render_firefox_native_host_manifest() {
    local manifest_template="$1"
    local firefox_manifest_path="$2"
    local native_host_path="$3"

    if [ ! -f "$manifest_template" ]; then
        log "⚠ Native host manifest template not found: $manifest_template"
        return 1
    fi

    sed "s|/usr/local/bin/openpath-native-host.py|$native_host_path|g" \
        "$manifest_template" > "$firefox_manifest_path"
}

write_chromium_native_host_manifest() {
    local manifest_path="$1"
    local native_host_path="$2"
    local chromium_origin="$3"

    cat > "$manifest_path" << EOF
{
    "name": "$OPENPATH_FIREFOX_NATIVE_HOST_NAME",
    "description": "OpenPath System Native Messaging Host",
    "path": "$native_host_path",
    "type": "stdio",
    "allowed_origins": ["$chromium_origin"]
}
EOF
}

install_native_host() {
    local native_source="${1:-$INSTALL_DIR/firefox-extension/native}"
    local chromium_ext_id="${2:-}"
    local native_manifest_dir
    native_manifest_dir="$(get_firefox_native_host_dir)"
    local native_script_dir
    native_script_dir="$(get_native_host_install_dir)"
    local native_host_path="$native_script_dir/$OPENPATH_NATIVE_HOST_SCRIPT_NAME"
    local firefox_manifest_template="$native_source/$OPENPATH_FIREFOX_NATIVE_HOST_FILENAME"
    local firefox_manifest_path="$native_manifest_dir/$OPENPATH_FIREFOX_NATIVE_HOST_FILENAME"

    if [ ! -d "$native_source" ]; then
        log "⚠ Native host directory not found: $native_source"
        return 1
    fi

    log "Installing native messaging host..."

    mkdir -p "$native_manifest_dir" "$native_script_dir"
    cp "$native_source/$OPENPATH_NATIVE_HOST_SCRIPT_NAME" "$native_host_path"
    chmod +x "$native_host_path"

    if ! render_firefox_native_host_manifest \
        "$firefox_manifest_template" \
        "$firefox_manifest_path" \
        "$native_host_path"; then
        return 1
    fi

    if [ -n "$chromium_ext_id" ]; then
        local chromium_origin="chrome-extension://$chromium_ext_id/"
        local chromium_manifest_dirs=(
            "$(get_chromium_native_host_dir)"
            "$(get_chrome_native_host_dir)"
            "$(get_edge_native_host_dir)"
        )

        for manifest_dir in "${chromium_manifest_dirs[@]}"; do
            mkdir -p "$manifest_dir"
            write_chromium_native_host_manifest \
                "$manifest_dir/$OPENPATH_CHROMIUM_NATIVE_HOST_FILENAME" \
                "$native_host_path" \
                "$chromium_origin"
        done
    fi

    log "✓ Native messaging host installed"
    return 0
}

remove_firefox_extension() {
    local ext_id="$FIREFOX_MANAGED_EXTENSION_ID"
    local firefox_app_id="{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
    local ext_dir="/usr/share/mozilla/extensions/$firefox_app_id/$ext_id"

    log "Removing Firefox extension..."

    rm -rf "$ext_dir" 2>/dev/null || true

    if [ -f "$FIREFOX_POLICIES" ]; then
        mutate_firefox_policies "remove_managed_extension" "$ext_id"
    fi

    rm -f "$(get_firefox_native_host_dir)/$OPENPATH_FIREFOX_NATIVE_HOST_FILENAME" 2>/dev/null || true
    rm -f "$(get_chromium_native_host_dir)/$OPENPATH_CHROMIUM_NATIVE_HOST_FILENAME" 2>/dev/null || true
    rm -f "$(get_chrome_native_host_dir)/$OPENPATH_CHROMIUM_NATIVE_HOST_FILENAME" 2>/dev/null || true
    rm -f "$(get_edge_native_host_dir)/$OPENPATH_CHROMIUM_NATIVE_HOST_FILENAME" 2>/dev/null || true
    rm -f "$(get_native_host_install_dir)/$OPENPATH_NATIVE_HOST_SCRIPT_NAME" 2>/dev/null || true

    local chromium_ext_id_file
    chromium_ext_id_file="$(get_chromium_extension_id_file)"
    if [ -f "$chromium_ext_id_file" ]; then
        local chromium_ext_id
        chromium_ext_id="$(cat "$chromium_ext_id_file" 2>/dev/null || true)"
        if [ -n "$chromium_ext_id" ]; then
            rm -f "$(get_chrome_external_extensions_dir)/$chromium_ext_id.json" 2>/dev/null || true
            rm -f "$(get_edge_external_extensions_dir)/$chromium_ext_id.json" 2>/dev/null || true
        fi
    fi

    rm -rf "$(get_chromium_extension_artifacts_dir)" 2>/dev/null || true

    local firefox_dir
    firefox_dir=$(detect_firefox_dir 2>/dev/null)
    if [ -n "$firefox_dir" ]; then
        rm -f "$firefox_dir/defaults/pref/autoconfig.js" 2>/dev/null || true
        rm -f "$firefox_dir/mozilla.cfg" 2>/dev/null || true
    fi

    log "✓ Firefox extension removed"
}
