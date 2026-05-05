setup() {
    TEST_TMP_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_TMP_DIR/config"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    export FIREFOX_POLICIES="$TEST_TMP_DIR/firefox/policies/policies.json"
    export FIREFOX_EXTENSIONS_ROOT="$TEST_TMP_DIR/share/mozilla/extensions"
    export CHROMIUM_POLICIES_BASE="$TEST_TMP_DIR/chromium/policies/managed"
    export BROWSER_POLICIES_HASH="$CONFIG_DIR/browser-policies.hash"
    export CHROME_EXTERNAL_EXTENSIONS_DIR="$TEST_TMP_DIR/chrome/extensions"
    export EDGE_EXTERNAL_EXTENSIONS_DIR="$TEST_TMP_DIR/edge/extensions"
    export FIREFOX_NATIVE_HOST_DIR="$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts"
    export OPENPATH_NATIVE_HOST_INSTALL_DIR="$TEST_TMP_DIR/local/lib/openpath"
    export CHROMIUM_NATIVE_HOST_DIR="$TEST_TMP_DIR/chromium/native-messaging-hosts"
    export CHROME_NATIVE_HOST_DIR="$TEST_TMP_DIR/chrome/native-messaging-hosts"
    export EDGE_NATIVE_HOST_DIR="$TEST_TMP_DIR/edge/native-messaging-hosts"

    mkdir -p "$CONFIG_DIR"
    mkdir -p "$INSTALL_DIR/lib"
    mkdir -p "$(dirname "$FIREFOX_POLICIES")"
    mkdir -p "$FIREFOX_EXTENSIONS_ROOT"
    mkdir -p "$CHROMIUM_POLICIES_BASE"
    mkdir -p "$CHROME_EXTERNAL_EXTENSIONS_DIR"
    mkdir -p "$EDGE_EXTERNAL_EXTENSIONS_DIR"
    mkdir -p "$FIREFOX_NATIVE_HOST_DIR"
    mkdir -p "$OPENPATH_NATIVE_HOST_INSTALL_DIR"
    mkdir -p "$CHROMIUM_NATIVE_HOST_DIR"
    mkdir -p "$CHROME_NATIVE_HOST_DIR"
    mkdir -p "$EDGE_NATIVE_HOST_DIR"

    cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/" 2>/dev/null || true

    BLOCKED_PATHS=()
    BLOCKED_SUBDOMAINS=()
    WHITELIST_DOMAINS=()

    log() { echo "$1"; }
    export -f log

    unset OPENPATH_BROWSER_POLICY_SPEC
}

teardown() {
    if [ -n "$TEST_TMP_DIR" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}

write_browser_policy_spec_fixture() {
    local spec_path="$1"
    cat > "$spec_path" <<'EOF'
{
  "firefox": {
    "googleSearchBlocks": [
      "*://search.example.test/*"
    ],
    "searchEngines": {
      "remove": ["Google", "Bing"],
      "default": "Startpage",
      "add": [
        {
          "Name": "Startpage",
          "Description": "Private search",
          "Alias": "sp",
          "Method": "GET",
          "URLTemplate": "https://www.startpage.com/search?q={searchTerms}",
          "IconURL": "https://www.startpage.com/favicon.ico"
        }
      ]
    },
    "dnsOverHttps": {
      "Enabled": false,
      "Locked": true
    },
    "disableTelemetry": true,
    "overrideFirstRunPage": ""
  },
  "chromium": {
    "googleSearchBlock": "*://search.example.test/*",
    "googleGameBlocks": [
      "*://games.example.test/*"
    ],
    "defaultSearchProviderEnabled": 1,
    "defaultSearchProviderName": "Startpage",
    "defaultSearchProviderSearchURL": "https://www.startpage.com/search?q={searchTerms}",
    "dnsOverHttpsMode": "off"
  }
}
EOF
}

browser_contract_fixture_value() {
    local file_name="$1"
    local field_path="$2"
    local fixture_path="$PROJECT_DIR/tests/contracts/$file_name"

    python3 - "$fixture_path" "$field_path" <<'PYEOF'
import json
import sys

fixture_path, field_path = sys.argv[1:3]
with open(fixture_path, "r", encoding="utf-8") as fh:
    value = json.load(fh)

for segment in field_path.split("."):
    if isinstance(value, list):
        value = value[int(segment)]
    else:
        value = value[segment]

if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("null")
else:
    print(value)
PYEOF
}
