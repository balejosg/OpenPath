#!/usr/bin/env bats
################################################################################
# browser_firefox_extension.bats - Firefox extension installation tests
################################################################################

load 'test_helper'
source "$BATS_TEST_DIRNAME/browser_support.bash"

@test "Firefox extension manifest owns path and subdomain request blocking" {
    python3 - <<PYEOF
import json

with open("$PROJECT_DIR/firefox-extension/manifest.json", "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

permissions = manifest.get("permissions", [])
assert "webRequest" in permissions
assert "webRequestBlocking" in permissions
assert "nativeMessaging" in permissions
assert manifest.get("host_permissions") == ["<all_urls>"]
PYEOF
}

@test "detect_firefox_dir returns valid directory if exists" {
    mkdir -p "$TEST_TMP_DIR/usr/lib/firefox-esr"
    touch "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    detect_firefox_dir() {
        local dirs=("$TEST_TMP_DIR/usr/lib/firefox-esr")
        for dir in "${dirs[@]}"; do
            if [ -d "$dir" ] && [ -f "$dir/firefox" ]; then
                echo "$dir"
                return 0
            fi
        done
        return 1
    }

    run detect_firefox_dir
    [ "$status" -eq 0 ]
    [[ "$output" == *"firefox-esr"* ]]
}

@test "detect_firefox_dir returns error if Firefox not exists" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    detect_firefox_dir() { return 1; }

    run detect_firefox_dir
    [ "$status" -eq 1 ]
}

@test "install_firefox_esr accepts existing non-dpkg Firefox installation" {
    run grep -nF 'if detect_firefox_dir >/dev/null 2>&1; then' \
        "$PROJECT_DIR/linux/lib/browser-firefox.sh"
    [ "$status" -eq 0 ]
}

@test "generate_firefox_autoconfig creates autoconfig files" {
    mkdir -p "$TEST_TMP_DIR/usr/lib/firefox-esr"
    touch "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    detect_firefox_dir() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr"; }
    export -f detect_firefox_dir

    run generate_firefox_autoconfig
    [ "$status" -eq 0 ]

    [ -f "$TEST_TMP_DIR/usr/lib/firefox-esr/defaults/pref/autoconfig.js" ]
    [ -f "$TEST_TMP_DIR/usr/lib/firefox-esr/mozilla.cfg" ]
}

@test "generate_firefox_autoconfig disables signature verification" {
    mkdir -p "$TEST_TMP_DIR/usr/lib/firefox-esr"
    touch "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    detect_firefox_dir() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr"; }
    export -f detect_firefox_dir

    run generate_firefox_autoconfig
    [ "$status" -eq 0 ]

    grep -q "xpinstall.signatures.required" "$TEST_TMP_DIR/usr/lib/firefox-esr/mozilla.cfg"
    grep -q "false" "$TEST_TMP_DIR/usr/lib/firefox-esr/mozilla.cfg"
}

@test "generate_firefox_autoconfig disables DoH and DNS cache" {
    mkdir -p "$TEST_TMP_DIR/usr/lib/firefox-esr"
    touch "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    detect_firefox_dir() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr"; }
    export -f detect_firefox_dir

    run generate_firefox_autoconfig
    [ "$status" -eq 0 ]

    grep -q 'lockPref("network.trr.mode", 5)' "$TEST_TMP_DIR/usr/lib/firefox-esr/mozilla.cfg"
    grep -q 'lockPref("network.trr.uri", "")' "$TEST_TMP_DIR/usr/lib/firefox-esr/mozilla.cfg"
    grep -q 'lockPref("network.dnsCacheExpiration", 0)' "$TEST_TMP_DIR/usr/lib/firefox-esr/mozilla.cfg"
    grep -q 'lockPref("network.dnsCacheExpirationGracePeriod", 0)' "$TEST_TMP_DIR/usr/lib/firefox-esr/mozilla.cfg"
}

@test "generate_firefox_autoconfig handles absence of Firefox" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    detect_firefox_dir() { return 1; }
    export -f detect_firefox_dir

    run generate_firefox_autoconfig
    [ "$status" -eq 1 ]
}

@test "install_firefox_release_extension configures policies from signed artifacts" {
    local release_dir="$TEST_TMP_DIR/firefox-release"
    mkdir -p "$release_dir"
    cat > "$release_dir/metadata.json" <<'EOF'
{"extensionId":"openpath-block-monitor@openpath","version":"2.0.0"}
EOF
    touch "$release_dir/openpath-firefox-extension.xpi"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    add_extension_to_policies() {
        printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$TEST_TMP_DIR/policy-args"
        return 0
    }
    export -f add_extension_to_policies

    run install_firefox_release_extension "$release_dir"
    [ "$status" -eq 0 ]

    mapfile -t policy_args < "$TEST_TMP_DIR/policy-args"
    [ "${policy_args[0]}" = "openpath-block-monitor@openpath" ]
    [ "${policy_args[1]}" = "$release_dir/openpath-firefox-extension.xpi" ]
    [[ "${policy_args[2]}" == file://* ]]
}

@test "stage_firefox_unpacked_extension_assets copies required bundle files" {
    local ext_dir="$TEST_TMP_DIR/firefox-extension"
    local staged_dir="$TEST_TMP_DIR/staged-extension"
    mkdir -p "$ext_dir/dist/lib" "$ext_dir/popup" "$ext_dir/icons" "$ext_dir/blocked"
    echo '{"manifest_version": 2}' > "$ext_dir/manifest.json"
    echo 'console.log("bg");' > "$ext_dir/dist/background.js"
    echo 'console.log("popup");' > "$ext_dir/dist/popup.js"
    echo 'console.log("lib");' > "$ext_dir/dist/lib/runtime.js"
    touch "$ext_dir/popup/popup.html"
    touch "$ext_dir/icons/icon-48.png"
    touch "$ext_dir/blocked/blocked.html"
    touch "$ext_dir/blocked/blocked.css"
    touch "$ext_dir/blocked/blocked.js"

    source "$PROJECT_DIR/linux/lib/firefox-extension-assets.sh"

    run stage_firefox_unpacked_extension_assets "$ext_dir" "$staged_dir"
    [ "$status" -eq 0 ]
    [ -f "$staged_dir/manifest.json" ]
    [ -f "$staged_dir/dist/background.js" ]
    [ -f "$staged_dir/dist/popup.js" ]
    [ -f "$staged_dir/dist/lib/runtime.js" ]
    [ -d "$staged_dir/popup" ]
    [ -d "$staged_dir/icons" ]
    [ -d "$staged_dir/blocked" ]
}

@test "stage_firefox_installation_bundle includes optional native host assets when present" {
    local ext_dir="$TEST_TMP_DIR/firefox-extension"
    local staged_dir="$TEST_TMP_DIR/staged-extension"
    mkdir -p "$ext_dir/dist/lib" "$ext_dir/popup" "$ext_dir/icons" "$ext_dir/blocked" "$ext_dir/native"
    echo '{"manifest_version": 2}' > "$ext_dir/manifest.json"
    echo 'console.log("bg");' > "$ext_dir/dist/background.js"
    echo 'console.log("popup");' > "$ext_dir/dist/popup.js"
    echo 'console.log("lib");' > "$ext_dir/dist/lib/runtime.js"
    touch "$ext_dir/popup/popup.html"
    touch "$ext_dir/icons/icon-48.png"
    touch "$ext_dir/blocked/blocked.html"
    touch "$ext_dir/blocked/blocked.css"
    touch "$ext_dir/blocked/blocked.js"
    touch "$ext_dir/native/openpath-native-host.py"

    source "$PROJECT_DIR/linux/lib/firefox-extension-assets.sh"

    run stage_firefox_installation_bundle "$ext_dir" "$staged_dir"
    [ "$status" -eq 0 ]
    [ -f "$staged_dir/native/openpath-native-host.py" ]
}

@test "install_firefox_extension copies extension files" {
    local ext_dir="$TEST_TMP_DIR/firefox-extension"
    mkdir -p "$ext_dir/dist/lib" "$ext_dir/popup" "$ext_dir/icons" "$ext_dir/blocked"
    echo '{"manifest_version": 2}' > "$ext_dir/manifest.json"
    echo 'console.log("bg");' > "$ext_dir/dist/background.js"
    echo 'console.log("popup");' > "$ext_dir/dist/popup.js"
    echo 'console.log("lib");' > "$ext_dir/dist/lib/runtime.js"
    touch "$ext_dir/popup/popup.html"
    touch "$ext_dir/icons/icon-48.png"
    touch "$ext_dir/blocked/blocked.html"
    touch "$ext_dir/blocked/blocked.css"
    touch "$ext_dir/blocked/blocked.js"

    local ext_install_dir="$FIREFOX_EXTENSIONS_ROOT/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/openpath-block-monitor@openpath"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    detect_firefox_dir() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr"; }
    generate_firefox_autoconfig() { return 0; }
    export -f detect_firefox_dir generate_firefox_autoconfig

    run install_firefox_extension "$ext_dir"
    [ "$status" -eq 0 ]

    [ -f "$ext_install_dir/manifest.json" ]
    [ -f "$ext_install_dir/dist/background.js" ]
    [ -f "$ext_install_dir/dist/popup.js" ]
    [ -f "$ext_install_dir/dist/lib/runtime.js" ]
    [ -d "$ext_install_dir/popup" ]
    [ -d "$ext_install_dir/icons" ]
    [ -d "$ext_install_dir/blocked" ]
}

@test "install_firefox_extension prefers signed Firefox release artifacts when available" {
    local release_dir="$TEST_TMP_DIR/firefox-release"
    mkdir -p "$release_dir"
    cat > "$release_dir/metadata.json" <<'EOF'
{"extensionId":"openpath-block-monitor@openpath","version":"2.0.0"}
EOF
    touch "$release_dir/openpath-firefox-extension.xpi"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    generate_firefox_autoconfig() {
        echo "called" > "$TEST_TMP_DIR/autoconfig-called"
        return 0
    }
    add_extension_to_policies() {
        printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$TEST_TMP_DIR/policy-args"
        return 0
    }
    export -f generate_firefox_autoconfig add_extension_to_policies

    run install_firefox_extension "$TEST_TMP_DIR/missing-unpacked-extension" "$release_dir"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP_DIR/autoconfig-called" ]

    mapfile -t policy_args < "$TEST_TMP_DIR/policy-args"
    [ "${policy_args[0]}" = "openpath-block-monitor@openpath" ]
    [ "${policy_args[1]}" = "$release_dir/openpath-firefox-extension.xpi" ]
    [[ "${policy_args[2]}" == file://* ]]
}

@test "install_firefox_extension handles nonexistent directory" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run install_firefox_extension "/path/that/does/not/exist"
    [ "$status" -eq 1 ]
}

@test "sync_firefox_managed_extension_policy prefers configured OpenPath API route over local release artifacts" {
    local release_dir="$TEST_TMP_DIR/firefox-release"
    export ETC_CONFIG_DIR="$TEST_TMP_DIR/etc/openpath"
    mkdir -p "$release_dir" "$ETC_CONFIG_DIR"
    cat > "$release_dir/metadata.json" <<'EOF'
{"extensionId":"openpath-block-monitor@openpath","version":"2.0.0"}
EOF
    touch "$release_dir/openpath-firefox-extension.xpi"
    printf '%s\n' 'https://school.example/' > "$ETC_CONFIG_DIR/api-url.conf"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    curl() {
        printf '%s\n' "$*" > "$TEST_TMP_DIR/curl-args"
        return 0
    }
    add_extension_to_policies() {
        printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$TEST_TMP_DIR/policy-args"
        return 0
    }
    export -f curl add_extension_to_policies

    run sync_firefox_managed_extension_policy "$release_dir"
    [ "$status" -eq 0 ]

    mapfile -t policy_args < "$TEST_TMP_DIR/policy-args"
    [ "${policy_args[0]}" = "openpath-block-monitor@openpath" ]
    [ "${policy_args[1]}" = "https://school.example/api/extensions/firefox/openpath.xpi" ]
    [ "${policy_args[2]}" = "https://school.example/api/extensions/firefox/openpath.xpi" ]
}

@test "resolve_firefox_managed_extension_policy reports managed api source when no signed release artifact exists" {
    local release_dir="$TEST_TMP_DIR/firefox-release"
    export ETC_CONFIG_DIR="$TEST_TMP_DIR/etc/openpath"
    mkdir -p "$release_dir" "$ETC_CONFIG_DIR"
    printf '%s\n' 'https://school.example/' > "$ETC_CONFIG_DIR/api-url.conf"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    curl() {
        return 0
    }
    export -f curl

    run resolve_firefox_managed_extension_policy "$release_dir"
    [ "$status" -eq 0 ]

    mapfile -t policy_lines <<< "$output"
    [ "${policy_lines[0]}" = "extension_id=openpath-block-monitor@openpath" ]
    [ "${policy_lines[1]}" = "install_entry=https://school.example/api/extensions/firefox/openpath.xpi" ]
    [ "${policy_lines[2]}" = "install_url=https://school.example/api/extensions/firefox/openpath.xpi" ]
    [ "${policy_lines[3]}" = "source=managed-api" ]
}

@test "install_firefox_extension falls back to local unpacked bundle when release metadata lacks a staged XPI" {
    local release_dir="$TEST_TMP_DIR/firefox-release"
    mkdir -p "$release_dir"
    cat > "$release_dir/metadata.json" <<'EOF'
{"extensionId":"openpath-block-monitor@openpath","version":"2.0.0","installUrl":"https://school.example/api/extensions/firefox/openpath.xpi"}
EOF

    source "$PROJECT_DIR/linux/lib/browser.sh"

    install_firefox_unpacked_extension() {
        printf '%s\n' "$1" > "$TEST_TMP_DIR/unpacked-source"
        return 0
    }
    export -f install_firefox_unpacked_extension

    run install_firefox_extension "$TEST_TMP_DIR/firefox-extension" "$release_dir"
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_TMP_DIR/unpacked-source")" = "$TEST_TMP_DIR/firefox-extension" ]
}

@test "install_firefox_extension prefers managed api over local unpacked bundle when signed artifacts are absent" {
    local release_dir="$TEST_TMP_DIR/firefox-release"
    local ext_dir="$TEST_TMP_DIR/firefox-extension"
    mkdir -p "$release_dir" "$ext_dir"
    export ETC_CONFIG_DIR="$TEST_TMP_DIR/etc/openpath"
    mkdir -p "$ETC_CONFIG_DIR"
    printf '%s\n' 'https://school.example/' > "$ETC_CONFIG_DIR/api-url.conf"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    curl() {
        return 0
    }
    install_firefox_unpacked_extension() {
        printf '%s\n' "$1" > "$TEST_TMP_DIR/unpacked-source"
        return 0
    }
    add_extension_to_policies() {
        printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$TEST_TMP_DIR/managed-policy-args"
        return 0
    }
    export -f curl install_firefox_unpacked_extension add_extension_to_policies

    run install_firefox_extension "$ext_dir" "$release_dir"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP_DIR/unpacked-source" ]
    mapfile -t policy_args < "$TEST_TMP_DIR/managed-policy-args"
    [ "${policy_args[0]}" = "openpath-block-monitor@openpath" ]
    [ "${policy_args[1]}" = "https://school.example/api/extensions/firefox/openpath.xpi" ]
    [ "${policy_args[2]}" = "https://school.example/api/extensions/firefox/openpath.xpi" ]
}
