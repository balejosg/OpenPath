@test "get_policies_hash returns empty hash without files" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run get_policies_hash
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "get_policies_hash ignores blocked paths now enforced by Firefox extension runtime" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    BLOCKED_PATHS=()
    hash1=$(get_policies_hash)

    BLOCKED_PATHS=("example.com/ads")
    hash2=$(get_policies_hash)

    [ "$hash1" = "$hash2" ]
}

@test "get_policies_hash includes Firefox policies hash" {
    echo '{"policies": {}}' > "$FIREFOX_POLICIES"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    run get_policies_hash
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "cleanup_browser_policies removes Chromium files" {
    echo '{"URLBlocklist": ["test"]}' > "$CHROMIUM_POLICIES_BASE/openpath.json"

    source "$PROJECT_DIR/linux/lib/browser.sh"

    run cleanup_browser_policies
    [ "$status" -eq 0 ]

    [ ! -f "$CHROMIUM_POLICIES_BASE/openpath.json" ]
}

@test "cleanup_browser_policies leaves Firefox managed extension policy untouched" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run add_extension_to_policies "openpath-block-monitor@openpath" "$TEST_TMP_DIR/extensions/openpath-block-monitor@openpath"
    [ "$status" -eq 0 ]

    BLOCKED_PATHS=("example.com/ads")

    run cleanup_browser_policies
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json

with open("$FIREFOX_POLICIES", "r", encoding="utf-8") as fh:
    policies = json.load(fh)

extension_settings = policies["policies"].get("ExtensionSettings", {})
assert "openpath-block-monitor@openpath" in extension_settings, extension_settings
assert "Extensions" in policies["policies"], policies["policies"]
assert "openpath-block-monitor@openpath" in policies["policies"]["Extensions"].get("Locked", [])
PYEOF
}

@test "add_extension_to_policies adds ExtensionSettings" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run add_extension_to_policies "test-ext@test" "/path/to/ext"
    [ "$status" -eq 0 ]

    grep -q "ExtensionSettings" "$FIREFOX_POLICIES"
    grep -q "test-ext@test" "$FIREFOX_POLICIES"
}

@test "add_extension_to_policies does not duplicate force-installed extension through Extensions.Install" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run add_extension_to_policies "test-ext@test" "/path/to/ext"
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json

with open("$FIREFOX_POLICIES", "r", encoding="utf-8") as fh:
    policies = json.load(fh)

assert policies["policies"].get("Extensions", {}).get("Install", []) == []
PYEOF
}

@test "add_extension_to_policies locks extension" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run add_extension_to_policies "test-ext@test" "/path/to/ext"
    [ "$status" -eq 0 ]

    grep -q "Locked" "$FIREFOX_POLICIES"
}

@test "add_extension_to_policies uses explicit install_url when provided" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run add_extension_to_policies \
        "test-ext@test" \
        "$TEST_TMP_DIR/test-ext.xpi" \
        "https://downloads.example/test-ext.xpi"
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json

with open("$FIREFOX_POLICIES", "r", encoding="utf-8") as fh:
    policies = json.load(fh)

entry = policies["policies"]["ExtensionSettings"]["test-ext@test"]
assert entry["install_url"] == "https://downloads.example/test-ext.xpi"
assert "https://downloads.example/test-ext.xpi" not in policies["policies"].get("Extensions", {}).get("Install", [])
PYEOF
}

@test "add_extension_to_policies replaces stale install entries for the same extension" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run add_extension_to_policies "openpath-block-monitor@openpath" "$TEST_TMP_DIR/unpacked-extension"
    [ "$status" -eq 0 ]

    run add_extension_to_policies \
        "openpath-block-monitor@openpath" \
        "$TEST_TMP_DIR/openpath-firefox-extension.xpi" \
        "https://school.example/api/extensions/firefox/openpath.xpi"
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json

with open("$FIREFOX_POLICIES", "r", encoding="utf-8") as fh:
    policies = json.load(fh)

install_entries = policies["policies"].get("Extensions", {}).get("Install", [])
old_entry = "$TEST_TMP_DIR/unpacked-extension"
assert old_entry not in install_entries, install_entries
assert "https://school.example/api/extensions/firefox/openpath.xpi" not in install_entries
assert policies["policies"]["ExtensionSettings"]["openpath-block-monitor@openpath"]["install_url"] == "https://school.example/api/extensions/firefox/openpath.xpi"
PYEOF
}

@test "remove_firefox_extension removes managed install entry" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run add_extension_to_policies \
        "openpath-block-monitor@openpath" \
        "$TEST_TMP_DIR/openpath.xpi" \
        "https://downloads.example/openpath-managed.xpi"
    [ "$status" -eq 0 ]

    run remove_firefox_extension
    [ "$status" -eq 0 ]

    python3 - <<PYEOF
import json

with open("$FIREFOX_POLICIES", "r", encoding="utf-8") as fh:
    policies = json.load(fh)

policy_root = policies["policies"]
assert "openpath-block-monitor@openpath" not in policy_root.get("ExtensionSettings", {})
assert "https://downloads.example/openpath-managed.xpi" not in policy_root.get("Extensions", {}).get("Install", [])
assert "openpath-block-monitor@openpath" not in policy_root.get("Extensions", {}).get("Locked", [])
PYEOF
}

@test "linux browser helpers keep Firefox dynamic policy helpers removed" {
    run grep -nF 'generate_firefox_policies' "$PROJECT_DIR/linux/lib/firefox-policy.sh"
    [ "$status" -ne 0 ]

    run grep -nF 'apply_search_engine_policies' "$PROJECT_DIR/linux/lib/firefox-policy.sh"
    [ "$status" -ne 0 ]

    run grep -nF 'browser-json.py mutate-firefox-policies' "$PROJECT_DIR/linux/lib/firefox-policy.sh"
    [ "$status" -eq 0 ]
}

@test "linux Chromium helpers delegate JSON mutation to the shared browser-json helper" {
    run grep -nF 'browser-json.py write-chromium-policy' "$PROJECT_DIR/linux/lib/chromium-managed-extension.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'browser-json.py rewrite-chromium-manifest' "$PROJECT_DIR/linux/lib/chromium-managed-extension.sh"
    [ "$status" -eq 0 ]
}

@test "browser tests are split into responsibility-focused suites" {
    run test -f "$PROJECT_DIR/tests/browser_policy.bats"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/tests/browser_firefox_extension.bats"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/tests/browser_chromium.bats"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/tests/browser_native_host.bats"
    [ "$status" -eq 0 ]
}

@test "browser policy tests consume shared Firefox managed-extension contracts" {
    source "$PROJECT_DIR/linux/lib/browser.sh"

    run browser_contract_fixture_value "browser-firefox-managed-extension.json" "extensionId"
    [ "$status" -eq 0 ]
    [ "$output" = "openpath-block-monitor@openpath" ]
}

@test "browser policy contracts define managed Firefox source precedence" {
    run test -f "$PROJECT_DIR/tests/contracts/browser-firefox-managed-extension.json"
    [ "$status" -eq 0 ]

    run grep -nF '"managedApiInstallUrl"' "$PROJECT_DIR/tests/contracts/browser-firefox-managed-extension.json"
    [ "$status" -eq 0 ]

    run grep -nF '"stagedReleaseInstallUrl"' "$PROJECT_DIR/tests/contracts/browser-firefox-managed-extension.json"
    [ "$status" -eq 0 ]
}
#!/usr/bin/env bats
################################################################################
# browser_policy.bats - Firefox policy and shared browser policy tests
################################################################################

load 'test_helper'
source "$BATS_TEST_DIRNAME/browser_support.bash"
