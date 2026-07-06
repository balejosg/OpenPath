#!/bin/bash
################################################################################
# run-contract-scenarios.sh - Executes tests/contracts/scenarios/*.scenario.json
# against the REAL enforcement stack (dnsmasq + iptables/ip6tables/ipset)
# inside the Linux E2E systemd container.
#
# Invoked by tests/e2e/docker-e2e-runner.sh when OPENPATH_CONTRACT_SCENARIOS_MODE=1
# (host entrypoint: tests/e2e/ci/run-linux-e2e.sh --contract-scenarios).
#
# Per scenario:
#   1. serve given.whitelist as the machine whitelist over loopback HTTP
#      (the same fixture pattern run-linux-e2e.sh's whitelist update test uses),
#   2. export given.flags as OPENPATH_<FLAG> environment overrides,
#   3. run the REAL /usr/local/bin/openpath-update.sh,
#   4. assert expect.dns / expect.egress / expect.invariants through the pure
#      helpers in contract-helpers.sh over freshly captured state.
#
# All scenarios run even after a failure (evidence completeness); the exit
# code is non-zero if any failed. Evidence per scenario lands in
# --artifact-dir (MUST be an absolute path).
################################################################################
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/contract-scenarios/contract-helpers.sh
source "$SCRIPT_DIR/contract-helpers.sh"

SCENARIOS_DIR="${OPENPATH_CONTRACT_SCENARIOS_DIR:-$(cd "$SCRIPT_DIR/../../contracts/scenarios" && pwd)}"
FIXTURE_PORT="${OPENPATH_CONTRACT_FIXTURE_PORT:-18083}"
FIXTURE_DIR="/tmp/openpath-contract-fixture"
FIXTURE_TOKEN="contract-token"
DEFAULTS_CONF="/usr/local/lib/openpath/lib/defaults.conf"
ARTIFACT_DIR=""
SUMMARY_FILE=""
FIXTURE_SERVER_PID=""

# Per-scenario state
SCENARIO_LOG=""
SCENARIO_ART=""
scenario_failed=0
declare -a ENV_OVERRIDES=()
PERSISTED_UPSTREAM_BEFORE=""
PERSISTED_UPSTREAM_AFTER=""
V4_RULES=""
V6_RULES=""
IPSET_STATE=""
DNSMASQ_CONF_TEXT=""
RESOLV_TEXT=""
DNSMASQ_RESOLV_TEXT=""
IP6_AVAILABLE=0
REJECT_CAPABLE_V4=0

usage() {
    echo "Usage: $0 --artifact-dir <ABSOLUTE path>" >&2
    exit 2
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --artifact-dir)
                ARTIFACT_DIR="${2:-}"
                shift 2
                ;;
            *) usage ;;
        esac
    done
    [ -n "$ARTIFACT_DIR" ] || usage
    [[ "$ARTIFACT_DIR" = /* ]] || {
        echo "--artifact-dir must be ABSOLUTE (Docker-lane contract), got: $ARTIFACT_DIR" >&2
        exit 2
    }
}

cleanup() {
    if [ -n "$FIXTURE_SERVER_PID" ]; then
        kill "$FIXTURE_SERVER_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# Task-2 review: contract_bypass_blocks_applied (contract-helpers.sh) falls
# back to its OWN inline VPN_BLOCK_RULES/TOR_BLOCK_PORTS catalog string when
# those variables are unset. That inline string is a hand-copy of
# linux/lib/defaults.conf and can silently drift from it. Source the REAL
# installed defaults.conf (in a subshell, so nothing else it sets leaks into
# this script) and export the two catalog variables so the helper checks the
# engine's actual, currently-installed catalog instead of its copy.
export_real_bypass_catalog() {
    [ -f "$DEFAULTS_CONF" ] || {
        echo "Missing installed defaults.conf: $DEFAULTS_CONF" >&2
        exit 2
    }
    # shellcheck source=/dev/null
    VPN_BLOCK_RULES="$(. "$DEFAULTS_CONF" && printf '%s' "$VPN_BLOCK_RULES")"
    # shellcheck source=/dev/null
    TOR_BLOCK_PORTS="$(. "$DEFAULTS_CONF" && printf '%s' "$TOR_BLOCK_PORTS")"
    export VPN_BLOCK_RULES TOR_BLOCK_PORTS
}

preflight() {
    if [ ! -f /.dockerenv ] && [ "${OPENPATH_CONTRACT_ALLOW_HOST:-0}" != "1" ]; then
        echo "Refusing to run outside the E2E container: this runner rewrites the" >&2
        echo "machine whitelist and firewall. Set OPENPATH_CONTRACT_ALLOW_HOST=1 only" >&2
        echo "on a disposable lab VM, never on a real endpoint." >&2
        exit 2
    fi
    [ "$(id -u)" -eq 0 ] || { echo "Must run as root" >&2; exit 2; }
    local cmd
    for cmd in jq dig iptables ipset python3; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required tool: $cmd" >&2; exit 2; }
    done
    [ -x /usr/local/bin/openpath-update.sh ] || {
        echo "OpenPath is not installed (missing /usr/local/bin/openpath-update.sh)" >&2
        exit 2
    }
    [ -d "$SCENARIOS_DIR" ] || { echo "Missing scenarios dir: $SCENARIOS_DIR" >&2; exit 2; }

    mkdir -p "$ARTIFACT_DIR"
    SUMMARY_FILE="$ARTIFACT_DIR/summary.txt"
    : > "$SUMMARY_FILE"

    if command -v ip6tables >/dev/null 2>&1 && ip6tables -S OUTPUT >/dev/null 2>&1; then
        IP6_AVAILABLE=1
    fi
    if probe_reject_capability_v4; then
        REJECT_CAPABLE_V4=1
    fi
    export_real_bypass_catalog
    {
        echo "ip6tables available: $IP6_AVAILABLE"
        echo "iptables REJECT capable: $REJECT_CAPABLE_V4"
        echo "VPN_BLOCK_RULES (from $DEFAULTS_CONF): $VPN_BLOCK_RULES"
        echo "TOR_BLOCK_PORTS (from $DEFAULTS_CONF): $TOR_BLOCK_PORTS"
    } | tee -a "$SUMMARY_FILE"
}

# The fast-fail REJECT is add_optional_rule (firewall-rule-helpers.sh:322-330):
# a kernel without the REJECT target silently degrades to DROP by design.
# Probe capability in a scratch chain so we can tell "engine bug" apart from
# "kernel limitation" when an expected `refused` classifies as `dropped`.
probe_reject_capability_v4() {
    iptables -N OPENPATH-CONTRACT-PROBE 2>/dev/null || iptables -F OPENPATH-CONTRACT-PROBE 2>/dev/null || return 1
    local ok=1
    if iptables -A OPENPATH-CONTRACT-PROBE -d 192.0.2.254/32 -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null; then
        ok=0
    fi
    iptables -F OPENPATH-CONTRACT-PROBE 2>/dev/null || true
    iptables -X OPENPATH-CONTRACT-PROBE 2>/dev/null || true
    return "$ok"
}

start_fixture_server() {
    rm -rf "$FIXTURE_DIR"
    mkdir -p "$FIXTURE_DIR/w/$FIXTURE_TOKEN"
    python3 -m http.server "$FIXTURE_PORT" --bind 127.0.0.1 --directory "$FIXTURE_DIR" \
        > "$ARTIFACT_DIR/fixture-server.log" 2>&1 &
    FIXTURE_SERVER_PID=$!
    local i
    for i in $(seq 1 20); do
        if curl -fsS "http://127.0.0.1:$FIXTURE_PORT/" >/dev/null 2>&1; then
            break
        fi
        [ "$i" -eq 20 ] && { echo "Fixture HTTP server did not come up" >&2; exit 1; }
        sleep 0.5
    done

    mkdir -p /etc/openpath
    printf 'http://127.0.0.1:%s\n' "$FIXTURE_PORT" > /etc/openpath/api-url.conf
    printf 'contract-scenarios-room\n' > /etc/openpath/classroom.conf
    printf 'contract-scenarios-room-id\n' > /etc/openpath/classroom-id.conf
    printf 'http://127.0.0.1:%s/w/%s/whitelist.txt\n' "$FIXTURE_PORT" "$FIXTURE_TOKEN" \
        > /etc/openpath/whitelist-url.conf
}

check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "  ok: $desc" >> "$SCENARIO_LOG"
    else
        echo "  FAIL: $desc" | tee -a "$SCENARIO_LOG" >&2
        scenario_failed=1
    fi
}

note() {
    echo "  $1" | tee -a "$SCENARIO_LOG"
}

# ---------------------------------------------------------------------------
# Scenario apply
# ---------------------------------------------------------------------------

write_scenario_whitelist() {
    local file="$1"
    {
        echo "## WHITELIST"
        jq -r '.given.whitelist[]?' "$file"
    } > "$FIXTURE_DIR/w/$FIXTURE_TOKEN/whitelist.txt"
}

collect_env_overrides() {
    local file="$1" k v
    ENV_OVERRIDES=()
    # MVP whitelists are tiny (0-1 domains); disable the minimum-size guard so
    # the download is accepted and the 0/1-domain enforcement posture is what
    # gets generated (the guard itself is covered by chaos.bats).
    ENV_OVERRIDES+=("OPENPATH_MIN_VALID_DOMAINS=0")
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        ENV_OVERRIDES+=("OPENPATH_${k}=${v}")
    done < <(jq -r '(.given.flags // {}) | to_entries[] | "\(.key)=\(.value)"' "$file")
}

apply_scenario() {
    local log_name="$1"
    if ! env "${ENV_OVERRIDES[@]}" /usr/local/bin/openpath-update.sh \
        > "$SCENARIO_ART/$log_name" 2>&1; then
        echo "  FAIL: openpath-update.sh exited non-zero (see $log_name)" | tee -a "$SCENARIO_LOG" >&2
        scenario_failed=1
        return 1
    fi
    return 0
}

# Regression 8fe4cbc0 procedural setup: with the owner-confined firewall
# ACTIVE (first apply above), a second update re-runs detect_primary_dns; the
# persisted format-valid upstream must be trusted WITHOUT a re-probe and must
# survive unchanged (the re-probe is dropped by our own firewall and used to
# degrade PRIMARY_DNS to a never-allowed fallback, killing all DNS).
run_persisted_upstream_setup() {
    PERSISTED_UPSTREAM_BEFORE="$(head -1 /etc/openpath/original-dns.conf 2>/dev/null || true)"
    if [ -z "$PERSISTED_UPSTREAM_BEFORE" ]; then
        echo "  FAIL: setup persisted-upstream: /etc/openpath/original-dns.conf is empty" \
            | tee -a "$SCENARIO_LOG" >&2
        scenario_failed=1
        return 1
    fi
    apply_scenario "update-second-pass.log" || return 1
    PERSISTED_UPSTREAM_AFTER="$(head -1 /etc/openpath/original-dns.conf 2>/dev/null || true)"
    note "persisted upstream: before=$PERSISTED_UPSTREAM_BEFORE after=$PERSISTED_UPSTREAM_AFTER"
    return 0
}

capture_state() {
    V4_RULES="$(iptables -S OUTPUT 2>/dev/null || true)"
    V6_RULES="$(ip6tables -S OUTPUT 2>/dev/null || true)"
    IPSET_STATE="$(ipset save 2>/dev/null || true)"
    DNSMASQ_CONF_TEXT="$(cat /etc/dnsmasq.d/openpath.conf 2>/dev/null || true)"
    RESOLV_TEXT="$(cat /etc/resolv.conf 2>/dev/null || true)"
    DNSMASQ_RESOLV_TEXT="$(cat /run/dnsmasq/resolv.conf 2>/dev/null || true)"
    printf '%s\n' "$V4_RULES" > "$SCENARIO_ART/iptables-S-OUTPUT.txt"
    printf '%s\n' "$V6_RULES" > "$SCENARIO_ART/ip6tables-S-OUTPUT.txt"
    printf '%s\n' "$IPSET_STATE" > "$SCENARIO_ART/ipset-save.txt"
    printf '%s\n' "$DNSMASQ_CONF_TEXT" > "$SCENARIO_ART/dnsmasq-openpath.conf"
    printf '%s\n' "$RESOLV_TEXT" > "$SCENARIO_ART/resolv.conf"
    printf '%s\n' "$DNSMASQ_RESOLV_TEXT" > "$SCENARIO_ART/dnsmasq-resolv.conf"
}

# ---------------------------------------------------------------------------
# DNS assertions
# ---------------------------------------------------------------------------

# Query (and cache to the artifact dir) one record type for a host.
dig_short() {
    local host="$1" rrtype="$2" out
    out="$SCENARIO_ART/dns-${rrtype,,}-${host}.txt"
    if [ ! -f "$out" ]; then
        timeout 10 dig @127.0.0.1 "$host" "$rrtype" +short +time=3 +tries=1 2>/dev/null > "$out" || true
    fi
    cat "$out"
}

linux_expectation() {
    # $1 = raw jq value for .a/.aaaa (string, object, or null). Prints the
    # linux-side expectation or "absent" when not asserted.
    jq -r 'if . == null then "absent"
           elif type == "string" then .
           else (.linux // "absent") end' <<< "$1"
}

# Resolve every resolved:/resolved6: egress dest BEFORE the state capture so
# dnsmasq's ipset= population from those answers is visible in the captured
# ipset snapshot (dig_short caches, so later probe resolution reuses these).
prewarm_egress_dns() {
    local file="$1" dest
    while IFS= read -r dest; do
        case "$dest" in
            resolved:*) dig_short "${dest#resolved:}" A >/dev/null ;;
            resolved6:*) dig_short "${dest#resolved6:}" AAAA >/dev/null ;;
        esac
    done < <(jq -r '(.expect.egress // [])[].dest' "$file")
}

assert_dns() {
    local file="$1" entry host a_raw aaaa_raw a_exp aaaa_exp answers
    while IFS= read -r entry; do
        host="$(jq -r '.host' <<< "$entry")"
        a_raw="$(jq -c '.a' <<< "$entry")"
        aaaa_raw="$(jq -c '.aaaa' <<< "$entry")"
        a_exp="$(linux_expectation "$a_raw")"
        aaaa_exp="$(linux_expectation "$aaaa_raw")"

        if [ "$a_exp" != "absent" ]; then
            answers="$(dig_short "$host" A)"
            check "dns A $host is $a_exp" contract_dns_matches a "$a_exp" "$answers"
        fi
        if [ "$aaaa_exp" != "absent" ]; then
            if [ "$aaaa_exp" = "sinkhole" ] && [ "$IP6_AVAILABLE" -eq 0 ]; then
                # The engine itself only emits the v6 sinkhole answer when
                # ip6tables can reset it (_dns_emit_blocked_aaaa_sinkhole).
                note "DEGRADED: no usable ip6tables; AAAA $host expectation sinkhole -> no-answer"
                aaaa_exp="no-answer"
            fi
            answers="$(dig_short "$host" AAAA)"
            check "dns AAAA $host is $aaaa_exp" contract_dns_matches aaaa "$aaaa_exp" "$answers"
        fi
    done < <(jq -c '(.expect.dns // [])[]' "$file")
}

# ---------------------------------------------------------------------------
# Egress assertions
# ---------------------------------------------------------------------------

# Prints "<family> <ip>" probe lines for a dest class ("" = none / skip).
resolve_dest_probes() {
    local dest="$1" host ip
    case "$dest" in
        sinkhole-v4) echo "v4 $CONTRACT_SINKHOLE_V4" ;;
        sinkhole-v6) [ "$IP6_AVAILABLE" -eq 1 ] && echo "v6 $CONTRACT_SINKHOLE_V6" ;;
        resolved:*)
            host="${dest#resolved:}"
            while IFS= read -r ip; do
                [ -n "$ip" ] && echo "v4 $ip"
            done < <(contract_dns_addresses "$(dig_short "$host" A)")
            ;;
        resolved6:*)
            host="${dest#resolved6:}"
            [ "$IP6_AVAILABLE" -eq 1 ] || return 0
            while IFS= read -r ip; do
                [ -n "$ip" ] && echo "v6 $ip"
            done < <(contract_dns_addresses "$(dig_short "$host" AAAA)")
            ;;
        doh-resolver:*) echo "v4 ${dest#doh-resolver:}" ;;
        dot-any | vpn:* | tor:* | any-other) echo "v4 203.0.113.10" ;;
        v6-dns-any) [ "$IP6_AVAILABLE" -eq 1 ] && echo "v6 2001:db8::53" ;;
        *)
            echo "UNKNOWN"
            ;;
    esac
    return 0
}

default_port_for_dest() {
    local dest="$1"
    case "$dest" in
        dot-any) echo 853 ;;
        vpn:*) echo "${dest##*:}" ;;
        tor:*) echo "${dest#tor:}" ;;
        v6-dns-any) echo 53 ;;
        any-other) echo 9999 ;;
        *) echo 443 ;;
    esac
}

# Live UX double-check for the fast-fail regression: a REJECTed connect to
# the sinkhole must fail in far less than the ~90s legacy hang.
probe_tcp_fast_fail_ms() {
    local ip="$1" port="$2" start_ms end_ms
    start_ms="$(date +%s%3N)"
    if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        echo "connected"
        return 0
    fi
    end_ms="$(date +%s%3N)"
    echo "$((end_ms - start_ms))"
}

assert_egress() {
    local file="$1" entry dest proto port verdict probes probe family ip actual rules
    while IFS= read -r entry; do
        dest="$(jq -r '.dest' <<< "$entry")"
        proto="$(jq -r '.proto // "tcp"' <<< "$entry")"
        port="$(jq -r '.port // 0' <<< "$entry")"
        verdict="$(jq -r '.verdict' <<< "$entry")"
        [ "$port" != "0" ] || port="$(default_port_for_dest "$dest")"

        probes="$(resolve_dest_probes "$dest")"
        if [ "$probes" = "UNKNOWN" ]; then
            echo "  FAIL: unknown egress dest class '$dest'" | tee -a "$SCENARIO_LOG" >&2
            scenario_failed=1
            continue
        fi
        if [ -z "$probes" ]; then
            case "$dest" in
                resolved6:*)
                    note "SKIP: $dest -> no AAAA answers (upstream returned none) or no ip6tables" ;;
                sinkhole-v6 | v6-dns-any)
                    note "SKIP: $dest -> no usable ip6tables in this environment" ;;
                *)
                    echo "  FAIL: dest '$dest' resolved to no probe addresses" | tee -a "$SCENARIO_LOG" >&2
                    scenario_failed=1
                    ;;
            esac
            continue
        fi

        while IFS= read -r probe; do
            family="${probe%% *}"
            ip="${probe#* }"
            if [ "$family" = "v4" ]; then rules="$V4_RULES"; else rules="$V6_RULES"; fi
            actual="$(contract_egress_verdict "$family" "$rules" "$IPSET_STATE" "$ip" "$proto" "$port")"

            local expected="$verdict"
            if [ "$expected" = "refused" ] && [ "$actual" = "dropped" ] && [ "$REJECT_CAPABLE_V4" -eq 0 ]; then
                # Documented degraded mode (add_optional_rule + kernel without
                # the REJECT target; see tests/e2e/ci/run-linux-student-flow.sh:15-23).
                note "DEGRADED: kernel lacks REJECT; accepting dropped for $dest ($ip $proto/$port)"
                expected="dropped"
            fi
            if [ "$actual" = "$expected" ]; then
                echo "  ok: egress $dest ($ip $proto/$port) -> $actual" >> "$SCENARIO_LOG"
            else
                echo "  FAIL: egress $dest ($ip $proto/$port) expected $expected got $actual" \
                    | tee -a "$SCENARIO_LOG" >&2
                scenario_failed=1
                continue
            fi

            # Fast-fail UX evidence: rule-state says refused; prove the connect
            # actually fails fast (regression: ~90s black-hole hang).
            if [ "$expected" = "refused" ] && [ "$family" = "v4" ] && [ "$proto" = "tcp" ]; then
                local elapsed
                elapsed="$(probe_tcp_fast_fail_ms "$ip" "$port")"
                if [ "$elapsed" = "connected" ]; then
                    echo "  FAIL: live probe CONNECTED to $ip:$port (sinkhole must never accept)" \
                        | tee -a "$SCENARIO_LOG" >&2
                    scenario_failed=1
                elif [ "$elapsed" -lt 2000 ]; then
                    note "fast-fail live probe: $ip:$port refused in ${elapsed}ms"
                else
                    echo "  FAIL: live probe to $ip:$port took ${elapsed}ms (>2000ms; fast-fail regression)" \
                        | tee -a "$SCENARIO_LOG" >&2
                    scenario_failed=1
                fi
            fi
        done <<< "$probes"
    done < <(jq -c '(.expect.egress // [])[] | select((.platforms // ["linux","windows"]) | index("linux"))' "$file")
}

# ---------------------------------------------------------------------------
# Invariant assertions
# ---------------------------------------------------------------------------

assert_invariants() {
    local file="$1" inv
    while IFS= read -r inv; do
        case "$inv" in
            sinkhole-order)
                check "invariant sinkhole-order" contract_sinkhole_order_ok "$DNSMASQ_CONF_TEXT"
                ;;
            resolv-conf-no-search-domain)
                check "invariant resolv-conf-no-search-domain" \
                    contract_resolv_conf_has_no_search_domain "$RESOLV_TEXT"
                ;;
            allow-set-populated-when-scoped)
                check "invariant allow-set-populated-when-scoped" \
                    contract_allow_set_scoped_and_populated "$V4_RULES" "$IPSET_STATE"
                ;;
            upstream-consistency)
                if [ -z "$PERSISTED_UPSTREAM_BEFORE" ]; then
                    echo "  FAIL: upstream-consistency requires given.setup=persisted-upstream" \
                        | tee -a "$SCENARIO_LOG" >&2
                    scenario_failed=1
                else
                    check "invariant upstream-consistency (persisted stable)" \
                        [ "$PERSISTED_UPSTREAM_AFTER" = "$PERSISTED_UPSTREAM_BEFORE" ]
                    check "invariant upstream-consistency (dnsmasq resolv matches)" \
                        contract_upstream_consistent "$PERSISTED_UPSTREAM_AFTER" "$DNSMASQ_RESOLV_TEXT"
                fi
                ;;
            bypass-blocks-applied)
                check "invariant bypass-blocks-applied" \
                    contract_bypass_blocks_applied "$V4_RULES" "$IPSET_STATE"
                ;;
            v6-dns-block-split-halves)
                if [ "$IP6_AVAILABLE" -eq 1 ]; then
                    check "invariant v6-dns-block-split-halves (linux: v6 DNS dropped)" \
                        contract_v6_dns_blocked "$V6_RULES"
                else
                    note "SKIP: v6-dns-block-split-halves (no usable ip6tables)"
                fi
                ;;
            no-slash-zero-prefix | no-ipv6-loopback-rule)
                # Windows-only encodings (New-NetFirewallRule argument
                # contracts); silently skipped on Linux per schema.json.
                ;;
            *)
                echo "  FAIL: UNKNOWN invariant '$inv' (fixture and runners out of sync)" \
                    | tee -a "$SCENARIO_LOG" >&2
                scenario_failed=1
                ;;
        esac
    done < <(jq -r '(.expect.invariants // [])[]' "$file")
}

# ---------------------------------------------------------------------------
# Scenario driver
# ---------------------------------------------------------------------------

run_scenario() {
    local file="$1" id
    id="$(jq -r '.id' "$file")"
    scenario_failed=0
    PERSISTED_UPSTREAM_BEFORE=""
    PERSISTED_UPSTREAM_AFTER=""

    if ! jq -e '.platforms | index("linux")' "$file" >/dev/null; then
        echo "SKIP  $id (not linux-scoped)" | tee -a "$SUMMARY_FILE"
        return 0
    fi

    SCENARIO_ART="$ARTIFACT_DIR/$id"
    mkdir -p "$SCENARIO_ART"
    SCENARIO_LOG="$SCENARIO_ART/scenario.log"
    : > "$SCENARIO_LOG"
    echo "=== $id: $(jq -r '.title' "$file")" | tee -a "$SCENARIO_LOG"

    # Stale allow-set members from the previous scenario would fake
    # allow-set membership assertions; flush entries (sets stay referenced
    # by live rules, so flush -- never destroy -- between scenarios).
    ipset flush openpath-allow-dst 2>/dev/null || true
    ipset flush openpath-allow-dst6 2>/dev/null || true

    write_scenario_whitelist "$file"
    collect_env_overrides "$file"
    apply_scenario "update.log" || { echo "FAIL  $id" | tee -a "$SUMMARY_FILE"; return 1; }

    if [ "$(jq -r '.given.setup // empty' "$file")" = "persisted-upstream" ]; then
        run_persisted_upstream_setup || { echo "FAIL  $id" | tee -a "$SUMMARY_FILE"; return 1; }
    fi

    # DNS first (it also populates the allow set via dnsmasq ipset=), then
    # pre-warm resolved:/resolved6: probe hosts, then capture the state every
    # remaining assertion reads.
    assert_dns "$file"
    prewarm_egress_dns "$file"
    capture_state
    assert_egress "$file"
    assert_invariants "$file"

    if [ "$scenario_failed" -eq 0 ]; then
        echo "PASS  $id" | tee -a "$SUMMARY_FILE"
        return 0
    fi
    echo "FAIL  $id" | tee -a "$SUMMARY_FILE"
    return 1
}

main() {
    parse_args "$@"
    preflight
    start_fixture_server

    local file failures=0
    for file in "$SCENARIOS_DIR"/*.scenario.json; do
        if ! run_scenario "$file"; then
            failures=$((failures + 1))
        fi
    done

    echo "" | tee -a "$SUMMARY_FILE"
    echo "Contract scenarios finished: $failures failing (summary: $SUMMARY_FILE)" | tee -a "$SUMMARY_FILE"
    [ "$failures" -eq 0 ]
}

main "$@"
