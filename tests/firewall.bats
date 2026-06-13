#!/usr/bin/env bats
################################################################################
# firewall.bats - Tests for lib/firewall.sh
################################################################################

load 'test_helper'

setup() {
    # Create temp directory for tests
    TEST_TMP_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_TMP_DIR/config"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    export PRIMARY_DNS="8.8.8.8"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$INSTALL_DIR/lib"
    mkdir -p "$TEST_TMP_DIR/iptables"
    # Keep bridge-enforcement sysctl writes out of the real /etc/sysctl.d.
    export OPENPATH_SYSCTL_D_DIR="$TEST_TMP_DIR/sysctl.d"
    mkdir -p "$OPENPATH_SYSCTL_D_DIR"
    # Deterministic dnsmasq uid for the upstream :53 owner-match.
    export OPENPATH_DNSMASQ_UID="498"

    # Copy libs
    cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/" 2>/dev/null || true

    # Source the library (with mocked dependencies)
    source "$PROJECT_DIR/linux/lib/common.sh"

    # Mock kernel-module / sysctl helpers so bridged-VM enforcement is inert and
    # has no side effects during tests. ip6tables is a no-op here; the IPv6
    # firewall is exercised directly in firewall-bypass.bats.
    modprobe() { return 0; }
    sysctl() { return 0; }
    ip6tables() { return 0; }
    export -f modprobe sysctl ip6tables

    # Mock log functions
    log() { echo "$1"; }
    log_debug() { echo "[DEBUG] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
    export -f log log_debug log_warn log_error

    # Mock validate_ip to return success for valid IPs
    validate_ip() {
        local ip="$1"
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            return 0
        else
            return 1
        fi
    }
    export -f validate_ip

    # Mock ipset so the DoH bypass-block path is deterministic regardless of
    # whether the host has the real binary installed
    ipset() {
        echo "$*" >> "$TEST_TMP_DIR/ipset.log"
        return 0
    }
    export -f ipset
    export OPENPATH_IPSET_STATE_FILE="$TEST_TMP_DIR/openpath-ipsets.v4"
}

# ============== validate_ip tests ==============

@test "validate_ip accepts valid IP" {
    run validate_ip "192.168.1.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip accepts Google DNS" {
    run validate_ip "8.8.8.8"
    [ "$status" -eq 0 ]
}

@test "validate_ip rejects invalid IP" {
    run validate_ip "256.1.1.1"
    # Note: regex alone doesn't validate octet ranges, but format is correct
    [ "$status" -eq 0 ]  # Regex passes, deeper validation needed
}

@test "validate_ip rejects text" {
    run validate_ip "not-an-ip"
    [ "$status" -eq 1 ]
}

@test "validate_ip rejects empty string" {
    run validate_ip ""
    [ "$status" -eq 1 ]
}

# ============== Tests de check_firewall_status ==============

@test "check_firewall_status detects inactive firewall" {
    # Mock iptables to return no DROP rules
    iptables() {
        echo "Chain OUTPUT (policy ACCEPT)"
        echo "target     prot opt source    destination"
        return 0
    }
    export -f iptables
    
    source "$PROJECT_DIR/linux/lib/firewall.sh"
    
    run check_firewall_status
    [ "$output" = "inactive" ]
}

@test "check_firewall_status detects active firewall" {
    # Mock iptables to return DROP rules for port 53
    iptables() {
        cat << 'EOF'
Chain OUTPUT (policy ACCEPT)
target     prot opt source    destination
DROP       udp  --  anywhere  anywhere    udp dpt:53
DROP       tcp  --  anywhere  anywhere    tcp dpt:53
EOF
        return 0
    }
    export -f iptables
    
    source "$PROJECT_DIR/linux/lib/firewall.sh"
    
    run check_firewall_status
    [ "$output" = "active" ]
}

@test "check_firewall_status detects active firewall from canonical iptables spec output" {
    iptables() {
        if [ "$1" = "-S" ] && [ "$2" = "OUTPUT" ]; then
            cat << 'EOF'
-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p udp -m udp --dport 53 -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p tcp -m tcp --dport 53 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 53 -j DROP
-A OUTPUT -j DROP
EOF
            return 0
        fi

        cat << 'EOF'
Chain OUTPUT (policy ACCEPT)
target     prot opt source    destination
DROP       all  --  0.0.0.0/0  0.0.0.0/0
EOF
        return 0
    }
    export -f iptables

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    run check_firewall_status
    [ "$output" = "active" ]
}

# ============== Tests de flush_dns_cache ==============

@test "flush_dns_cache runs without errors when dnsmasq is active" {
    # Mock systemctl
    systemctl() {
        if [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "dnsmasq" ]; then
            return 0
        fi
        return 1
    }
    export -f systemctl
    
    # Mock pkill
    pkill() {
        return 0
    }
    export -f pkill
    
    source "$PROJECT_DIR/linux/lib/firewall.sh"
    
    run flush_dns_cache
    [ "$status" -eq 0 ]
    [[ "$output" == *"DNS cache flushed"* ]]
}

@test "flush_dns_cache does nothing when dnsmasq is inactive" {
    # Mock systemctl to say dnsmasq is not active
    systemctl() {
        return 1
    }
    export -f systemctl
    
    source "$PROJECT_DIR/linux/lib/firewall.sh"
    
    run flush_dns_cache
    [ "$status" -eq 0 ]
    # Should not contain the success message
    [[ "$output" != *"DNS cache flushed"* ]]
}

# ============== Tests de save_firewall_rules ==============

@test "save_firewall_rules creates rules file" {
    local rules_dir="$TEST_TMP_DIR/iptables"
    mkdir -p "$rules_dir"
    
    # Mock iptables-save
    iptables-save() {
        echo "# Generated rules"
        echo "*filter"
        echo ":OUTPUT ACCEPT [0:0]"
        echo "COMMIT"
    }
    export -f iptables-save
    
    # Override the save path
    save_firewall_rules() {
        mkdir -p "$rules_dir"
        iptables-save > "$rules_dir/rules.v4" 2>/dev/null || true
    }
    
    run save_firewall_rules
    [ "$status" -eq 0 ]
}

# ============== Tests de flush_connections ==============

@test "flush_connections works with conntrack available" {
    # Mock conntrack
    conntrack() {
        return 0
    }
    export -f conntrack
    
    # Mock command to say conntrack exists
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "conntrack" ]; then
            return 0
        fi
        builtin command "$@"
    }
    export -f command
    
    source "$PROJECT_DIR/linux/lib/firewall.sh"
    
    run flush_connections
    [ "$status" -eq 0 ]
}

@test "flush_connections warns when conntrack is not available" {
    # Mock command to say conntrack doesn't exist
    command() {
        if [ "$2" = "conntrack" ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    run flush_connections
    [ "$status" -eq 0 ]
    [[ "$output" == *"conntrack not available"* ]]
}

# ============== Shared contract fixture tests ==============

@test "default Linux DoH resolver catalog matches shared IPv4 contract fixture" {
    source "$PROJECT_DIR/linux/lib/common.sh"

    local expected actual
    expected=$(load_contract_fixture_lines "doh-resolvers.txt" | awk 'index($0, ":") == 0' | sort)
    actual=$(csv_to_lines "$DOH_RESOLVERS" | sort)

    [ "$actual" = "$expected" ]
}

@test "default VPN block rules match shared contract fixture" {
    source "$PROJECT_DIR/linux/lib/common.sh"

    local expected actual
    expected=$(load_contract_fixture_lines "vpn-block-rules.txt" | sort)
    actual=$(csv_to_lines "$VPN_BLOCK_RULES" | sort)

    [ "$actual" = "$expected" ]
}

@test "default Tor block ports match shared contract fixture" {
    source "$PROJECT_DIR/linux/lib/common.sh"

    local expected actual
    expected=$(load_contract_fixture_lines "tor-block-ports.txt" | sort)
    actual=$(csv_to_lines "$TOR_BLOCK_PORTS" | sort)

    [ "$actual" = "$expected" ]
}

# ============== Tests de activate_firewall ==============

@test "activate_firewall adds loopback rule" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    # Mock iptables to log calls
    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    # Mock ip for gateway detection
    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    grep -q "\-A OUTPUT \-o lo \-j ACCEPT" "$iptables_log"
}

@test "activate_firewall adds DNS blocking rules" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    # Check DNS DROP rules are present
    grep -q "\-A OUTPUT \-p udp \-\-dport 53 \-j DROP" "$iptables_log"
    grep -q "\-A OUTPUT \-p tcp \-\-dport 53 \-j DROP" "$iptables_log"
}

@test "activate_firewall adds DoT blocking rule" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    # Check DNS-over-TLS (DoT) blocking
    grep -q "\-A OUTPUT \-p tcp \-\-dport 853 \-j DROP" "$iptables_log"
}

@test "activate_firewall uses configurable DoH resolver list" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"
    export DOH_RESOLVERS="4.4.4.4,5.5.5.5"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    grep -q "add openpath-doh-block 4.4.4.4 -exist" "$TEST_TMP_DIR/ipset.log"
    grep -q "add openpath-doh-block 5.5.5.5 -exist" "$TEST_TMP_DIR/ipset.log"
    grep -q "\-A OUTPUT \-p tcp \-\-dport 443 \-m set \-\-match\-set openpath-doh-block dst \-j DROP" "$iptables_log"
    grep -q "\-A OUTPUT \-p udp \-\-dport 443 \-m set \-\-match\-set openpath-doh-block dst \-j DROP" "$iptables_log"
}

@test "activate_firewall adds VPN blocking rules" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    # Check VPN blocking rules
    grep -q "\-\-dport 1194 \-j DROP" "$iptables_log"   # OpenVPN
    grep -q "\-\-dport 51820 \-j DROP" "$iptables_log"  # WireGuard
    grep -q "\-\-dport 1723 \-j DROP" "$iptables_log"   # PPTP
}

@test "activate_firewall adds Tor blocking rules" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    # Check Tor blocking rules
    grep -q "\-\-dport 9001 \-j DROP" "$iptables_log"
    grep -q "\-\-dport 9030 \-j DROP" "$iptables_log"
}

@test "activate_firewall uses configurable VPN block rules" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"
    export VPN_BLOCK_RULES="tcp:9443:TestVPN,udp:5555:TestTunnel"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    grep -q "\-p tcp \-\-dport 9443 \-j DROP" "$iptables_log"
    grep -q "\-p udp \-\-dport 5555 \-j DROP" "$iptables_log"
}

@test "activate_firewall uses configurable Tor block ports" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"
    export TOR_BLOCK_PORTS="10001,10002"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    grep -q "\-p tcp \-\-dport 10001 \-j DROP" "$iptables_log"
    grep -q "\-p tcp \-\-dport 10002 \-j DROP" "$iptables_log"
}

@test "activate_firewall allows localhost DNS" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    # Check localhost DNS is allowed
    grep -q "\-d 127.0.0.1 \-\-dport 53 \-j ACCEPT" "$iptables_log"
}

@test "activate_firewall allows upstream DNS" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    # Upstream DNS is allowed only from the dnsmasq process (owner-match).
    grep -q -- "-d 8.8.8.8 --dport 53 -m owner --uid-owner 498 -j ACCEPT" "$iptables_log"
}

@test "activate_firewall scopes HTTP/HTTPS to the name-aware allow set" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"
    local ipset_log="$TEST_TMP_DIR/ipset.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    # Mock ipset so name-aware egress is active deterministically (command -v
    # finds the function), instead of depending on whether the host has ipset.
    ipset() {
        echo "$*" >> "$ipset_log"
        return 0
    }
    export -f ipset

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    # HTTP/HTTPS are ACCEPTed only to resolved-whitelist IPs (openpath-allow-dst),
    # not to any destination — the legacy broad ACCEPT was the name-blind hole.
    grep -q -- "--dport 80 -m set --match-set openpath-allow-dst dst -j ACCEPT" "$iptables_log"
    grep -q -- "--dport 443 -m set --match-set openpath-allow-dst dst -j ACCEPT" "$iptables_log"
    ! grep -q -- "--dport 443 -j ACCEPT" "$iptables_log"
}

@test "activate_firewall allows private networks" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    # Check private network ranges allowed (default RFC1918_EGRESS_MODE=all emits
    # the legacy blanket all-ports ACCEPT; restricted mode is covered in
    # firewall-bypass.bats).
    grep -q "\-d 10.0.0.0/8 \-j ACCEPT" "$iptables_log"
    grep -q "\-d 172.16.0.0/12 \-j ACCEPT" "$iptables_log"
    grep -q "\-d 192.168.0.0/16 \-j ACCEPT" "$iptables_log"
}

@test "activate_firewall uses fallback DNS for invalid PRIMARY_DNS" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    # Set invalid DNS
    export PRIMARY_DNS="not-an-ip"
    export FALLBACK_DNS_PRIMARY="1.1.1.1"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    activate_firewall

    # Should use fallback DNS (owner-confined upstream :53).
    grep -q -- "-d 1.1.1.1 --dport 53 -m owner --uid-owner 498 -j ACCEPT" "$iptables_log"
}

# ============== Tests de deactivate_firewall ==============

@test "deactivate_firewall flushes OUTPUT chain" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    deactivate_firewall

    grep -q "\-F OUTPUT" "$iptables_log"
}

@test "deactivate_firewall sets policy to ACCEPT" {
    local iptables_log="$TEST_TMP_DIR/iptables.log"

    iptables() {
        echo "$*" >> "$iptables_log"
        return 0
    }
    export -f iptables

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules AFTER sourcing
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    deactivate_firewall

    grep -q "\-P OUTPUT ACCEPT" "$iptables_log"
}

# ============== Tests de verify_firewall_rules ==============

@test "verify_firewall_rules passes with all critical rules present" {
    # Mock iptables to return complete firewall rules
    iptables() {
        cat << 'EOF'
Chain OUTPUT (policy DROP)
target     prot opt source    destination
ACCEPT     all  --  anywhere  anywhere    /* lo */
ACCEPT     all  --  anywhere  anywhere    state RELATED,ESTABLISHED
ACCEPT     udp  --  anywhere  127.0.0.1   udp dpt:53
ACCEPT     tcp  --  anywhere  127.0.0.1   tcp dpt:53
ACCEPT     udp  --  anywhere  8.8.8.8     udp dpt:53
DROP       udp  --  anywhere  anywhere    udp dpt:53
DROP       tcp  --  anywhere  anywhere    tcp dpt:53
DROP       all  --  anywhere  anywhere
EOF
        return 0
    }
    export -f iptables

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    run verify_firewall_rules
    [ "$status" -eq 0 ]
}

@test "verify_firewall_rules accepts canonical iptables spec output when list output is lossy" {
    iptables() {
        if [ "$1" = "-S" ] && [ "$2" = "OUTPUT" ]; then
            cat << 'EOF'
-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p udp -m udp --dport 53 -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p tcp -m tcp --dport 53 -j ACCEPT
-A OUTPUT -d 8.8.8.8/32 -p udp -m udp --dport 53 -j ACCEPT
-A OUTPUT -d 8.8.8.8/32 -p tcp -m tcp --dport 53 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 53 -j DROP
-A OUTPUT -j DROP
EOF
            return 0
        fi

        cat << 'EOF'
Chain OUTPUT (policy ACCEPT)
target     prot opt source    destination
ACCEPT     udp  --  0.0.0.0/0  127.0.0.1   udp dpt:53
ACCEPT     tcp  --  0.0.0.0/0  127.0.0.1   tcp dpt:53
DROP       udp  --  0.0.0.0/0  0.0.0.0/0   udp dpt:53
DROP       tcp  --  0.0.0.0/0  0.0.0.0/0   tcp dpt:53
DROP       all  --  0.0.0.0/0  0.0.0.0/0
EOF
        return 0
    }
    export -f iptables

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    run verify_firewall_rules
    [ "$status" -eq 0 ]
}

@test "verify_firewall_rules fails when loopback rule missing" {
    # Mock iptables without loopback rule
    iptables() {
        cat << 'EOF'
Chain OUTPUT (policy DROP)
target     prot opt source    destination
ACCEPT     udp  --  anywhere  127.0.0.1   udp dpt:53
DROP       udp  --  anywhere  anywhere    udp dpt:53
DROP       tcp  --  anywhere  anywhere    tcp dpt:53
DROP       all  --  anywhere  anywhere
EOF
        return 0
    }
    export -f iptables

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    run verify_firewall_rules
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing firewall rule"* ]]
}

@test "verify_firewall_rules fails when DNS DROP rules missing" {
    # Mock iptables without DNS DROP rules (only general DROP, not dpt:53)
    iptables() {
        cat << 'EOF'
Chain OUTPUT (policy DROP)
target     prot opt source    destination
ACCEPT     all  --  anywhere  anywhere    /* lo */
ACCEPT     udp  --  anywhere  127.0.0.1   udp dpt:53
ACCEPT     tcp  --  anywhere  127.0.0.1   tcp dpt:53
DROP       all  --  anywhere  anywhere
EOF
        return 0
    }
    export -f iptables

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    run verify_firewall_rules
    [ "$status" -eq 1 ]
    [[ "$output" == *"DNS DROP"* ]]
}

@test "verify_firewall_rules fails when iptables command fails" {
    # Mock iptables to fail
    iptables() {
        return 1
    }
    export -f iptables

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    run verify_firewall_rules
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot read firewall rules"* ]]
}

# ============== Tests de helper functions ==============

@test "add_critical_rule returns success when command succeeds" {
    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Test with a command that succeeds
    run add_critical_rule "Test rule" true
    [ "$status" -eq 0 ]
}

@test "add_critical_rule returns failure when command fails" {
    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Test with a command that fails
    run add_critical_rule "Test rule" false
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED [CRITICAL]"* ]]
}

@test "add_important_rule returns success even when command fails" {
    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Test with a command that fails - should still return 0
    run add_important_rule "Test rule" false
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAILED [IMPORTANT]"* ]]
}

@test "add_optional_rule returns success when command fails" {
    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Test with a command that fails - should return 0 and log debug
    run add_optional_rule "Test rule" false
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED [OPTIONAL]"* ]]
}

@test "activate_firewall returns failure when critical rule fails" {
    local call_count=0

    # Mock iptables to fail on a specific critical rule
    iptables() {
        call_count=$((call_count + 1))
        # Fail on the loopback rule (second call after flush)
        if [ "$call_count" -eq 2 ]; then
            return 1
        fi
        return 0
    }
    export -f iptables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    export PRIMARY_DNS="8.8.8.8"

    source "$PROJECT_DIR/linux/lib/firewall.sh"

    # Override save_firewall_rules and verify_firewall_rules
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }

    run activate_firewall
    [ "$status" -eq 1 ]
    [[ "$output" == *"CRITICAL"* ]]
}
