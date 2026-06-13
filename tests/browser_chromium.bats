@test "generate_chromium_policies creates directories" {
    BLOCKED_PATHS=("example.com/ads")

    source "$PROJECT_DIR/linux/lib/browser.sh"

    run generate_chromium_policies
    [ "$status" -eq 0 ]
    [ -d "$CHROMIUM_POLICIES_BASE" ]
}

@test "generate_chromium_policies creates policies file" {
    BLOCKED_PATHS=("example.com/ads")

    source "$PROJECT_DIR/linux/lib/browser.sh"

    run generate_chromium_policies
    [ "$status" -eq 0 ]
    [ -f "$CHROMIUM_POLICIES_BASE/openpath.json" ]
}

@test "generate_chromium_policies JSON contains URLBlocklist" {
    BLOCKED_PATHS=("example.com/ads")

    source "$PROJECT_DIR/linux/lib/browser.sh"

    run generate_chromium_policies

    grep -q "URLBlocklist" "$CHROMIUM_POLICIES_BASE/openpath.json"
}

@test "install_browser_integrations keeps Chromium best-effort while wiring native host with extension id" {
    local ext_dir="$TEST_TMP_DIR/firefox-extension"
    local release_dir="$TEST_TMP_DIR/firefox-release"
    mkdir -p "$ext_dir" "$release_dir"
    export OPENPATH_CHROMIUM_EXTENSION_DIR="$TEST_TMP_DIR/browser-extension"
    mkdir -p "$OPENPATH_CHROMIUM_EXTENSION_DIR"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    install_firefox_extension() {
        echo "install_firefox_extension $1 $2"
        return 0
    }
    install_chromium_extension() {
        echo "install_chromium_extension $1"
        printf '%s\n' "abcdefghijklmnopabcdefghijklmnop" > "$(get_chromium_extension_id_file)"
        return 0
    }
    install_native_host() {
        echo "install_native_host $1 $2"
        return 0
    }
    export -f install_firefox_extension install_chromium_extension install_native_host

    run install_browser_integrations \
        "$ext_dir" \
        "$release_dir" \
        --native-host \
        --firefox-required \
        --chromium-best-effort
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_firefox_extension $ext_dir $release_dir"* ]]
    [[ "$output" == *"install_chromium_extension $ext_dir"* ]]
    [[ "$output" == *"install_native_host $ext_dir/native abcdefghijklmnopabcdefghijklmnop"* ]]
}

@test "install_browser_integrations warns and continues when Chromium install is best-effort" {
    local ext_dir="$TEST_TMP_DIR/firefox-extension"
    local release_dir="$TEST_TMP_DIR/firefox-release"
    mkdir -p "$ext_dir" "$release_dir"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    install_firefox_extension() { return 0; }
    install_chromium_extension() { return 1; }
    install_native_host() { echo "install_native_host $1 $2"; return 0; }
    export -f install_firefox_extension install_chromium_extension install_native_host

    run install_browser_integrations \
        "$ext_dir" \
        "$release_dir" \
        --native-host \
        --firefox-required \
        --chromium-best-effort \
        --native-host-best-effort
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ Chrome/Edge extension not installed (can retry later)"* ]]
    [[ "$output" == *"install_native_host $ext_dir/native"* ]]
}

@test "install_chromium_extension_preferences writes Chrome and Edge descriptors" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run install_chromium_extension_preferences \
        "abcdefghijklmnopabcdefghijklmnop" \
        "$TEST_TMP_DIR/packages/openpath.crx" \
        "1.2.3"
    [ "$status" -eq 0 ]

    [ -f "$CHROME_EXTERNAL_EXTENSIONS_DIR/abcdefghijklmnopabcdefghijklmnop.json" ]
    [ -f "$EDGE_EXTERNAL_EXTENSIONS_DIR/abcdefghijklmnopabcdefghijklmnop.json" ]

    grep -q '"external_crx"' "$CHROME_EXTERNAL_EXTENSIONS_DIR/abcdefghijklmnopabcdefghijklmnop.json"
    grep -q '"1.2.3"' "$CHROME_EXTERNAL_EXTENSIONS_DIR/abcdefghijklmnopabcdefghijklmnop.json"
    grep -q '"external_crx"' "$EDGE_EXTERNAL_EXTENSIONS_DIR/abcdefghijklmnopabcdefghijklmnop.json"
    grep -q '"1.2.3"' "$EDGE_EXTERNAL_EXTENSIONS_DIR/abcdefghijklmnopabcdefghijklmnop.json"
}

@test "install_chromium_extension installs descriptors from generated artifacts" {
    local ext_dir="$TEST_TMP_DIR/firefox-extension"
    mkdir -p "$ext_dir"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    build_chromium_extension_artifacts() {
        mkdir -p "$TEST_TMP_DIR/packages"
        touch "$TEST_TMP_DIR/packages/openpath.crx"
        cat << EOF
EXT_ID=abcdefghijklmnopabcdefghijklmnop
CRX_PATH=$TEST_TMP_DIR/packages/openpath.crx
VERSION=1.2.3
EOF
        return 0
    }
    export -f build_chromium_extension_artifacts

    run install_chromium_extension "$ext_dir"
    [ "$status" -eq 0 ]

    [ -f "$CHROME_EXTERNAL_EXTENSIONS_DIR/abcdefghijklmnopabcdefghijklmnop.json" ]
    [ -f "$EDGE_EXTERNAL_EXTENSIONS_DIR/abcdefghijklmnopabcdefghijklmnop.json" ]
}

@test "Chromium browser helpers live in a dedicated module sourced from browser.sh" {
    run test -f "$PROJECT_DIR/linux/lib/chromium-managed-extension.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$_browser_lib_dir/chromium-managed-extension.sh"' "$PROJECT_DIR/linux/lib/browser.sh"
    [ "$status" -eq 0 ]
}

@test "Chromium browser tests consume shared Chromium policy contracts" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run browser_contract_fixture_value "browser-chromium-policy.json" "defaultSearchProviderName"
    [ "$status" -eq 0 ]
    [ "$output" = "DuckDuckGo" ]
}

@test "generate_chromium_policies emits DnsOverHttpsMode and pinned default search" {
    BLOCKED_PATHS=("example.com/ads")

    source "$PROJECT_DIR/linux/lib/browser.sh"

    run generate_chromium_policies
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json

with open("$CHROMIUM_POLICIES_BASE/openpath.json", "r", encoding="utf-8") as fh:
    policy = json.load(fh)

assert policy["DnsOverHttpsMode"] == "off", policy
assert policy["DnsOverHttpsTemplates"] == "", policy
assert policy["DefaultSearchProviderEnabled"] is True, policy
assert policy["DefaultSearchProviderName"] == "DuckDuckGo", policy
assert "URLBlocklist" in policy, policy
PYEOF
}

@test "generate_chromium_policies force-installs managed extension when id is known" {
    export OPENPATH_CHROMIUM_EXTENSION_DIR="$TEST_TMP_DIR/browser-extension"
    mkdir -p "$OPENPATH_CHROMIUM_EXTENSION_DIR"
    BLOCKED_PATHS=("example.com/ads")

    source "$PROJECT_DIR/linux/lib/browser.sh"

    printf '%s\n' "abcdefghijklmnopabcdefghijklmnop" > "$(get_chromium_extension_id_file)"

    run generate_chromium_policies
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json

with open("$CHROMIUM_POLICIES_BASE/openpath.json", "r", encoding="utf-8") as fh:
    policy = json.load(fh)

forcelist = policy["ExtensionInstallForcelist"]
assert len(forcelist) == 1, forcelist
assert forcelist[0].startswith("abcdefghijklmnopabcdefghijklmnop;"), forcelist
PYEOF
}

@test "generate_chromium_policies honours CHROMIUM_EXTENSION_UPDATE_URL override" {
    export OPENPATH_CHROMIUM_EXTENSION_DIR="$TEST_TMP_DIR/browser-extension"
    mkdir -p "$OPENPATH_CHROMIUM_EXTENSION_DIR"
    export CHROMIUM_EXTENSION_UPDATE_URL="https://school.example/api/extensions/chromium/updates.xml"
    BLOCKED_PATHS=()

    source "$PROJECT_DIR/linux/lib/browser.sh"

    printf '%s\n' "abcdefghijklmnopabcdefghijklmnop" > "$(get_chromium_extension_id_file)"

    run generate_chromium_policies
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json

with open("$CHROMIUM_POLICIES_BASE/openpath.json", "r", encoding="utf-8") as fh:
    policy = json.load(fh)

assert policy["ExtensionInstallForcelist"] == [
    "abcdefghijklmnopabcdefghijklmnop;https://school.example/api/extensions/chromium/updates.xml"
], policy
PYEOF
}
#!/usr/bin/env bats
################################################################################
# browser_chromium.bats - Chromium browser integration tests
################################################################################

load 'test_helper'
source "$BATS_TEST_DIRNAME/browser_support.bash"
