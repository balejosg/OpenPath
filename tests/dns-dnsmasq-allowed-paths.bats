#!/usr/bin/env bats
# dns-dnsmasq-allowed-paths.bats
# Verifies that ## ALLOWED-PATHS entries are never emitted as dnsmasq server= allows.

load 'test_helper'

setup() {
    TEST_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_DIR"
    export LOG_FILE="$TEST_DIR/test.log"
    export VAR_STATE_DIR="$TEST_DIR"
    export ETC_CONFIG_DIR="$TEST_DIR/etc"
    export DNSMASQ_CONF="$TEST_DIR/openpath.conf"
    mkdir -p "$ETC_CONFIG_DIR"
    touch "$LOG_FILE"

    source "$BATS_TEST_DIRNAME/../linux/lib/common.sh"
    source "$BATS_TEST_DIRNAME/../linux/lib/dns.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# -----------------------------------------------------------------------------
# Section-parser safety: ALLOWED-PATHS must NOT leak into WHITELIST_DOMAINS
# -----------------------------------------------------------------------------

@test "parse_whitelist_sections: ALLOWED-PATHS entry never appears in WHITELIST_DOMAINS" {
    local wl="$TEST_DIR/whitelist.txt"
    cat >"$wl" <<'EOF'
## WHITELIST
youtube.com
## ALLOWED-PATHS
youtube.com/watch?v=abc
EOF
    parse_whitelist_sections "$wl"

    # youtube.com (bare domain) must be whitelisted
    [[ " ${WHITELIST_DOMAINS[*]} " == *" youtube.com "* ]]

    # The path entry must NOT appear in WHITELIST_DOMAINS
    for d in "${WHITELIST_DOMAINS[@]}"; do
        if [[ "$d" == *"watch"* ]] || [[ "$d" == *"/"* ]]; then
            echo "FAIL: path entry leaked into WHITELIST_DOMAINS: $d" >&2
            return 1
        fi
    done
}

@test "parse_whitelist_sections: ALLOWED-PATHS after WHITELIST does not contaminate remaining whitelist entries" {
    local wl="$TEST_DIR/whitelist.txt"
    cat >"$wl" <<'EOF'
## WHITELIST
github.com
## ALLOWED-PATHS
github.com/path/to/resource
## BLOCKED-SUBDOMAINS
bad.github.com
EOF
    parse_whitelist_sections "$wl"

    # github.com (bare domain) must be present
    [[ " ${WHITELIST_DOMAINS[*]} " == *" github.com "* ]]

    # No entry with a slash must appear in WHITELIST_DOMAINS
    for d in "${WHITELIST_DOMAINS[@]}"; do
        [[ "$d" != *"/"* ]] || { echo "FAIL: path entry in WHITELIST_DOMAINS: $d" >&2; return 1; }
    done

    # Blocked subdomain must still be parsed correctly
    [[ " ${BLOCKED_SUBDOMAINS[*]} " == *" bad.github.com "* ]]
}

# -----------------------------------------------------------------------------
# dnsmasq config generation: ALLOWED-PATHS entry must not produce server= lines
# -----------------------------------------------------------------------------

@test "allowed-paths section entry never becomes a dnsmasq server= allow" {
    local wl="$TEST_DIR/whitelist.txt"
    cat >"$wl" <<'EOF'
## WHITELIST
youtube.com
## ALLOWED-PATHS
youtube.com/watch?v=abc
EOF
    parse_whitelist_sections "$wl"

    PRIMARY_DNS="8.8.8.8"
    generate_dnsmasq_config

    [ -f "$DNSMASQ_CONF" ]

    # The bare domain allow must exist
    grep -q 'server=/youtube\.com/' "$DNSMASQ_CONF"

    # The path string must never appear in any dnsmasq directive
    ! grep -q 'watch' "$DNSMASQ_CONF"
    ! grep -q 'watch?v=abc' "$DNSMASQ_CONF"
}
