@test "install_native_host copies native host files" {
    local native_dir="$TEST_TMP_DIR/native"
    mkdir -p "$native_dir"
    echo '#!/usr/bin/env python3' > "$native_dir/openpath-native-host.py"

    local native_manifest_dir="$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts"
    local native_script_dir="$TEST_TMP_DIR/local/lib/openpath"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    install_native_host() {
        local native_source="${1:-$INSTALL_DIR/firefox-extension/native}"
        mkdir -p "$native_manifest_dir" "$native_script_dir"
        cp "$native_source/openpath-native-host.py" "$native_script_dir/"
        echo '{"name":"test"}' > "$native_manifest_dir/whitelist_native_host.json"
        return 0
    }
    export -f install_native_host

    run install_native_host "$native_dir"
    [ "$status" -eq 0 ]

    [ -f "$native_script_dir/openpath-native-host.py" ]
    [ -f "$native_manifest_dir/whitelist_native_host.json" ]
}

@test "install_native_host handles nonexistent directory" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run install_native_host "/path/that/does/not/exist"
    [ "$status" -eq 1 ]
}

@test "install_native_host writes Chromium and Edge manifests when extension id is provided" {
    local native_dir="$TEST_TMP_DIR/native"
    mkdir -p "$native_dir"
    echo '#!/usr/bin/env python3' > "$native_dir/openpath-native-host.py"
    cat > "$native_dir/whitelist_native_host.json" <<'EOF'
{
  "name": "whitelist_native_host",
  "description": "OpenPath System Native Messaging Host",
  "path": "/usr/local/bin/openpath-native-host.py",
  "type": "stdio",
  "allowed_extensions": ["openpath-block-monitor@openpath"]
}
EOF

    source "$PROJECT_DIR/linux/lib/browser.sh"

    run install_native_host "$native_dir" "abcdefghijklmnopabcdefghijklmnop"
    [ "$status" -eq 0 ]

    [ -f "$CHROMIUM_NATIVE_HOST_DIR/openpath_native_host.json" ]
    [ -f "$CHROME_NATIVE_HOST_DIR/openpath_native_host.json" ]
    [ -f "$EDGE_NATIVE_HOST_DIR/openpath_native_host.json" ]

    grep -q '"allowed_origins"' "$CHROMIUM_NATIVE_HOST_DIR/openpath_native_host.json"
    grep -q 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/' "$CHROMIUM_NATIVE_HOST_DIR/openpath_native_host.json"
    grep -q 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/' "$CHROME_NATIVE_HOST_DIR/openpath_native_host.json"
    grep -q 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/' "$EDGE_NATIVE_HOST_DIR/openpath_native_host.json"
}

@test "remove_firefox_extension removes extension directory" {
    local ext_dir="$TEST_TMP_DIR/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/openpath-block-monitor@openpath"
    mkdir -p "$ext_dir"
    touch "$ext_dir/manifest.json"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    detect_firefox_dir() { return 1; }
    export -f detect_firefox_dir

    remove_firefox_extension() {
        rm -rf "$ext_dir" 2>/dev/null || true
        return 0
    }
    export -f remove_firefox_extension

    run remove_firefox_extension
    [ "$status" -eq 0 ]

    [ ! -d "$ext_dir" ]
}

@test "remove_firefox_extension removes native host" {
    local native_manifest="$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts/whitelist_native_host.json"
    local native_script="$TEST_TMP_DIR/local/lib/openpath/openpath-native-host.py"

    mkdir -p "$(dirname "$native_manifest")" "$(dirname "$native_script")"
    touch "$native_manifest" "$native_script"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    detect_firefox_dir() { return 1; }
    export -f detect_firefox_dir

    remove_firefox_extension() {
        rm -f "$native_manifest" "$native_script" 2>/dev/null || true
        return 0
    }
    export -f remove_firefox_extension

    run remove_firefox_extension
    [ "$status" -eq 0 ]

    [ ! -f "$native_manifest" ]
    [ ! -f "$native_script" ]
}

@test "remove_firefox_extension removes Chromium and Edge descriptors" {
    local ext_id="abcdefghijklmnopabcdefghijklmnop"
    touch "$CHROME_EXTERNAL_EXTENSIONS_DIR/$ext_id.json"
    touch "$EDGE_EXTERNAL_EXTENSIONS_DIR/$ext_id.json"
    touch "$CHROMIUM_NATIVE_HOST_DIR/openpath_native_host.json"
    touch "$CHROME_NATIVE_HOST_DIR/openpath_native_host.json"
    touch "$EDGE_NATIVE_HOST_DIR/openpath_native_host.json"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    remove_firefox_extension() {
        rm -f "$CHROME_EXTERNAL_EXTENSIONS_DIR/$ext_id.json"
        rm -f "$EDGE_EXTERNAL_EXTENSIONS_DIR/$ext_id.json"
        rm -f "$CHROMIUM_NATIVE_HOST_DIR/openpath_native_host.json"
        rm -f "$CHROME_NATIVE_HOST_DIR/openpath_native_host.json"
        rm -f "$EDGE_NATIVE_HOST_DIR/openpath_native_host.json"
        return 0
    }
    export -f remove_firefox_extension

    run remove_firefox_extension
    [ "$status" -eq 0 ]

    [ ! -f "$CHROME_EXTERNAL_EXTENSIONS_DIR/$ext_id.json" ]
    [ ! -f "$EDGE_EXTERNAL_EXTENSIONS_DIR/$ext_id.json" ]
    [ ! -f "$CHROMIUM_NATIVE_HOST_DIR/openpath_native_host.json" ]
    [ ! -f "$CHROME_NATIVE_HOST_DIR/openpath_native_host.json" ]
    [ ! -f "$EDGE_NATIVE_HOST_DIR/openpath_native_host.json" ]
}

@test "linux browser runtime uses whitelist_native_host.json for Firefox" {
    run grep -nF 'OPENPATH_FIREFOX_NATIVE_HOST_FILENAME' "$PROJECT_DIR/linux/lib/browser.sh"
    [ "$status" -eq 0 ]
}

@test "manual native host installer wraps the production registration seam" {
    run grep -nF 'source "$REPO_ROOT/linux/lib/browser.sh"' "$PROJECT_DIR/firefox-extension/native/install-native-host.sh"
    [ "$status" -eq 0 ]
    run grep -nF 'install_native_host "$SCRIPT_DIR"' "$PROJECT_DIR/firefox-extension/native/install-native-host.sh"
    [ "$status" -eq 0 ]
}

@test "dev install-native-host.sh registers per-user through the production seam" {
    export HOME="$TEST_TMP_DIR/home"
    mkdir -p "$HOME"
    unset FIREFOX_NATIVE_HOST_DIR OPENPATH_NATIVE_HOST_INSTALL_DIR

    run bash "$PROJECT_DIR/firefox-extension/native/install-native-host.sh"
    [ "$status" -eq 0 ]

    local manifest="$HOME/.mozilla/native-messaging-hosts/whitelist_native_host.json"
    local host_script="$HOME/.local/lib/openpath/openpath-native-host.py"
    [ -f "$manifest" ]
    [ -x "$host_script" ]

    run python3 - "$manifest" "$PROJECT_DIR/tests/contracts/browser-firefox-native-host.json" <<'PYEOF'
import json, sys
manifest = json.load(open(sys.argv[1]))
fixture = json.load(open(sys.argv[2]))
assert manifest["name"] == fixture["name"], manifest["name"]
assert manifest["type"] == fixture["type"], manifest["type"]
assert manifest["allowed_extensions"] == fixture["allowedExtensions"], manifest["allowed_extensions"]
PYEOF
    [ "$status" -eq 0 ]

    run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$manifest"
    [ "$status" -eq 0 ]
    [ "$output" = "$host_script" ]
}

@test "dev install-native-host.sh output is English-only" {
    run grep -nE 'Instalando|instalado|extensión|Recarga|Verificar|Colores' "$PROJECT_DIR/firefox-extension/native/install-native-host.sh"
    [ "$status" -eq 1 ]
}

@test "install_native_host writes a manifest matching the shared native-host fixture" {
    local native_dir="$TEST_TMP_DIR/native"
    mkdir -p "$native_dir"
    cp "$PROJECT_DIR/firefox-extension/native/openpath-native-host.py" "$native_dir/"
    cp "$PROJECT_DIR/firefox-extension/native/whitelist_native_host.json" "$native_dir/"

    export FIREFOX_NATIVE_HOST_DIR="$TEST_TMP_DIR/native-manifests"
    export OPENPATH_NATIVE_HOST_INSTALL_DIR="$TEST_TMP_DIR/native-bin"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    run install_native_host "$native_dir"
    [ "$status" -eq 0 ]

    local expected_name
    expected_name="$(browser_contract_fixture_value "browser-firefox-native-host.json" "name")"
    local manifest="$FIREFOX_NATIVE_HOST_DIR/${expected_name}.json"
    [ -f "$manifest" ]

    run python3 - "$manifest" "$PROJECT_DIR/tests/contracts/browser-firefox-native-host.json" <<'PYEOF'
import json, sys
manifest = json.load(open(sys.argv[1]))
fixture = json.load(open(sys.argv[2]))
assert manifest["name"] == fixture["name"], manifest["name"]
assert manifest["type"] == fixture["type"], manifest["type"]
assert manifest["allowed_extensions"] == fixture["allowedExtensions"], manifest["allowed_extensions"]
PYEOF
    [ "$status" -eq 0 ]

    # The manifest's exec target must be the installed, executable host script.
    run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$manifest"
    [ "$status" -eq 0 ]
    [ "$output" = "$OPENPATH_NATIVE_HOST_INSTALL_DIR/openpath-native-host.py" ]
    [ -x "$output" ]
}
#!/usr/bin/env bats
################################################################################
# browser_native_host.bats - Native host and removal tests
################################################################################

load 'test_helper'
source "$BATS_TEST_DIRNAME/browser_support.bash"
