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

################################################################################
# Part 2: unit tests for tests/e2e/contract-scenarios/contract-helpers.sh
################################################################################

# shellcheck source=e2e/contract-scenarios/contract-helpers.sh
source "$TEST_DIR/e2e/contract-scenarios/contract-helpers.sh"

# Canned `iptables -S OUTPUT` capture mirroring activate_firewall
# (linux/lib/firewall-runtime.sh:7-117) rule order on a full-featured kernel.
V4_FIXTURE='-P OUTPUT DROP
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j DROP
-A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p udp -m udp --dport 53 -j ACCEPT
-A OUTPUT -d 10.77.0.53/32 -p udp -m udp --dport 53 -m owner --uid-owner 106 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -m limit --limit 5/min -j LOG --log-prefix "OPENPATH-DNS-DROP "
-A OUTPUT -p udp -m udp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 853 -j DROP
-A OUTPUT -p tcp -m tcp --dport 443 -m set --match-set openpath-doh-block dst -j DROP
-A OUTPUT -p udp -m udp --dport 443 -m set --match-set openpath-doh-block dst -j DROP
-A OUTPUT -p udp -m udp --dport 1194 -j DROP
-A OUTPUT -p tcp -m tcp --dport 1194 -j DROP
-A OUTPUT -p udp -m udp --dport 51820 -j DROP
-A OUTPUT -p tcp -m tcp --dport 1723 -j DROP
-A OUTPUT -p udp -m udp --dport 500 -j DROP
-A OUTPUT -p udp -m udp --dport 4500 -j DROP
-A OUTPUT -p tcp -m tcp --dport 9001 -j DROP
-A OUTPUT -p tcp -m tcp --dport 9030 -j DROP
-A OUTPUT -p tcp -m tcp --dport 9050 -j DROP
-A OUTPUT -p tcp -m tcp --dport 9051 -j DROP
-A OUTPUT -p tcp -m tcp --dport 9150 -j DROP
-A OUTPUT -p tcp -m tcp --dport 80 -m set --match-set openpath-allow-dst dst -j ACCEPT
-A OUTPUT -p tcp -m tcp --dport 443 -m set --match-set openpath-allow-dst dst -j ACCEPT
-A OUTPUT -p udp -m udp --dport 123 -m set --match-set openpath-allow-dst dst -j ACCEPT
-A OUTPUT -p udp -m udp --dport 67:68 -j ACCEPT
-A OUTPUT -d 10.0.0.0/8 -j ACCEPT
-A OUTPUT -d 172.16.0.0/12 -j ACCEPT
-A OUTPUT -d 192.168.0.0/16 -j ACCEPT
-A OUTPUT -d 192.0.2.1/32 -p tcp -j REJECT --reject-with tcp-reset
-A OUTPUT -d 192.0.2.1/32 -p udp -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "OPENPATH-EGRESS-DROP "
-A OUTPUT -j DROP'

# Canned `ip6tables -S OUTPUT` capture mirroring apply_ipv6_firewall
# (linux/lib/firewall-rule-helpers.sh:425-507).
V6_FIXTURE='-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -p ipv6-icmp -m icmp6 --icmpv6-type 128 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 546:547 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 853 -j DROP
-A OUTPUT -p tcp -m tcp --dport 80 -m set --match-set openpath-allow-dst6 dst -j ACCEPT
-A OUTPUT -p tcp -m tcp --dport 443 -m set --match-set openpath-allow-dst6 dst -j ACCEPT
-A OUTPUT -p udp -m udp --dport 123 -m set --match-set openpath-allow-dst6 dst -j ACCEPT
-A OUTPUT -d 100::/128 -p tcp -j REJECT --reject-with tcp-reset
-A OUTPUT -d 100::/128 -p udp -j REJECT --reject-with icmp6-port-unreachable
-A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "OPENPATH-EGRESS6-DROP "
-A OUTPUT -j DROP'

IPSET_FIXTURE='create openpath-allow-dst hash:ip family inet hashsize 1024 maxelem 65536 timeout 300
add openpath-allow-dst 93.184.216.34 timeout 297
create openpath-allow-dst6 hash:ip family inet6 hashsize 1024 maxelem 65536 timeout 300
create openpath-doh-block hash:ip family inet hashsize 1024 maxelem 65536
add openpath-doh-block 9.9.9.9'

IPSET_EMPTY_ALLOW='create openpath-allow-dst hash:ip family inet hashsize 1024 maxelem 65536 timeout 300
create openpath-doh-block hash:ip family inet hashsize 1024 maxelem 65536
add openpath-doh-block 9.9.9.9'

@test "contract_ipv4_in_cidr: membership, non-membership, bare /32" {
    contract_ipv4_in_cidr 10.255.0.1 10.0.0.0/8
    ! contract_ipv4_in_cidr 11.0.0.1 10.0.0.0/8
    contract_ipv4_in_cidr 192.0.2.1 192.0.2.1/32
    contract_ipv4_in_cidr 192.0.2.1 192.0.2.1
    ! contract_ipv4_in_cidr 192.0.2.2 192.0.2.1/32
}

@test "contract_port_matches: exact and iptables X:Y range" {
    contract_port_matches 443 443
    ! contract_port_matches 444 443
    contract_port_matches 68 67:68
    ! contract_port_matches 69 67:68
}

@test "verdict: v4 sinkhole tcp/udp 443 is refused (fast-fail REJECT wins over final DROP)" {
    run contract_egress_verdict v4 "$V4_FIXTURE" "$IPSET_FIXTURE" 192.0.2.1 tcp 443
    [ "$output" = "refused" ]
    run contract_egress_verdict v4 "$V4_FIXTURE" "$IPSET_FIXTURE" 192.0.2.1 udp 443
    [ "$output" = "refused" ]
}

@test "verdict: allow-set member is allowed on 443; non-member falls to terminal DROP" {
    run contract_egress_verdict v4 "$V4_FIXTURE" "$IPSET_FIXTURE" 93.184.216.34 tcp 443
    [ "$output" = "allowed" ]
    run contract_egress_verdict v4 "$V4_FIXTURE" "$IPSET_FIXTURE" 203.0.113.10 tcp 9999
    [ "$output" = "dropped" ]
}

@test "verdict: DoH block-set DROP precedes the allow-set ACCEPT" {
    run contract_egress_verdict v4 "$V4_FIXTURE" "$IPSET_FIXTURE" 9.9.9.9 tcp 443
    [ "$output" = "dropped" ]
}

@test "verdict: owner-scoped upstream :53 ACCEPT does NOT match ordinary traffic (8fe4cbc0 topology)" {
    run contract_egress_verdict v4 "$V4_FIXTURE" "$IPSET_FIXTURE" 10.77.0.53 udp 53
    [ "$output" = "dropped" ]
}

@test "verdict: RFC1918 broad ACCEPT and DHCP port range match" {
    run contract_egress_verdict v4 "$V4_FIXTURE" "$IPSET_FIXTURE" 192.168.1.7 tcp 8080
    [ "$output" = "allowed" ]
    run contract_egress_verdict v4 "$V4_FIXTURE" "$IPSET_FIXTURE" 203.0.113.10 udp 68
    [ "$output" = "allowed" ]
}

@test "verdict v6: sinkhole refused, external v6 DNS dropped" {
    run contract_egress_verdict v6 "$V6_FIXTURE" "$IPSET_FIXTURE" 100:: tcp 443
    [ "$output" = "refused" ]
    run contract_egress_verdict v6 "$V6_FIXTURE" "$IPSET_FIXTURE" 2001:db8::53 udp 53
    [ "$output" = "dropped" ]
}

@test "contract_dns_matches covers the full expectation vocabulary" {
    contract_dns_matches a sinkhole "192.0.2.1"
    ! contract_dns_matches a sinkhole "93.184.216.34"
    contract_dns_matches a real "93.184.216.34"
    ! contract_dns_matches a real "192.0.2.1"
    ! contract_dns_matches a real ""
    contract_dns_matches a no-answer ""
    ! contract_dns_matches a no-answer "93.184.216.34"
    contract_dns_matches aaaa not-sinkhole ""
    contract_dns_matches aaaa not-sinkhole "2606:2800:220:1:248:1893:25c8:1946"
    ! contract_dns_matches aaaa not-sinkhole "100::"
    contract_dns_matches a blocked ""
    contract_dns_matches a blocked "0.0.0.0"
    contract_dns_matches aaaa blocked "100::"
    ! contract_dns_matches a blocked "93.184.216.34"
}

@test "contract_dns_matches ignores intermediate CNAME chain lines" {
    contract_dns_matches a real "cdn.example.net.
93.184.216.34"
}

@test "contract_sinkhole_order_ok: sinkhole before server= passes, reversed fails" {
    local good="address=/#/192.0.2.1
address=/#/100::
server=/example.com/8.8.8.8"
    local bad="server=/example.com/8.8.8.8
address=/#/192.0.2.1"
    contract_sinkhole_order_ok "$good"
    ! contract_sinkhole_order_ok "$bad"
}

@test "contract_resolv_conf_has_no_search_domain (page-observer canary contract)" {
    contract_resolv_conf_has_no_search_domain "nameserver 127.0.0.1
options edns0 trust-ad"
    ! contract_resolv_conf_has_no_search_domain "nameserver 127.0.0.1
search lan"
    ! contract_resolv_conf_has_no_search_domain "domain lan
nameserver 127.0.0.1"
}

@test "contract_allow_set_scoped_and_populated: scoped+populated ok, scoped+empty fails" {
    contract_allow_set_scoped_and_populated "$V4_FIXTURE" "$IPSET_FIXTURE"
    ! contract_allow_set_scoped_and_populated "$V4_FIXTURE" "$IPSET_EMPTY_ALLOW"
}

@test "contract_bypass_blocks_applied: full catalog passes, missing Tor port fails" {
    contract_bypass_blocks_applied "$V4_FIXTURE" "$IPSET_FIXTURE"
    local degraded
    degraded="$(printf '%s\n' "$V4_FIXTURE" | grep -v -- '--dport 9050 ')"
    ! contract_bypass_blocks_applied "$degraded" "$IPSET_FIXTURE"
}

@test "contract_v6_dns_blocked and contract_upstream_consistent" {
    contract_v6_dns_blocked "$V6_FIXTURE"
    ! contract_v6_dns_blocked "-A OUTPUT -j ACCEPT"
    contract_upstream_consistent "10.77.0.53" "# upstream
nameserver 10.77.0.53
nameserver 8.8.4.4"
    ! contract_upstream_consistent "10.77.0.53" "nameserver 8.8.8.8"
    ! contract_upstream_consistent "" "nameserver 8.8.8.8"
}
