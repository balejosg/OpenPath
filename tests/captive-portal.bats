#!/usr/bin/env bats
################################################################################
# captive-portal.bats - Tests for captive portal detection
################################################################################

load 'test_helper'

setup() {
    setup_std_lib_layout
    setup_mock_log
}

# ============== check_captive_portal tests ==============

@test "check_captive_portal returns 1 (no portal) when response matches expected" {
    # Disable multi-check mode for legacy single-check behavior
    export OPENPATH_CAPTIVE_PORTAL_CHECKS=""

    # Mock curl to return success response
    curl() {
        echo "success"
        return 0
    }
    export -f curl

    # Mock timeout to pass through
    timeout() {
        shift  # Remove timeout value
        "$@"   # Execute the rest
    }
    export -f timeout

    # Set expected values
    export CAPTIVE_PORTAL_CHECK_URL="http://detectportal.firefox.com/success.txt"
    export CAPTIVE_PORTAL_CHECK_EXPECTED="success"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run check_captive_portal
    [ "$status" -eq 1 ]  # 1 means NO captive portal
}

@test "check_captive_portal returns 0 (portal detected) when response differs" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS=""

    # Mock curl to return captive portal redirect
    curl() {
        echo "<html>Please login...</html>"
        return 0
    }
    export -f curl

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    export CAPTIVE_PORTAL_CHECK_URL="http://detectportal.firefox.com/success.txt"
    export CAPTIVE_PORTAL_CHECK_EXPECTED="success"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run check_captive_portal
    [ "$status" -eq 0 ]  # 0 means captive portal detected
}

@test "check_captive_portal returns 1 (no portal mode) when curl times out" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS=""

    # Mock curl to hang (simulated by returning empty)
    curl() {
        return 1
    }
    export -f curl

    timeout() {
        return 124  # Timeout exit code
    }
    export -f timeout

    export CAPTIVE_PORTAL_CHECK_URL="http://detectportal.firefox.com/success.txt"
    export CAPTIVE_PORTAL_CHECK_EXPECTED="success"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run check_captive_portal
    [ "$status" -eq 1 ]  # Timeout = no network, not captive portal
}

@test "check_captive_portal returns 1 (no portal mode) when curl fails" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS=""

    # Mock curl to fail (network error)
    curl() {
        return 7  # Connection refused
    }
    export -f curl

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    export CAPTIVE_PORTAL_CHECK_URL="http://detectportal.firefox.com/success.txt"
    export CAPTIVE_PORTAL_CHECK_EXPECTED="success"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run check_captive_portal
    [ "$status" -eq 1 ]  # Network error = no network, not captive portal
}

# ============== is_network_authenticated tests ==============

@test "is_network_authenticated returns 0 when authenticated" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS=""

    curl() {
        echo "success"
        return 0
    }
    export -f curl

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    export CAPTIVE_PORTAL_CHECK_URL="http://detectportal.firefox.com/success.txt"
    export CAPTIVE_PORTAL_CHECK_EXPECTED="success"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run is_network_authenticated
    [ "$status" -eq 0 ]
}

@test "is_network_authenticated returns 1 when not authenticated" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS=""

    curl() {
        echo "redirected to login"
        return 0
    }
    export -f curl

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    export CAPTIVE_PORTAL_CHECK_URL="http://detectportal.firefox.com/success.txt"
    export CAPTIVE_PORTAL_CHECK_EXPECTED="success"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run is_network_authenticated
    [ "$status" -eq 1 ]
}

@test "is_network_authenticated handles empty response" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS=""

    curl() {
        echo ""
        return 0
    }
    export -f curl

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    export CAPTIVE_PORTAL_CHECK_URL="http://detectportal.firefox.com/success.txt"
    export CAPTIVE_PORTAL_CHECK_EXPECTED="success"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run is_network_authenticated
    [ "$status" -eq 1 ]  # Empty != expected
}

@test "is_network_authenticated strips whitespace from response" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS=""

    curl() {
        printf "success\r\n"  # Windows-style line ending
        return 0
    }
    export -f curl

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    export CAPTIVE_PORTAL_CHECK_URL="http://detectportal.firefox.com/success.txt"
    export CAPTIVE_PORTAL_CHECK_EXPECTED="success"

    source "$PROJECT_DIR/linux/lib/common.sh"

    run is_network_authenticated
    [ "$status" -eq 0 ]  # Should match after stripping
}

# ============== Configuration tests ==============

@test "captive portal uses configurable URL from defaults.conf" {
    # defaults.conf is a committed repo file (like its sibling test below, which sources it
    # unconditionally), so this always runs -- no skip guard needed.
    source "$PROJECT_DIR/linux/lib/defaults.conf"
    [ -n "$CAPTIVE_PORTAL_URL" ]
}

@test "CAPTIVE_PORTAL_URL can be overridden via environment" {
    export OPENPATH_CAPTIVE_PORTAL_URL="http://custom-portal.example.com/check"

    source "$PROJECT_DIR/linux/lib/defaults.conf"

    [ "$CAPTIVE_PORTAL_URL" = "http://custom-portal.example.com/check" ]
}

# ============== Multi-check state tests ==============

@test "get_captive_portal_state returns AUTHENTICATED on multi-check majority success" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS="http://a.example/success.txt,success|http://b.example/connecttest.txt,Microsoft Connect Test|http://c.example/generate_204,"

    curl() {
        local url="${!#}"
        case "$url" in
            http://a.example/success.txt)
                echo "success"
                return 0
                ;;
            http://b.example/connecttest.txt)
                echo "Microsoft Connect Test"
                return 0
                ;;
            http://c.example/generate_204)
                # 204 style: empty body
                printf ""
                return 0
                ;;
        esac
        return 7
    }
    export -f curl

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    source "$PROJECT_DIR/linux/lib/common.sh"

    run get_captive_portal_state
    [ "$status" -eq 0 ]
    [ "$output" = "AUTHENTICATED" ]
}

@test "get_captive_portal_state returns PORTAL on multi-check majority mismatch" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS="http://a.example/success.txt,success|http://b.example/connecttest.txt,Microsoft Connect Test|http://c.example/generate_204,"

    curl() {
        local url="${!#}"
        case "$url" in
            http://a.example/success.txt)
                echo "success"
                return 0
                ;;
            http://b.example/connecttest.txt)
                echo "<html>login</html>"
                return 0
                ;;
            http://c.example/generate_204)
                echo "not-empty"
                return 0
                ;;
        esac
        return 7
    }
    export -f curl

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    source "$PROJECT_DIR/linux/lib/common.sh"

    run get_captive_portal_state
    [ "$status" -eq 0 ]
    [ "$output" = "PORTAL" ]
}

@test "get_captive_portal_state returns NO_NETWORK when all multi-checks transport-fail" {
    export OPENPATH_CAPTIVE_PORTAL_CHECKS="http://a.example/success.txt,success|http://b.example/connecttest.txt,Microsoft Connect Test|http://c.example/generate_204,"

    curl() {
        return 7
    }
    export -f curl

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    source "$PROJECT_DIR/linux/lib/common.sh"

    run get_captive_portal_state
    [ "$status" -eq 0 ]
    [ "$output" = "NO_NETWORK" ]
}

# ============== Marker-with-expiry tests (WEDU port) ==============

# Helper: source common.sh + captive-portal.sh with a test state dir.
_source_portal_lib() {
    export VAR_STATE_DIR="$TEST_TMP_DIR/state"
    mkdir -p "$VAR_STATE_DIR"
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/captive-portal.sh"
}

@test "write_portal_mode_marker writes start ts and expires line" {
    _source_portal_lib

    local now
    now=$(date +%s)
    write_portal_mode_marker "$now"

    [ -f "$CAPTIVE_PORTAL_STATE_FILE" ]
    run get_portal_mode_start_ts
    [ "$status" -eq 0 ]
    [ "$output" = "$now" ]

    run get_portal_mode_expiry_ts
    [ "$status" -eq 0 ]
    [ "$output" -gt "$now" ]
}

@test "write_portal_mode_marker honors CAPTIVE_PORTAL_TTL_SECONDS override" {
    _source_portal_lib
    export CAPTIVE_PORTAL_TTL_SECONDS=7

    local now expiry
    now=$(date +%s)
    write_portal_mode_marker "$now"

    expiry=$(get_portal_mode_expiry_ts)
    [ "$expiry" -ge $((now + 7)) ]
    [ "$expiry" -le $((now + 9)) ]
}

@test "legacy single-line marker has no expiry and is never expired" {
    _source_portal_lib

    date +%s > "$CAPTIVE_PORTAL_STATE_FILE"

    run get_portal_mode_expiry_ts
    [ "$status" -eq 1 ]

    run is_portal_mode_expired
    [ "$status" -eq 1 ]

    # Backward compatibility: legacy reader still works
    run get_portal_mode_start_ts
    [ "$status" -eq 0 ]
}

@test "is_portal_mode_expired detects a past deadline" {
    _source_portal_lib

    printf '%s\nexpires=%s\n' "$(($(date +%s) - 300))" "$(($(date +%s) - 100))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"

    run is_portal_mode_expired
    [ "$status" -eq 0 ]
}

@test "is_portal_mode_expired is false for a future deadline" {
    _source_portal_lib

    printf '%s\nexpires=%s\n' "$(date +%s)" "$(($(date +%s) + 300))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"

    run is_portal_mode_expired
    [ "$status" -eq 1 ]
}

@test "refresh_portal_mode_expiry preserves start ts and extends deadline" {
    _source_portal_lib

    local start old_expiry new_expiry
    start=$(($(date +%s) - 60))
    printf '%s\nexpires=%s\n' "$start" "$(($(date +%s) + 1))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"
    old_expiry=$(get_portal_mode_expiry_ts)

    refresh_portal_mode_expiry

    run get_portal_mode_start_ts
    [ "$output" = "$start" ]
    new_expiry=$(get_portal_mode_expiry_ts)
    [ "$new_expiry" -gt "$old_expiry" ]
}

@test "refresh_portal_mode_expiry fails without a marker" {
    _source_portal_lib

    run refresh_portal_mode_expiry
    [ "$status" -eq 1 ]
    [ ! -f "$CAPTIVE_PORTAL_STATE_FILE" ]
}

@test "close_expired_portal_mode restores protections for an expired marker" {
    _source_portal_lib

    printf '%s\nexpires=%s\n' "$(($(date +%s) - 300))" "$(($(date +%s) - 100))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"

    with_openpath_lock() { "$@"; }
    exit_portal_mode_locked() {
        rm -f "$CAPTIVE_PORTAL_STATE_FILE"
        echo "EXIT_PORTAL_MODE_CALLED"
    }

    run close_expired_portal_mode
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT_PORTAL_MODE_CALLED"* ]]
}

@test "close_expired_portal_mode is a no-op for a fresh marker" {
    _source_portal_lib

    printf '%s\nexpires=%s\n' "$(date +%s)" "$(($(date +%s) + 300))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"

    with_openpath_lock() { "$@"; }
    exit_portal_mode_locked() { echo "EXIT_PORTAL_MODE_CALLED"; }

    run close_expired_portal_mode
    [ "$status" -eq 1 ]
    [[ "$output" != *"EXIT_PORTAL_MODE_CALLED"* ]]
    [ -f "$CAPTIVE_PORTAL_STATE_FILE" ]
}

@test "close_expired_portal_mode is a no-op for a legacy marker without expiry" {
    _source_portal_lib

    date +%s > "$CAPTIVE_PORTAL_STATE_FILE"

    with_openpath_lock() { "$@"; }
    exit_portal_mode_locked() { echo "EXIT_PORTAL_MODE_CALLED"; }

    run close_expired_portal_mode
    [ "$status" -eq 1 ]
    [ -f "$CAPTIVE_PORTAL_STATE_FILE" ]
}

@test "dnsmasq-watchdog wires the expired-marker auto-close" {
    # The watchdog must source the captive-portal helpers and call the
    # auto-close hook each cycle (fail-open must not outlive its deadline).
    grep -q 'lib/captive-portal.sh' "$PROJECT_DIR/linux/scripts/runtime/dnsmasq-watchdog.sh"
    grep -q 'close_expired_portal_mode' "$PROJECT_DIR/linux/scripts/runtime/dnsmasq-watchdog.sh"
}

# ============== Anti-oscillation observation counter tests ==============

@test "observation: PORTAL increments portal count and resets authenticated" {
    _source_portal_lib

    update_captive_portal_observation "AUTHENTICATED"
    update_captive_portal_observation "PORTAL"
    update_captive_portal_observation "PORTAL"

    [ "$(get_captive_portal_observation_count portal)" -eq 2 ]
    [ "$(get_captive_portal_observation_count authenticated)" -eq 0 ]
}

@test "observation: AUTHENTICATED increments authenticated and resets portal" {
    _source_portal_lib

    update_captive_portal_observation "PORTAL"
    update_captive_portal_observation "PORTAL"
    update_captive_portal_observation "AUTHENTICATED"

    [ "$(get_captive_portal_observation_count portal)" -eq 0 ]
    [ "$(get_captive_portal_observation_count authenticated)" -eq 1 ]
}

@test "observation: NO_NETWORK leaves both counters unchanged" {
    _source_portal_lib

    update_captive_portal_observation "PORTAL"
    update_captive_portal_observation "NO_NETWORK"

    [ "$(get_captive_portal_observation_count portal)" -eq 1 ]
    [ "$(get_captive_portal_observation_count authenticated)" -eq 0 ]
}

@test "observation: corrupt observation file is treated as zero counts" {
    _source_portal_lib

    echo "garbage not-a-count" > "$CAPTIVE_PORTAL_OBSERVATION_FILE"

    [ "$(get_captive_portal_observation_count portal)" -eq 0 ]
    [ "$(get_captive_portal_observation_count authenticated)" -eq 0 ]
}

@test "should_enter_portal_mode requires 2 consecutive PORTAL observations by default" {
    _source_portal_lib

    update_captive_portal_observation "PORTAL"
    run should_enter_portal_mode
    [ "$status" -eq 1 ]

    update_captive_portal_observation "PORTAL"
    run should_enter_portal_mode
    [ "$status" -eq 0 ]
}

@test "should_enter_portal_mode counter resets on an AUTHENTICATED flap" {
    _source_portal_lib

    update_captive_portal_observation "PORTAL"
    update_captive_portal_observation "AUTHENTICATED"
    update_captive_portal_observation "PORTAL"

    run should_enter_portal_mode
    [ "$status" -eq 1 ]
}

@test "should_exit_portal_mode requires 1 AUTHENTICATED observation by default" {
    _source_portal_lib

    run should_exit_portal_mode
    [ "$status" -eq 1 ]

    update_captive_portal_observation "AUTHENTICATED"
    run should_exit_portal_mode
    [ "$status" -eq 0 ]
}

@test "observation thresholds are overridable via environment" {
    export OPENPATH_CAPTIVE_PORTAL_ENTER_THRESHOLD=1
    export OPENPATH_CAPTIVE_PORTAL_EXIT_THRESHOLD=3
    _source_portal_lib

    update_captive_portal_observation "PORTAL"
    run should_enter_portal_mode
    [ "$status" -eq 0 ]

    update_captive_portal_observation "AUTHENTICATED"
    update_captive_portal_observation "AUTHENTICATED"
    run should_exit_portal_mode
    [ "$status" -eq 1 ]
    update_captive_portal_observation "AUTHENTICATED"
    run should_exit_portal_mode
    [ "$status" -eq 0 ]
}

# ============== Split-DNS detection tests (WEDU root cause) ==============

@test "get_captive_portal_split_dns_hosts normalizes the declared list" {
    _source_portal_lib
    export CAPTIVE_PORTAL_SPLIT_DNS_HOSTS=" Portal.Example.COM. , login.wifi.lan ,"

    run get_captive_portal_split_dns_hosts
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "portal.example.com" ]
    [ "${lines[1]}" = "login.wifi.lan" ]
}

@test "get_captive_portal_split_dns_hosts fails when nothing is declared" {
    _source_portal_lib
    export CAPTIVE_PORTAL_SPLIT_DNS_HOSTS=""

    run get_captive_portal_split_dns_hosts
    [ "$status" -eq 1 ]
}

@test "dns_server_resolves_host compares answers, not transport" {
    _source_portal_lib

    timeout() { shift; "$@"; }
    export -f timeout

    # NXDOMAIN-style: dig exits 0 but prints no answer
    dig() { return 0; }
    export -f dig
    run dns_server_resolves_host "10.77.0.53" "portal.example.com"
    [ "$status" -eq 1 ]

    dig() { echo "10.77.0.10"; return 0; }
    export -f dig
    run dns_server_resolves_host "10.77.0.53" "portal.example.com"
    [ "$status" -eq 0 ]
}

@test "detect_split_dns_upstream finds the DHCP DNS that exclusively resolves the portal host" {
    _source_portal_lib
    export CAPTIVE_PORTAL_SPLIT_DNS_HOSTS="portal.example.com"

    get_dhcp_dns_servers() { echo "10.77.0.53"; }
    timeout() { shift; "$@"; }
    export -f timeout
    # Only the DHCP DNS (10.77.0.53) knows the portal host (WEDU topology)
    dig() {
        local server=""
        local arg
        for arg in "$@"; do
            case "$arg" in @*) server="${arg#@}" ;; esac
        done
        if [ "$server" = "10.77.0.53" ]; then
            echo "10.77.0.10"
        fi
        return 0
    }
    export -f dig

    run detect_split_dns_upstream "8.8.8.8"
    [ "$status" -eq 0 ]
    [ "$output" = "10.77.0.53" ]
}

@test "detect_split_dns_upstream reports no split when the upstream also resolves" {
    _source_portal_lib
    export CAPTIVE_PORTAL_SPLIT_DNS_HOSTS="portal.example.com"

    get_dhcp_dns_servers() { echo "10.77.0.53"; }
    timeout() { shift; "$@"; }
    export -f timeout
    dig() { echo "10.77.0.10"; return 0; }
    export -f dig

    run detect_split_dns_upstream "8.8.8.8"
    [ "$status" -eq 1 ]
}

@test "detect_split_dns_upstream degrades gracefully when DHCP DNS is unknown" {
    _source_portal_lib
    export CAPTIVE_PORTAL_SPLIT_DNS_HOSTS="portal.example.com"

    get_dhcp_dns_servers() { return 1; }

    run detect_split_dns_upstream "8.8.8.8"
    [ "$status" -eq 1 ]
}

@test "detect_split_dns_upstream is skipped when no portal hosts are declared" {
    _source_portal_lib
    export CAPTIVE_PORTAL_SPLIT_DNS_HOSTS=""

    get_dhcp_dns_servers() { echo "10.77.0.53"; }

    run detect_split_dns_upstream "8.8.8.8"
    [ "$status" -eq 1 ]
}

@test "enter_portal_mode_locked prefers the split-DNS upstream for passthrough" {
    _source_portal_lib
    export CAPTIVE_PORTAL_SPLIT_DNS_HOSTS="portal.example.com"
    export DNSMASQ_CONF="$TEST_TMP_DIR/openpath.conf"

    detect_primary_dns() { echo "8.8.8.8"; }
    get_dhcp_dns_servers() { echo "10.77.0.53"; }
    timeout() { shift; "$@"; }
    export -f timeout
    dig() {
        local server=""
        local arg
        for arg in "$@"; do
            case "$arg" in @*) server="${arg#@}" ;; esac
        done
        [ "$server" = "10.77.0.53" ] && echo "10.77.0.10"
        return 0
    }
    export -f dig
    write_dnsmasq_passthrough_config() { echo "PASSTHROUGH_UPSTREAM=$1"; return 0; }
    restart_dnsmasq() { return 0; }
    deactivate_firewall() { :; }
    flush_connections() { :; }

    run enter_portal_mode_locked
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASSTHROUGH_UPSTREAM=10.77.0.53"* ]]
    [[ "$output" == *"Split DNS detected"* ]]
    [ -f "$VAR_STATE_DIR/captive-portal-active.state" ]
    grep -q '^expires=' "$VAR_STATE_DIR/captive-portal-active.state"
}

@test "enter_portal_mode_locked keeps the detected upstream when no split DNS" {
    _source_portal_lib
    export CAPTIVE_PORTAL_SPLIT_DNS_HOSTS=""
    export DNSMASQ_CONF="$TEST_TMP_DIR/openpath.conf"

    detect_primary_dns() { echo "8.8.8.8"; }
    write_dnsmasq_passthrough_config() { echo "PASSTHROUGH_UPSTREAM=$1"; return 0; }
    restart_dnsmasq() { return 0; }
    deactivate_firewall() { :; }
    flush_connections() { :; }

    run enter_portal_mode_locked
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASSTHROUGH_UPSTREAM=8.8.8.8"* ]]
    grep -q '^expires=' "$VAR_STATE_DIR/captive-portal-active.state"
}

# ============== DHCP DNS discovery tests ==============

@test "get_dhcp_dns_servers reads systemd-resolved upstream list and filters loopback" {
    _source_portal_lib

    cat > "$TEST_TMP_DIR/resolved.conf" << 'EOF'
# This is /run/systemd/resolve/resolv.conf style content
nameserver 10.77.0.53
nameserver 127.0.0.1
nameserver 10.77.0.53
EOF
    export OPENPATH_SYSTEMD_RESOLV_CONF="$TEST_TMP_DIR/resolved.conf"
    export OPENPATH_DHCLIENT_LEASE_DIR="$TEST_TMP_DIR/no-leases"
    nmcli() { :; }
    export -f nmcli

    run get_dhcp_dns_servers
    [ "$status" -eq 0 ]
    [ "$output" = "10.77.0.53" ]
}

@test "get_dhcp_dns_servers falls back to dhclient leases" {
    _source_portal_lib

    mkdir -p "$TEST_TMP_DIR/leases"
    cat > "$TEST_TMP_DIR/leases/dhclient.eth0.leases" << 'EOF'
lease {
  interface "eth0";
  option domain-name-servers 192.168.8.1, 192.168.8.2;
}
lease {
  interface "eth0";
  option domain-name-servers 10.77.0.53;
}
EOF
    export OPENPATH_SYSTEMD_RESOLV_CONF="$TEST_TMP_DIR/missing-resolved.conf"
    export OPENPATH_DHCLIENT_LEASE_DIR="$TEST_TMP_DIR/leases"
    nmcli() { :; }
    export -f nmcli

    run get_dhcp_dns_servers
    [ "$status" -eq 0 ]
    [ "$output" = "10.77.0.53" ]
}

@test "get_dhcp_dns_servers falls back to NetworkManager" {
    _source_portal_lib

    export OPENPATH_SYSTEMD_RESOLV_CONF="$TEST_TMP_DIR/missing-resolved.conf"
    export OPENPATH_DHCLIENT_LEASE_DIR="$TEST_TMP_DIR/no-leases"
    nmcli() {
        printf 'IP4.DNS[1]:                             10.77.0.53\n'
        printf 'IP4.DNS[2]:                             10.77.0.54\n'
    }
    export -f nmcli

    run get_dhcp_dns_servers
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "10.77.0.53" ]
    [ "${lines[1]}" = "10.77.0.54" ]
}

@test "get_dhcp_dns_servers returns 1 when no DHCP DNS can be determined" {
    _source_portal_lib

    export OPENPATH_SYSTEMD_RESOLV_CONF="$TEST_TMP_DIR/missing-resolved.conf"
    export OPENPATH_DHCLIENT_LEASE_DIR="$TEST_TMP_DIR/no-leases"
    nmcli() { :; }
    export -f nmcli

    run get_dhcp_dns_servers
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# ============== Detector anti-oscillation defaults ==============

@test "defaults.conf exposes the WEDU portal knobs with Windows-parity defaults" {
    source "$PROJECT_DIR/linux/lib/defaults.conf"

    [ "$CAPTIVE_PORTAL_TTL_SECONDS" = "120" ]
    [ "$CAPTIVE_PORTAL_ENTER_THRESHOLD" = "2" ]
    [ "$CAPTIVE_PORTAL_EXIT_THRESHOLD" = "1" ]
    [ "${CAPTIVE_PORTAL_SPLIT_DNS_HOSTS}" = "" ]
}

# ============== Absolute lifetime cap tests ==============

@test "defaults.conf exposes CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS with default 1800" {
    source "$PROJECT_DIR/linux/lib/defaults.conf"

    [ "$CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS" = "1800" ]
}

@test "write_portal_mode_marker clamps expires to start_ts + MAX_LIFETIME" {
    _source_portal_lib
    export CAPTIVE_PORTAL_TTL_SECONDS=120
    export CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS=60

    # start_ts 70 seconds ago -> hard_deadline = start_ts + 60 = 10 seconds ago
    local start_ts
    start_ts=$(( $(date +%s) - 70 ))
    write_portal_mode_marker "$start_ts"

    local expiry hard_deadline now
    now=$(date +%s)
    expiry=$(get_portal_mode_expiry_ts)
    hard_deadline=$(( start_ts + 60 ))

    # expires must equal hard_deadline (clamped), not now+ttl
    [ "$expiry" -eq "$hard_deadline" ]
}

@test "refresh_portal_mode_expiry does NOT re-arm when elapsed >= MAX_LIFETIME and forces close" {
    _source_portal_lib
    export CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS=60

    # Marker started 61 seconds ago (past the cap)
    local start_ts
    start_ts=$(( $(date +%s) - 61 ))
    printf '%s\nexpires=%s\n' "$start_ts" "$(($(date +%s) + 60))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"

    with_openpath_lock() { "$@"; }
    exit_portal_mode_locked() {
        rm -f "$CAPTIVE_PORTAL_STATE_FILE"
        echo "EXIT_PORTAL_MODE_CALLED"
    }

    run refresh_portal_mode_expiry
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT_PORTAL_MODE_CALLED"* ]]
    # Marker must be gone after the forced close
    [ ! -f "$CAPTIVE_PORTAL_STATE_FILE" ]
}

@test "refresh_portal_mode_expiry extends expiry when elapsed < MAX_LIFETIME" {
    _source_portal_lib
    export CAPTIVE_PORTAL_TTL_SECONDS=120
    export CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS=1800

    local start_ts old_expiry new_expiry
    start_ts=$(( $(date +%s) - 60 ))
    printf '%s\nexpires=%s\n' "$start_ts" "$(($(date +%s) + 1))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"
    old_expiry=$(get_portal_mode_expiry_ts)

    # refresh should succeed and extend the deadline (60s elapsed < 1800s cap)
    with_openpath_lock() { "$@"; }
    exit_portal_mode_locked() { echo "EXIT_PORTAL_MODE_CALLED"; }

    run refresh_portal_mode_expiry
    [ "$status" -eq 0 ]
    [[ "$output" != *"EXIT_PORTAL_MODE_CALLED"* ]]
    new_expiry=$(get_portal_mode_expiry_ts)
    [ "$new_expiry" -gt "$old_expiry" ]
}

@test "refresh_portal_mode_expiry new expiry never exceeds hard deadline" {
    _source_portal_lib
    export CAPTIVE_PORTAL_TTL_SECONDS=120
    export CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS=90

    # started 30 seconds ago -> 60 seconds until deadline; ttl=120 would overshoot
    local start_ts hard_deadline new_expiry
    start_ts=$(( $(date +%s) - 30 ))
    hard_deadline=$(( start_ts + 90 ))
    printf '%s\nexpires=%s\n' "$start_ts" "$(($(date +%s) + 1))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"

    with_openpath_lock() { "$@"; }
    exit_portal_mode_locked() { echo "EXIT_PORTAL_MODE_CALLED"; }

    run refresh_portal_mode_expiry
    [ "$status" -eq 0 ]
    [[ "$output" != *"EXIT_PORTAL_MODE_CALLED"* ]]
    new_expiry=$(get_portal_mode_expiry_ts)
    [ "$new_expiry" -le "$hard_deadline" ]
}

# ============== Clock-jump / monotonic lifetime cap (F-E) ==============

@test "write_portal_mode_marker persists a monotonic reference" {
    _source_portal_lib

    write_portal_mode_marker "$(date +%s)"

    # mono_start= is written from /proc/uptime on hosts that have it.
    if [ -r /proc/uptime ]; then
        run get_portal_mode_mono_start_ts
        [ "$status" -eq 0 ]
        [[ "$output" =~ ^[0-9]+$ ]]
    fi
}

@test "refresh_portal_mode_expiry forces close on a backward wall-clock jump (fail-closed)" {
    _source_portal_lib
    export CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS=1800

    # start_ts in the FUTURE simulates the wall clock having jumped backward
    # since the marker was written (now - start_ts < 0).
    local start_ts
    start_ts=$(( $(date +%s) + 600 ))
    printf '%s\nexpires=%s\n' "$start_ts" "$(($(date +%s) + 300))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"

    with_openpath_lock() { "$@"; }
    exit_portal_mode_locked() {
        rm -f "$CAPTIVE_PORTAL_STATE_FILE"
        echo "EXIT_PORTAL_MODE_CALLED"
    }

    run refresh_portal_mode_expiry
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT_PORTAL_MODE_CALLED"* ]]
    [[ "$output" == *"clock jumped backward"* ]]
    [ ! -f "$CAPTIVE_PORTAL_STATE_FILE" ]
}

@test "refresh_portal_mode_expiry caps on monotonic elapsed even when wall clock looks fresh" {
    _source_portal_lib
    export CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS=60

    # Wall clock says only 1s elapsed (start_ts = now-1), but the stored
    # monotonic reference is far in the past, so monotonic elapsed > cap. The
    # cap must fire on the monotonic source.
    local start_ts now
    now=$(date +%s)
    start_ts=$(( now - 1 ))

    # Mock the monotonic source: pretend uptime advanced 1000s past mono_start=5.
    read_monotonic_seconds() { echo 1005; }
    export -f read_monotonic_seconds

    printf '%s\nexpires=%s\nmono_start=5\n' "$start_ts" "$(( now + 300 ))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"

    with_openpath_lock() { "$@"; }
    exit_portal_mode_locked() {
        rm -f "$CAPTIVE_PORTAL_STATE_FILE"
        echo "EXIT_PORTAL_MODE_CALLED"
    }

    run refresh_portal_mode_expiry
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT_PORTAL_MODE_CALLED"* ]]
    [[ "$output" == *"absolute lifetime cap reached"* ]]
}

# ============== Re-entry cooldown + observation reset (F-F) ==============

@test "should_enter_portal_mode refuses re-entry during the cooldown window" {
    _source_portal_lib
    export CAPTIVE_PORTAL_REENTRY_COOLDOWN_SECONDS=300
    export CAPTIVE_PORTAL_ENTER_THRESHOLD=1

    # Enough PORTAL observations to normally enter...
    update_captive_portal_observation "PORTAL"
    run should_enter_portal_mode
    [ "$status" -eq 0 ]

    # ...but a recent forced close records a cooldown that blocks re-entry.
    record_portal_reentry_cooldown
    run should_enter_portal_mode
    [ "$status" -eq 1 ]
}

@test "portal_reentry_cooldown_active expires after the cooldown window" {
    _source_portal_lib
    export CAPTIVE_PORTAL_REENTRY_COOLDOWN_SECONDS=60

    # Cooldown recorded 120s ago -> window elapsed.
    printf '%s\n' "$(( $(date +%s) - 120 ))" > "$CAPTIVE_PORTAL_COOLDOWN_FILE"
    run portal_reentry_cooldown_active
    [ "$status" -eq 1 ]

    # Cooldown recorded 10s ago -> still active.
    printf '%s\n' "$(( $(date +%s) - 10 ))" > "$CAPTIVE_PORTAL_COOLDOWN_FILE"
    run portal_reentry_cooldown_active
    [ "$status" -eq 0 ]
}

@test "portal_reentry_cooldown_active treats a backward clock jump as active (fail-closed)" {
    _source_portal_lib
    export CAPTIVE_PORTAL_REENTRY_COOLDOWN_SECONDS=60

    # Cooldown timestamp in the future (clock jumped back since the close).
    printf '%s\n' "$(( $(date +%s) + 120 ))" > "$CAPTIVE_PORTAL_COOLDOWN_FILE"
    run portal_reentry_cooldown_active
    [ "$status" -eq 0 ]
}

@test "cooldown is disabled when CAPTIVE_PORTAL_REENTRY_COOLDOWN_SECONDS=0" {
    _source_portal_lib
    export CAPTIVE_PORTAL_REENTRY_COOLDOWN_SECONDS=0

    record_portal_reentry_cooldown
    run portal_reentry_cooldown_active
    [ "$status" -eq 1 ]
}

@test "reset_captive_portal_observation zeroes both counters" {
    _source_portal_lib

    update_captive_portal_observation "PORTAL"
    update_captive_portal_observation "PORTAL"
    [ "$(get_captive_portal_observation_count portal)" -eq 2 ]

    reset_captive_portal_observation
    [ "$(get_captive_portal_observation_count portal)" -eq 0 ]
    [ "$(get_captive_portal_observation_count authenticated)" -eq 0 ]
}

@test "refresh_portal_mode_expiry records a re-entry cooldown when it force-closes on the cap" {
    _source_portal_lib
    export CAPTIVE_PORTAL_MAX_LIFETIME_SECONDS=60

    local start_ts
    start_ts=$(( $(date +%s) - 61 ))
    printf '%s\nexpires=%s\n' "$start_ts" "$(($(date +%s) + 60))" \
        > "$CAPTIVE_PORTAL_STATE_FILE"

    with_openpath_lock() { "$@"; }
    exit_portal_mode_locked() { rm -f "$CAPTIVE_PORTAL_STATE_FILE"; }

    run refresh_portal_mode_expiry
    [ "$status" -eq 0 ]
    [ -f "$CAPTIVE_PORTAL_COOLDOWN_FILE" ]
}

# ============== Scoped passthrough flag (F-G, default off) ==============

@test "defaults.conf ships scoped passthrough OFF by default" {
    source "$PROJECT_DIR/linux/lib/defaults.conf"
    [ "$CAPTIVE_PORTAL_SCOPED_PASSTHROUGH_ENABLED" = "0" ]
}

@test "apply_captive_portal_passthrough_firewall deactivates the firewall when scoped passthrough is off (default)" {
    _source_portal_lib
    unset CAPTIVE_PORTAL_SCOPED_PASSTHROUGH_ENABLED

    deactivate_firewall() { echo "MOCK_DEACTIVATE"; }
    activate_firewall() { echo "MOCK_ACTIVATE"; }

    run apply_captive_portal_passthrough_firewall
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK_DEACTIVATE"* ]]
    [[ "$output" != *"MOCK_ACTIVATE"* ]]
}

@test "apply_captive_portal_passthrough_firewall keeps the firewall active when scoped passthrough is enabled" {
    _source_portal_lib
    export CAPTIVE_PORTAL_SCOPED_PASSTHROUGH_ENABLED=1

    deactivate_firewall() { echo "MOCK_DEACTIVATE"; }
    activate_firewall() { echo "MOCK_ACTIVATE"; }

    run apply_captive_portal_passthrough_firewall
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK_ACTIVATE"* ]]
    [[ "$output" != *"MOCK_DEACTIVATE"* ]]
}
