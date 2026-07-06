#!/usr/bin/env bats
################################################################################
# contract-constants.bats - Generated contract constants (linux include)
################################################################################

load 'test_helper'

setup() {
    source "$PROJECT_DIR/linux/lib/common-contract-constants.sh"
}

@test "disabled sentinel is the canonical no-space form" {
    [ "$OPENPATH_CONTRACT_DISABLED_SENTINEL" = "#DESACTIVADO" ]
    [ "$OPENPATH_CONTRACT_DISABLED_SENTINEL_WORD" = "DESACTIVADO" ]
}

@test "section headers match the wire format" {
    [ "$OPENPATH_CONTRACT_SECTION_WHITELIST" = "## WHITELIST" ]
    [ "$OPENPATH_CONTRACT_SECTION_BLOCKED_SUBDOMAINS" = "## BLOCKED-SUBDOMAINS" ]
    [ "$OPENPATH_CONTRACT_SECTION_BLOCKED_PATHS" = "## BLOCKED-PATHS" ]
    [ "$OPENPATH_CONTRACT_SECTION_ALLOWED_PATHS" = "## ALLOWED-PATHS" ]
}

@test "probe domain list matches the linux contract list (order preserved)" {
    run get_openpath_contract_captive_portal_probe_domains
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "detectportal.firefox.com" ]
    [ "${lines[1]}" = "connectivity-check.ubuntu.com" ]
    [ "${lines[2]}" = "captive.apple.com" ]
    [ "${lines[3]}" = "www.msftconnecttest.com" ]
    [ "${lines[4]}" = "clients3.google.com" ]
    [ "${#lines[@]}" -eq 5 ]
}
