#!/bin/bash
################################################################################
# contract-helpers.sh - Pure assertion helpers for the Linux contract scenarios
#
# Every function receives captured text (dig +short answers, `iptables -S
# OUTPUT`, `ipset save`, config file bodies) as arguments and never executes
# live commands, so this file is unit-tested without root from
# tests/contract-scenarios.bats. The live runner (run-contract-scenarios.sh)
# gathers real state and feeds it here. Vocabulary is defined by
# tests/contracts/scenarios/schema.json.
################################################################################

CONTRACT_SINKHOLE_V4="${OPENPATH_DNS_SINKHOLE_IPV4:-192.0.2.1}"
CONTRACT_SINKHOLE_V6="${OPENPATH_DNS_SINKHOLE_IPV6:-100::}"

# ---------------------------------------------------------------------------
# DNS answer classification
# ---------------------------------------------------------------------------

# Keep only address lines: drop empties and intermediate CNAME chain entries
# (dig +short prints CNAME targets with a trailing dot).
contract_dns_addresses() {
    printf '%s\n' "${1:-}" | awk 'NF > 0 && $0 !~ /\.$/'
}

# Echo only "blocked-shaped" answers (sinkhole or unspecified). Mirrors
# dns_probe_result_is_public in linux/lib/dns-runtime.sh:99-109.
contract_dns_blocked_shaped() {
    printf '%s\n' "${1:-}" | awk -v s4="$CONTRACT_SINKHOLE_V4" -v s6="$CONTRACT_SINKHOLE_V6" \
        '$0 == s4 || $0 == s6 || $0 == "0.0.0.0" || $0 == "::"'
}

# contract_dns_matches <a|aaaa> <expectation> <dig +short output>
# Expectation vocabulary: sinkhole | real | no-answer | not-sinkhole | blocked
contract_dns_matches() {
    local family="$1" expectation="$2" answers sink
    answers="$(contract_dns_addresses "${3:-}")"

    case "$family" in
        a) sink="$CONTRACT_SINKHOLE_V4" ;;
        aaaa) sink="$CONTRACT_SINKHOLE_V6" ;;
        *)
            echo "contract_dns_matches: unknown family '$family'" >&2
            return 2
            ;;
    esac

    local total blockedish sink_count any_sink
    total=$(printf '%s' "$answers" | grep -c . || true)
    blockedish=$(contract_dns_blocked_shaped "$answers" | grep -c . || true)
    sink_count=$(printf '%s\n' "$answers" | awk -v s="$sink" '$0 == s' | grep -c . || true)
    any_sink=$(printf '%s\n' "$answers" | awk -v s4="$CONTRACT_SINKHOLE_V4" -v s6="$CONTRACT_SINKHOLE_V6" \
        '$0 == s4 || $0 == s6' | grep -c . || true)

    case "$expectation" in
        sinkhole) [ "$total" -gt 0 ] && [ "$sink_count" -eq "$total" ] ;;
        real) [ "$total" -gt 0 ] && [ "$blockedish" -eq 0 ] ;;
        no-answer) [ "$total" -eq 0 ] ;;
        not-sinkhole) [ "$any_sink" -eq 0 ] ;;
        blocked) [ "$blockedish" -eq "$total" ] ;;
        *)
            echo "contract_dns_matches: unknown expectation '$expectation'" >&2
            return 2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Address / port matching
# ---------------------------------------------------------------------------

contract_ipv4_to_int() {
    local ip="$1" a b c d
    IFS=. read -r a b c d <<< "$ip" || return 1
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    echo $(((a << 24) + (b << 16) + (c << 8) + d))
}

# contract_ipv4_in_cidr <ip> <cidr>   (a bare IP is treated as /32)
contract_ipv4_in_cidr() {
    local ip="$1" cidr="$2" base prefix ip_int base_int mask
    base="${cidr%%/*}"
    if [[ "$cidr" == */* ]]; then prefix="${cidr##*/}"; else prefix=32; fi
    ip_int=$(contract_ipv4_to_int "$ip") || return 1
    base_int=$(contract_ipv4_to_int "$base") || return 1
    [ "$prefix" -eq 0 ] && return 0
    mask=$((0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF))
    [ $((ip_int & mask)) -eq $((base_int & mask)) ]
}

# IPv6 destination match, restricted to the CIDR forms the Linux engine
# actually emits: /128 (exact, e.g. the 100:: fast-fail rule) and /0. Any
# other prefix is reported and treated as a non-match so a future rule shape
# fails loudly during triage instead of silently passing.
contract_ipv6_dest_matches() {
    local dest="$1" cidr="$2" base prefix
    base="${cidr%%/*}"
    if [[ "$cidr" == */* ]]; then prefix="${cidr##*/}"; else prefix=128; fi
    case "$prefix" in
        128) [ "${dest,,}" = "${base,,}" ] ;;
        0) return 0 ;;
        *)
            echo "contract_ipv6_dest_matches: unsupported IPv6 prefix /$prefix in '$cidr' (extend the helper)" >&2
            return 2
            ;;
    esac
}

# contract_port_matches <port> <spec>  where spec is N or the iptables N:M range
contract_port_matches() {
    local port="$1" spec="$2" lo hi
    if [[ "$spec" == *:* ]]; then
        lo="${spec%%:*}"
        hi="${spec##*:}"
        [ "$port" -ge "$lo" ] && [ "$port" -le "$hi" ]
    else
        [ "$port" -eq "$spec" ]
    fi
}

# ---------------------------------------------------------------------------
# ipset state (from `ipset save` text)
# ---------------------------------------------------------------------------

contract_ipset_has_member() {
    printf '%s\n' "${1:-}" | awk -v set="$2" -v ip="$3" \
        '$1 == "add" && $2 == set && $3 == ip { found = 1 } END { exit found ? 0 : 1 }'
}

contract_ipset_nonempty() {
    printf '%s\n' "${1:-}" | awk -v set="$2" \
        '$1 == "add" && $2 == set { found = 1 } END { exit found ? 0 : 1 }'
}

# ---------------------------------------------------------------------------
# Egress verdict classification (first matching OUTPUT rule wins)
# ---------------------------------------------------------------------------

# contract_egress_verdict <v4|v6> <rules -S text> <ipset save text> <dest> <proto> <port>
# Prints allowed|dropped|refused: the verdict the OUTPUT chain gives a fresh
# (NEW-state) packet sent by an ordinary process (not dnsmasq's uid, no
# specific egress interface). Rules that cannot match such a packet are
# skipped by construction: -o (interface-scoped), --uid-owner (owner-scoped),
# --state (conntrack), --icmp(v6)-type (ICMP-typed), -j LOG (non-terminal).
contract_egress_verdict() {
    local family="$1" rules="$2" ipsets="$3" dest="$4" proto="$5" port="$6"
    local line verdict="" policy_drop=0

    while IFS= read -r line; do
        case "$line" in
            "-P OUTPUT DROP") policy_drop=1; continue ;;
            "-A OUTPUT "*) ;;
            *) continue ;;
        esac

        local -a tok=()
        read -r -a tok <<< "$line"
        local i=0 n=${#tok[@]}
        local r_dest="" r_proto="" r_dport="" r_set="" r_target="" skip=0
        while [ "$i" -lt "$n" ]; do
            case "${tok[$i]}" in
                -d) r_dest="${tok[$((i + 1))]}"; i=$((i + 2)) ;;
                -p) r_proto="${tok[$((i + 1))]}"; i=$((i + 2)) ;;
                --dport) r_dport="${tok[$((i + 1))]}"; i=$((i + 2)) ;;
                --match-set) r_set="${tok[$((i + 1))]}"; i=$((i + 2)) ;;
                -o | --uid-owner | --state | --icmp-type | --icmpv6-type) skip=1; break ;;
                -j) r_target="${tok[$((i + 1))]}"; i=$((i + 2)) ;;
                *) i=$((i + 1)) ;;
            esac
        done
        [ "$skip" -eq 1 ] && continue
        [ "$r_target" = "LOG" ] && continue
        [ -z "$r_target" ] && continue

        if [ -n "$r_proto" ] && [ "$r_proto" != "$proto" ]; then continue; fi
        if [ -n "$r_dport" ] && ! contract_port_matches "$port" "$r_dport"; then continue; fi
        if [ -n "$r_dest" ]; then
            if [ "$family" = "v4" ]; then
                contract_ipv4_in_cidr "$dest" "$r_dest" || continue
            else
                contract_ipv6_dest_matches "$dest" "$r_dest" || continue
            fi
        fi
        if [ -n "$r_set" ] && ! contract_ipset_has_member "$ipsets" "$r_set" "$dest"; then continue; fi

        case "$r_target" in
            ACCEPT) verdict="allowed" ;;
            DROP) verdict="dropped" ;;
            REJECT) verdict="refused" ;;
            *) continue ;;
        esac
        break
    done <<< "$rules"

    if [ -z "$verdict" ]; then
        if [ "$policy_drop" -eq 1 ]; then verdict="dropped"; else verdict="allowed"; fi
    fi
    printf '%s\n' "$verdict"
}

# ---------------------------------------------------------------------------
# Named invariants (Linux encodings)
# ---------------------------------------------------------------------------

# sinkhole-order: the first address=/#/ wildcard must precede the first
# server=/ allow (linux/AGENTS.md Critical Contract; dns-dnsmasq.sh:135-139).
contract_sinkhole_order_ok() {
    printf '%s\n' "${1:-}" | awk '
        /^address=\/#\// { if (!sink_line) sink_line = NR }
        /^server=\// { if (!server_line) server_line = NR }
        END {
            if (!sink_line || !server_line) exit 1
            exit (sink_line < server_line) ? 0 : 1
        }'
}

# resolv-conf-no-search-domain: no search/domain directive may appear
# (linux/lib/dns-runtime.sh:150-169; page-observer canary).
contract_resolv_conf_has_no_search_domain() {
    ! printf '%s\n' "${1:-}" | grep -qE '^[[:space:]]*(search|domain)[[:space:]]'
}

# allow-set-populated-when-scoped: when the 80/443 ACCEPT is scoped to the
# allow set, the set MUST be non-empty (an empty allow set under default-deny
# bricks all HTTPS -- the ADR-0011 never-brick clause). In the degraded
# broad-accept mode the broad 443 ACCEPT must exist instead.
contract_allow_set_scoped_and_populated() {
    local rules="$1" ipsets="$2" set_name="${OPENPATH_ALLOW_DST_IPSET:-openpath-allow-dst}"
    if printf '%s\n' "$rules" | grep -q -- "--match-set $set_name dst -j ACCEPT"; then
        contract_ipset_nonempty "$ipsets" "$set_name"
        return $?
    fi
    printf '%s\n' "$rules" | grep -q -- "-p tcp -m tcp --dport 443 -j ACCEPT"
}

# upstream-consistency: dnsmasq's runtime upstream must equal the persisted
# upstream (regression 8fe4cbc0 -- divergence kills all DNS).
contract_upstream_consistent() {
    local persisted="$1" resolv_body="$2" first
    [ -n "$persisted" ] || return 1
    first="$(printf '%s\n' "$resolv_body" | awk '$1 == "nameserver" { print $2; exit }')"
    [ "$first" = "$persisted" ]
}

# bypass-blocks-applied: the full anti-bypass catalog must be present:
# DoT :853 DROP, DoH block-set DROP (populated set), every VPN catalog entry,
# every Tor catalog port, and the tun+ interface DROP. Catalog defaults mirror
# linux/lib/defaults.conf (and tests/contracts/{vpn-block-rules,tor-block-ports}.txt).
contract_bypass_blocks_applied() {
    local rules="$1" ipsets="$2"
    printf '%s\n' "$rules" | grep -q -- "--dport 853 -j DROP" \
        || { echo "bypass-blocks-applied: missing DoT :853 DROP" >&2; return 1; }
    printf '%s\n' "$rules" | grep -q -- "--match-set openpath-doh-block dst -j DROP" \
        || { echo "bypass-blocks-applied: missing DoH match-set DROP" >&2; return 1; }
    contract_ipset_nonempty "$ipsets" "openpath-doh-block" \
        || { echo "bypass-blocks-applied: DoH block ipset is empty" >&2; return 1; }

    local -a vpn_rules=()
    IFS=',' read -r -a vpn_rules <<< "${VPN_BLOCK_RULES:-udp:1194:OpenVPN,tcp:1194:OpenVPN-TCP,udp:51820:WireGuard,tcp:1723:PPTP,udp:500:IKE,udp:4500:IPSec-NAT}"
    local entry vproto vport vname
    for entry in "${vpn_rules[@]}"; do
        IFS=: read -r vproto vport vname <<< "$entry"
        printf '%s\n' "$rules" | grep -q -- "-p $vproto -m $vproto --dport $vport -j DROP" \
            || { echo "bypass-blocks-applied: missing VPN block $vproto/$vport ($vname)" >&2; return 1; }
    done

    local -a tor_ports=()
    IFS=',' read -r -a tor_ports <<< "${TOR_BLOCK_PORTS:-9001,9030,9050,9051,9150}"
    local tport
    for tport in "${tor_ports[@]}"; do
        printf '%s\n' "$rules" | grep -q -- "-p tcp -m tcp --dport $tport -j DROP" \
            || { echo "bypass-blocks-applied: missing Tor block :$tport" >&2; return 1; }
    done

    printf '%s\n' "$rules" | grep -q -- "-o tun+ -j DROP" \
        || { echo "bypass-blocks-applied: missing tun+ interface DROP" >&2; return 1; }
    return 0
}

# Linux mapping of "v6-dns-block-split-halves": ALL IPv6 DNS (:53 udp+tcp)
# and DoT (:853) dropped in ip6tables. The literal ::/1 + 8000::/1 halves are
# the Windows-only encoding of "all IPv6" (New-NetFirewallRule rejects ::/0;
# ContractScenarios.Helpers.psm1 asserts that form).
contract_v6_dns_blocked() {
    local rules6="$1"
    printf '%s\n' "$rules6" | grep -q -- "-p udp -m udp --dport 53 -j DROP" || return 1
    printf '%s\n' "$rules6" | grep -q -- "-p tcp -m tcp --dport 53 -j DROP" || return 1
    printf '%s\n' "$rules6" | grep -q -- "--dport 853 -j DROP" || return 1
}
