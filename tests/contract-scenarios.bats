#!/usr/bin/env bats
################################################################################
# contract-scenarios.bats - Unit rung for the cross-platform contract scenarios
#
# Part 1 (this task): fixture-schema validation for tests/contracts/scenarios/.
# Part 2 (Task 2):   unit tests for tests/e2e/contract-scenarios/contract-helpers.sh.
# The real-state rung runs inside the Linux E2E Docker lane (Task 4) and on the
# self-hosted Windows lab runner (Tasks 7-8).
################################################################################

load 'test_helper'

SCENARIOS_DIR="$TEST_DIR/contracts/scenarios"

require_jq() {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
}

@test "scenarios directory exists and contains the MVP scenario set" {
    [ -d "$SCENARIOS_DIR" ]
    for id in \
        s01-blocked-domain-sinkhole \
        s02-blocked-domain-v6-off \
        s03-whitelisted-domain-allow-set \
        s04-empty-whitelist-never-brick \
        s05-upstream-reprobe-owner-confined \
        s06-bypass-blocks-and-v6-blanket \
        s07-search-domain-no-fallthrough; do
        [ -f "$SCENARIOS_DIR/${id}.scenario.json" ]
    done
}

@test "every scenario is valid JSON with required keys and id matching filename" {
    require_jq
    for f in "$SCENARIOS_DIR"/*.scenario.json; do
        run jq -e '.id and .title and .platforms and .given and .expect' "$f"
        [ "$status" -eq 0 ]
        local base id
        base="$(basename "$f" .scenario.json)"
        id="$(jq -r '.id' "$f")"
        [ "$id" = "$base" ]
    done
}

@test "platforms values are only linux/windows" {
    require_jq
    for f in "$SCENARIOS_DIR"/*.scenario.json; do
        run jq -e '.platforms | length > 0 and all(. == "linux" or . == "windows")' "$f"
        [ "$status" -eq 0 ]
    done
}

@test "flags use only canonical defaults.conf names with 0/1 string values" {
    require_jq
    for f in "$SCENARIOS_DIR"/*.scenario.json; do
        run jq -e '
            (.given.flags // {}) | to_entries | all(
                (.key | IN("SINKHOLE_FAST_FAIL","IPV6_FIREWALL_ENABLED","ALLOW_SET_EGRESS_ENABLED","DOH_BLOCK_ENABLED","VPN_BLOCK_ENABLED","TOR_BLOCK_ENABLED"))
                and (.value | IN("0","1"))
            )' "$f"
        [ "$status" -eq 0 ]
    done
}

@test "dns expectations use the defined vocabulary" {
    require_jq
    for f in "$SCENARIOS_DIR"/*.scenario.json; do
        run jq -e '
            def vocab: IN("sinkhole","real","no-answer","not-sinkhole","blocked");
            def expect_ok: if type == "string" then vocab
                else (type == "object" and (to_entries | all((.key | IN("linux","windows")) and (.value | vocab)))) end;
            (.expect.dns // []) | all(
                (.host | type == "string" and length > 0)
                and ((.a // "no-answer") | expect_ok)
                and ((.aaaa // "no-answer") | expect_ok)
            )' "$f"
        [ "$status" -eq 0 ]
    done
}

@test "egress verdicts and invariant names use the defined vocabulary" {
    require_jq
    for f in "$SCENARIOS_DIR"/*.scenario.json; do
        run jq -e '
            ((.expect.egress // []) | all(.verdict | IN("allowed","refused","dropped")))
            and ((.expect.invariants // []) | all(IN(
                "sinkhole-order","resolv-conf-no-search-domain",
                "allow-set-populated-when-scoped","upstream-consistency",
                "bypass-blocks-applied","v6-dns-block-split-halves",
                "no-slash-zero-prefix","no-ipv6-loopback-rule")))' "$f"
        [ "$status" -eq 0 ]
    done
}
