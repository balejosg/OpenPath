#!/usr/bin/env bats
################################################################################
# firewall-bypass.bats - DoH/VPN/Tor bypass-vector blocking
# (lib/firewall-rule-helpers.sh, lib/firewall-runtime.sh, lib/firewall-snapshot.sh)
################################################################################

load 'test_helper'

setup() {
    TEST_TMP_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_TMP_DIR/config"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    export PRIMARY_DNS="8.8.8.8"
    mkdir -p "$CONFIG_DIR" "$INSTALL_DIR/lib"

    IPTABLES_LOG="$TEST_TMP_DIR/iptables.log"
    IP6TABLES_LOG="$TEST_TMP_DIR/ip6tables.log"
    IPSET_LOG="$TEST_TMP_DIR/ipset.log"
    export IPTABLES_LOG IP6TABLES_LOG IPSET_LOG
    export OPENPATH_IPSET_STATE_FILE="$TEST_TMP_DIR/openpath-ipsets.v4"
    export OPENPATH_SYSCTL_D_DIR="$TEST_TMP_DIR/sysctl.d"
    mkdir -p "$OPENPATH_SYSCTL_D_DIR"
    # Deterministic dnsmasq uid so upstream :53 owner-match is testable without
    # depending on whether a 'dnsmasq' account exists on the test host.
    export OPENPATH_DNSMASQ_UID="498"

    source "$PROJECT_DIR/linux/lib/common.sh"

    # Mock log functions
    log() { echo "$1"; }
    log_debug() { echo "[DEBUG] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
    export -f log log_debug log_warn log_error

    validate_ip() {
        local ip="$1"
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
    }
    export -f validate_ip

    iptables() {
        echo "$*" >> "$IPTABLES_LOG"
        return 0
    }
    export -f iptables

    ipset() {
        echo "$*" >> "$IPSET_LOG"
        return 0
    }
    export -f ipset

    ip6tables() {
        echo "$*" >> "$IP6TABLES_LOG"
        return 0
    }
    export -f ip6tables

    ip() {
        echo "default via 192.168.1.1 dev eth0"
    }
    export -f ip

    MODPROBE_LOG="$TEST_TMP_DIR/modprobe.log"
    SYSCTL_LOG="$TEST_TMP_DIR/sysctl.log"
    export MODPROBE_LOG SYSCTL_LOG

    modprobe() {
        echo "$*" >> "$MODPROBE_LOG"
        return 0
    }
    export -f modprobe

    sysctl() {
        echo "$*" >> "$SYSCTL_LOG"
        return 0
    }
    export -f sysctl
}

source_firewall() {
    source "$PROJECT_DIR/linux/lib/firewall.sh"
    save_firewall_rules() { return 0; }
    verify_firewall_rules() { return 0; }
}

# ============== DoH block rule builder ==============

@test "apply_doh_block_rules populates the openpath-doh-block ipset with the default catalog" {
    source_firewall

    apply_doh_block_rules

    grep -q "create openpath-doh-block hash:ip -exist" "$IPSET_LOG"
    grep -q "flush openpath-doh-block" "$IPSET_LOG"
    # Spot-check IPv4 entries from the shared Windows/Linux catalog
    grep -q "add openpath-doh-block 8.8.8.8 -exist" "$IPSET_LOG"
    grep -q "add openpath-doh-block 1.1.1.1 -exist" "$IPSET_LOG"
    grep -q "add openpath-doh-block 9.9.9.9 -exist" "$IPSET_LOG"
    grep -q "add openpath-doh-block 94.140.14.14 -exist" "$IPSET_LOG"
    grep -q "add openpath-doh-block 76.76.10.0 -exist" "$IPSET_LOG"
}

@test "apply_doh_block_rules adds set-scoped 443 DROP rules for TCP and UDP" {
    source_firewall

    apply_doh_block_rules

    grep -q "\-A OUTPUT \-p tcp \-\-dport 443 \-m set \-\-match\-set openpath-doh-block dst \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-p udp \-\-dport 443 \-m set \-\-match\-set openpath-doh-block dst \-j DROP" "$IPTABLES_LOG"
    # No :53 rule is produced by the DoH builder (dnsmasq upstream unaffected)
    ! grep -q "\-\-dport 53" "$IPTABLES_LOG"
}

@test "apply_doh_block_rules covers every IPv4 entry of the shared contract fixture" {
    source_firewall

    apply_doh_block_rules

    local fixture_ip
    while IFS= read -r fixture_ip; do
        grep -q "add openpath-doh-block $fixture_ip -exist" "$IPSET_LOG"
    done < <(load_contract_fixture_lines "doh-resolvers.txt" | awk 'index($0, ":") == 0')
}

@test "apply_doh_block_rules honors a custom DOH_RESOLVERS list" {
    export DOH_RESOLVERS="4.4.4.4, 5.5.5.5"
    source_firewall

    apply_doh_block_rules

    grep -q "add openpath-doh-block 4.4.4.4 -exist" "$IPSET_LOG"
    grep -q "add openpath-doh-block 5.5.5.5 -exist" "$IPSET_LOG"
    ! grep -q "add openpath-doh-block 8.8.8.8 -exist" "$IPSET_LOG"
}

@test "apply_doh_block_rules keeps the upstream DNS IP in the block set (443-only scope)" {
    export PRIMARY_DNS="8.8.8.8"
    source_firewall

    apply_doh_block_rules

    # Upstream IP is blocked on :443 like any other resolver...
    grep -q "add openpath-doh-block 8.8.8.8 -exist" "$IPSET_LOG"
    # ...because the DROP rules are scoped to dport 443 only
    ! grep -Eq -- "-j DROP" <(grep -v -- "--dport 443" "$IPTABLES_LOG")
}

@test "apply_doh_block_rules skips invalid and IPv6 resolver entries" {
    export DOH_RESOLVERS="1.2.3.4,2001:4860:4860::8888,bogus"
    source_firewall

    run apply_doh_block_rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping invalid DoH resolver IP: 2001:4860:4860::8888"* ]]
    [[ "$output" == *"Skipping invalid DoH resolver IP: bogus"* ]]

    grep -q "add openpath-doh-block 1.2.3.4 -exist" "$IPSET_LOG"
    ! grep -q "2001" "$IPSET_LOG"
    ! grep -q "bogus" "$IPSET_LOG"
}

@test "apply_doh_block_rules is disabled via DOH_BLOCK_ENABLED=0" {
    export DOH_BLOCK_ENABLED="0"
    source_firewall

    run apply_doh_block_rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"DoH IP blocking disabled by configuration"* ]]

    [ ! -f "$IPSET_LOG" ]
    [ ! -f "$IPTABLES_LOG" ]
}

@test "apply_doh_block_rules falls back to per-IP rules when ipset is unavailable" {
    export DOH_RESOLVERS="4.4.4.4,5.5.5.5"

    command() {
        if [ "$2" = "ipset" ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    source_firewall

    run apply_doh_block_rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"ipset not available"* ]]

    grep -q "\-A OUTPUT \-d 4.4.4.4 \-p tcp \-\-dport 443 \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-d 4.4.4.4 \-p udp \-\-dport 443 \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-d 5.5.5.5 \-p tcp \-\-dport 443 \-j DROP" "$IPTABLES_LOG"
    [ ! -f "$IPSET_LOG" ]
}

# ============== VPN block rule builders ==============

@test "apply_vpn_interface_block_rules blocks tun+ and tap+ by default" {
    source_firewall

    apply_vpn_interface_block_rules

    grep -q "\-A OUTPUT \-o tun+ \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-o tap+ \-j DROP" "$IPTABLES_LOG"
}

@test "apply_vpn_interface_block_rules honors custom VPN_BLOCK_INTERFACES" {
    export VPN_BLOCK_INTERFACES="wg+, vpn0"
    source_firewall

    apply_vpn_interface_block_rules

    grep -q "\-A OUTPUT \-o wg+ \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-o vpn0 \-j DROP" "$IPTABLES_LOG"
    ! grep -q "tun+" "$IPTABLES_LOG"
}

@test "apply_vpn_interface_block_rules skips invalid interface patterns" {
    export VPN_BLOCK_INTERFACES='tun+,bad;rm,'
    source_firewall

    run apply_vpn_interface_block_rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping invalid VPN interface pattern"* ]]

    grep -q "\-A OUTPUT \-o tun+ \-j DROP" "$IPTABLES_LOG"
    ! grep -q "bad;rm" "$IPTABLES_LOG"
}

@test "apply_vpn_port_block_rules blocks the default VPN port catalog" {
    source_firewall

    apply_vpn_port_block_rules

    grep -q "\-A OUTPUT \-p udp \-\-dport 1194 \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-p tcp \-\-dport 1194 \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-p udp \-\-dport 51820 \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-p tcp \-\-dport 1723 \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-p udp \-\-dport 500 \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-p udp \-\-dport 4500 \-j DROP" "$IPTABLES_LOG"
}

@test "VPN_BLOCK_ENABLED=0 disables both interface and port VPN blocks" {
    export VPN_BLOCK_ENABLED="0"
    source_firewall

    apply_vpn_interface_block_rules
    run apply_vpn_port_block_rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"VPN blocking disabled by configuration"* ]]

    [ ! -f "$IPTABLES_LOG" ]
}

# ============== Tor block rule builder ==============

@test "apply_tor_block_rules blocks the default Tor port catalog" {
    source_firewall

    apply_tor_block_rules

    local tor_port
    for tor_port in 9001 9030 9050 9051 9150; do
        grep -q "\-A OUTPUT \-p tcp \-\-dport $tor_port \-j DROP" "$IPTABLES_LOG"
    done
}

@test "TOR_BLOCK_ENABLED=0 disables Tor port blocks" {
    export TOR_BLOCK_ENABLED="0"
    source_firewall

    run apply_tor_block_rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"Tor port blocking disabled by configuration"* ]]

    [ ! -f "$IPTABLES_LOG" ]
}

# ============== activate_firewall integration ==============

@test "activate_firewall confines dnsmasq upstream :53 to the dnsmasq uid (owner-match)" {
    export PRIMARY_DNS="8.8.8.8"
    source_firewall

    activate_firewall

    # Upstream :53 is reachable only from the dnsmasq process, not any user.
    grep -q -- "-A OUTPUT -p udp -d 8.8.8.8 --dport 53 -m owner --uid-owner 498 -j ACCEPT" "$IPTABLES_LOG"
    grep -q -- "-A OUTPUT -p tcp -d 8.8.8.8 --dport 53 -m owner --uid-owner 498 -j ACCEPT" "$IPTABLES_LOG"
    # No unconfined upstream allow (a student could otherwise dig @8.8.8.8).
    ! grep -q -- "-A OUTPUT -p udp -d 8.8.8.8 --dport 53 -j ACCEPT" "$IPTABLES_LOG"
    # The upstream IP still lands in the DoH block set (443-only)
    grep -q "add openpath-doh-block 8.8.8.8 -exist" "$IPSET_LOG"
}

@test "activate_firewall no longer allows DNS to the gateway and logs blocked DNS" {
    export PRIMARY_DNS="8.8.8.8"
    source_firewall

    activate_firewall

    # gateway is 192.168.1.1 (from the ip mock); its :53 allow must be gone.
    ! grep -q -- "-A OUTPUT -p udp -d 192.168.1.1 --dport 53 -j ACCEPT" "$IPTABLES_LOG"
    ! grep -q -- "-A OUTPUT -p tcp -d 192.168.1.1 --dport 53 -j ACCEPT" "$IPTABLES_LOG"
    # Blocked DNS attempts are logged (rate-limited) before the DROP.
    grep -q -- "-A OUTPUT -p udp --dport 53 -m limit --limit 5/min -j LOG --log-prefix OPENPATH-DNS-DROP " "$IPTABLES_LOG"
}

@test "apply_upstream_dns_owner_rule falls back to an unconfined allow when uid unresolved" {
    unset OPENPATH_DNSMASQ_UID
    id() { return 1; }
    export -f id
    source_firewall

    run apply_upstream_dns_owner_rule "8.8.8.8"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unconfined"* ]]
    # No owner rule emitted; caller is expected to add the plain allow.
    ! grep -q -- "--uid-owner" "$IPTABLES_LOG"
}

@test "activate_firewall places the DoH 443 DROP before the name-aware 443 ACCEPT" {
    source_firewall

    activate_firewall

    local drop_line accept_line
    drop_line=$(grep -n -- "--dport 443 -m set --match-set openpath-doh-block dst -j DROP" "$IPTABLES_LOG" | head -1 | cut -d: -f1)
    accept_line=$(grep -n -- "--dport 443 -m set --match-set openpath-allow-dst dst -j ACCEPT" "$IPTABLES_LOG" | head -1 | cut -d: -f1)

    [ -n "$drop_line" ]
    [ -n "$accept_line" ]
    [ "$drop_line" -lt "$accept_line" ]
}

@test "activate_firewall places VPN interface blocks before the ESTABLISHED accept" {
    source_firewall

    activate_firewall

    local tun_line established_line
    tun_line=$(grep -n -- "-o tun+ -j DROP" "$IPTABLES_LOG" | head -1 | cut -d: -f1)
    established_line=$(grep -n -- "--state ESTABLISHED,RELATED -j ACCEPT" "$IPTABLES_LOG" | head -1 | cut -d: -f1)

    [ -n "$tun_line" ]
    [ -n "$established_line" ]
    [ "$tun_line" -lt "$established_line" ]
}

@test "activate_firewall re-apply is idempotent (flush plus -exist ipset create)" {
    source_firewall

    activate_firewall
    activate_firewall

    [ "$(grep -c -- "-F OUTPUT" "$IPTABLES_LOG")" -eq 2 ]
    [ "$(grep -c "create openpath-doh-block hash:ip -exist" "$IPSET_LOG")" -eq 2 ]
    [ "$(grep -c "flush openpath-doh-block" "$IPSET_LOG")" -eq 2 ]
    # One tcp + one udp set-scoped rule per run, no accumulation within a run
    [ "$(grep -c -- "--match-set openpath-doh-block dst -j DROP" "$IPTABLES_LOG")" -eq 4 ]
}

@test "activate_firewall honors all three disable switches at once" {
    export DOH_BLOCK_ENABLED="0"
    export VPN_BLOCK_ENABLED="false"
    export TOR_BLOCK_ENABLED="no"
    # Name-aware egress is a separate mechanism; disable it too so this test
    # isolates the DoH/VPN/Tor switches (and keeps the no-ipset assertion below).
    export ALLOW_SET_EGRESS_ENABLED="0"
    source_firewall

    activate_firewall

    [ ! -f "$IPSET_LOG" ]
    ! grep -q -- "--match-set" "$IPTABLES_LOG"
    ! grep -q -- "-o tun+" "$IPTABLES_LOG"
    ! grep -q -- "--dport 1194" "$IPTABLES_LOG"
    ! grep -q -- "--dport 9050" "$IPTABLES_LOG"
    # Core DNS enforcement is unaffected by the bypass switches
    grep -q "\-A OUTPUT \-p udp \-\-dport 53 \-j DROP" "$IPTABLES_LOG"
    grep -q "\-A OUTPUT \-j DROP" "$IPTABLES_LOG"
}

# ============== name-aware egress allow set ==============

@test "ensure_allow_dst_ipset creates the allow set idempotently with a timeout" {
    source_firewall

    ensure_allow_dst_ipset
    ensure_allow_dst_ipset

    [ "$(grep -c "create openpath-allow-dst hash:ip timeout 600 -exist" "$IPSET_LOG")" -eq 2 ]
}

@test "ensure_allow_dst_ipset is a no-op when name-aware egress is disabled" {
    export ALLOW_SET_EGRESS_ENABLED="0"
    source_firewall

    ensure_allow_dst_ipset

    [ ! -f "$IPSET_LOG" ]
}

@test "apply_http_egress_rules scopes 80/443 to the allow set and omits the broad ACCEPT" {
    source_firewall

    apply_http_egress_rules

    grep -q -- "-A OUTPUT -p tcp --dport 80 -m set --match-set openpath-allow-dst dst -j ACCEPT" "$IPTABLES_LOG"
    grep -q -- "-A OUTPUT -p tcp --dport 443 -m set --match-set openpath-allow-dst dst -j ACCEPT" "$IPTABLES_LOG"
    ! grep -q -- "-A OUTPUT -p tcp --dport 443 -j ACCEPT" "$IPTABLES_LOG"
    ! grep -q -- "-A OUTPUT -p tcp --dport 80 -j ACCEPT" "$IPTABLES_LOG"
}

@test "activate_firewall scopes HTTP/HTTPS to the openpath-allow-dst set by default" {
    source_firewall

    activate_firewall

    grep -q "create openpath-allow-dst hash:ip timeout 600 -exist" "$IPSET_LOG"
    grep -q -- "-A OUTPUT -p tcp --dport 443 -m set --match-set openpath-allow-dst dst -j ACCEPT" "$IPTABLES_LOG"
    grep -q -- "-A OUTPUT -p tcp --dport 80 -m set --match-set openpath-allow-dst dst -j ACCEPT" "$IPTABLES_LOG"
    # The legacy broad HTTPS ACCEPT must be gone (that was the name-blind hole).
    ! grep -q -- "-A OUTPUT -p tcp --dport 443 -j ACCEPT" "$IPTABLES_LOG"
}

@test "activate_firewall falls back to broad 80/443 ACCEPT when name-aware egress disabled" {
    export ALLOW_SET_EGRESS_ENABLED="0"
    source_firewall

    activate_firewall

    grep -q -- "-A OUTPUT -p tcp --dport 443 -j ACCEPT" "$IPTABLES_LOG"
    grep -q -- "-A OUTPUT -p tcp --dport 80 -j ACCEPT" "$IPTABLES_LOG"
    ! grep -q -- "--match-set openpath-allow-dst" "$IPTABLES_LOG"
    ! grep -q "create openpath-allow-dst" "$IPSET_LOG"
}

@test "firewall_snapshot_has_allow_set_rule detects the name-aware ACCEPT and rejects the broad one" {
    source_firewall

    local with_set="-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -p tcp -m tcp --dport 443 -m set --match-set openpath-allow-dst dst -j ACCEPT
-A OUTPUT -j DROP"
    firewall_snapshot_has_allow_set_rule "$with_set"

    local broad_only="-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -p tcp -m tcp --dport 443 -j ACCEPT
-A OUTPUT -j DROP"
    ! firewall_snapshot_has_allow_set_rule "$broad_only"
}

# ============== NTP scoping ==============

@test "apply_ntp_egress_rules scopes udp/123 to the allow set when name-aware egress is active" {
    source_firewall

    apply_ntp_egress_rules

    grep -q -- "-A OUTPUT -p udp --dport 123 -m set --match-set openpath-allow-dst dst -j ACCEPT" "$IPTABLES_LOG"
    ! grep -q -- "-A OUTPUT -p udp --dport 123 -j ACCEPT" "$IPTABLES_LOG"
}

@test "apply_ntp_egress_rules falls back to broad NTP when name-aware egress disabled" {
    export ALLOW_SET_EGRESS_ENABLED="0"
    source_firewall

    apply_ntp_egress_rules

    grep -q -- "-A OUTPUT -p udp --dport 123 -j ACCEPT" "$IPTABLES_LOG"
    ! grep -q -- "--match-set openpath-allow-dst" "$IPTABLES_LOG"
}

# ============== bridged-VM enforcement ==============

@test "apply_bridge_enforcement loads br_netfilter and persists the bridge sysctls" {
    source_firewall

    apply_bridge_enforcement

    grep -q "br_netfilter" "$MODPROBE_LOG"
    grep -q "net.bridge.bridge-nf-call-iptables=1" "$SYSCTL_LOG"
    grep -q "net.bridge.bridge-nf-call-ip6tables=1" "$SYSCTL_LOG"
    grep -q "net.bridge.bridge-nf-call-iptables=1" "$OPENPATH_SYSCTL_D_DIR/99-openpath-bridge.conf"
}

@test "apply_forward_default_deny sets FORWARD policy DROP with an established allow" {
    source_firewall

    apply_forward_default_deny

    grep -q -- "-A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT" "$IPTABLES_LOG"
    grep -q -- "-P FORWARD DROP" "$IPTABLES_LOG"
}

@test "bridge enforcement is disabled via BRIDGE_ENFORCEMENT_ENABLED=0" {
    export BRIDGE_ENFORCEMENT_ENABLED="0"
    source_firewall

    apply_bridge_enforcement
    apply_forward_default_deny

    [ ! -f "$MODPROBE_LOG" ]
    [ ! -f "$IPTABLES_LOG" ]
}

@test "activate_firewall applies bridge enforcement and FORWARD default-deny by default" {
    source_firewall

    activate_firewall

    grep -q "br_netfilter" "$MODPROBE_LOG"
    grep -q -- "-P FORWARD DROP" "$IPTABLES_LOG"
}

# ============== IPv6 egress firewall ==============

@test "ensure_allow_dst_ipset creates the inet6 allow set when IPv6 firewall is active" {
    source_firewall

    ensure_allow_dst_ipset

    grep -q "create openpath-allow-dst hash:ip timeout 600 -exist" "$IPSET_LOG"
    grep -q "create openpath-allow-dst6 hash:ip family inet6 timeout 600 -exist" "$IPSET_LOG"
}

@test "apply_ipv6_firewall mirrors the v4 policy with ICMPv6 allowed and v6 DNS dropped" {
    source_firewall

    apply_ipv6_firewall

    grep -q -- "-A OUTPUT -o lo -j ACCEPT" "$IP6TABLES_LOG"
    grep -q -- "-A OUTPUT -p ipv6-icmp -j ACCEPT" "$IP6TABLES_LOG"
    grep -q -- "-A OUTPUT -p udp --dport 53 -j DROP" "$IP6TABLES_LOG"
    grep -q -- "-A OUTPUT -p tcp --dport 53 -j DROP" "$IP6TABLES_LOG"
    grep -q -- "-A OUTPUT -j DROP" "$IP6TABLES_LOG"
    # v4 OUTPUT chain is untouched by the v6 builder.
    [ ! -f "$IPTABLES_LOG" ]
}

@test "apply_ipv6_firewall scopes 80/443 to the inet6 allow set and applies FORWARD deny" {
    source_firewall

    apply_ipv6_firewall

    grep -q -- "-A OUTPUT -p tcp --dport 443 -m set --match-set openpath-allow-dst6 dst -j ACCEPT" "$IP6TABLES_LOG"
    grep -q -- "-A OUTPUT -p tcp --dport 80 -m set --match-set openpath-allow-dst6 dst -j ACCEPT" "$IP6TABLES_LOG"
    grep -q -- "-P FORWARD DROP" "$IP6TABLES_LOG"
}

@test "apply_ipv6_firewall is a no-op when IPV6_FIREWALL_ENABLED=0" {
    export IPV6_FIREWALL_ENABLED="0"
    source_firewall

    apply_ipv6_firewall

    [ ! -f "$IP6TABLES_LOG" ]
}

@test "activate_firewall applies the IPv6 firewall by default" {
    source_firewall

    activate_firewall

    grep -q -- "-A OUTPUT -j DROP" "$IP6TABLES_LOG"
    grep -q -- "-A OUTPUT -p udp --dport 53 -j DROP" "$IP6TABLES_LOG"
}

# ============== RFC1918 knob + egress logging ==============

@test "apply_rfc1918_egress_rules honors a custom RFC1918_ALLOW list" {
    export RFC1918_ALLOW="192.168.10.0/24, 10.1.2.0/24"
    source_firewall

    apply_rfc1918_egress_rules

    grep -q -- "-A OUTPUT -d 192.168.10.0/24 -j ACCEPT" "$IPTABLES_LOG"
    grep -q -- "-A OUTPUT -d 10.1.2.0/24 -j ACCEPT" "$IPTABLES_LOG"
    # The broad default ranges are not emitted when a narrower list is set.
    ! grep -q -- "-A OUTPUT -d 10.0.0.0/8 -j ACCEPT" "$IPTABLES_LOG"
}

@test "activate_firewall logs dropped egress before the default deny (v4 and v6)" {
    source_firewall

    activate_firewall

    grep -q -- "-A OUTPUT -m limit --limit 5/min -j LOG --log-prefix OPENPATH-EGRESS-DROP " "$IPTABLES_LOG"
    grep -q -- "-A OUTPUT -m limit --limit 5/min -j LOG --log-prefix OPENPATH-EGRESS6-DROP " "$IP6TABLES_LOG"
}

# ============== deactivate_firewall cleanup ==============

@test "deactivate_firewall destroys the DoH ipset after flushing rules" {
    source_firewall

    touch "$OPENPATH_IPSET_STATE_FILE"

    deactivate_firewall

    grep -q "\-F OUTPUT" "$IPTABLES_LOG"
    grep -q "destroy openpath-doh-block" "$IPSET_LOG"
    [ ! -f "$OPENPATH_IPSET_STATE_FILE" ]
}

@test "deactivate_firewall succeeds when ipset is unavailable" {
    command() {
        if [ "$2" = "ipset" ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    source_firewall

    run deactivate_firewall
    [ "$status" -eq 0 ]
    [ ! -f "$IPSET_LOG" ]
}

# ============== snapshot / restore ==============

@test "save_doh_block_ipset_state persists the set next to rules.v4" {
    ipset() {
        echo "$*" >> "$IPSET_LOG"
        if [ "$1" = "save" ]; then
            echo "create openpath-doh-block hash:ip"
            echo "add openpath-doh-block 8.8.8.8"
        fi
        return 0
    }
    export -f ipset

    source_firewall

    save_doh_block_ipset_state

    [ -f "$OPENPATH_IPSET_STATE_FILE" ]
    grep -q "add openpath-doh-block 8.8.8.8" "$OPENPATH_IPSET_STATE_FILE"
}

@test "save_doh_block_ipset_state removes stale state when the set is gone" {
    ipset() {
        echo "$*" >> "$IPSET_LOG"
        if [ "$1" = "list" ]; then
            return 1
        fi
        return 0
    }
    export -f ipset

    source_firewall

    echo "stale" > "$OPENPATH_IPSET_STATE_FILE"
    save_doh_block_ipset_state

    [ ! -f "$OPENPATH_IPSET_STATE_FILE" ]
}

# ============== snapshot predicates ==============

@test "firewall_snapshot_has_doh_block_rule detects the ipset rule in canonical output" {
    source_firewall

    local snapshot="-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -p tcp -m tcp --dport 443 -m set --match-set openpath-doh-block dst -j DROP"

    firewall_snapshot_has_doh_block_rule "$snapshot"
}

@test "firewall_snapshot_has_doh_block_rule detects per-IP fallback rules" {
    source_firewall

    local snapshot="-P OUTPUT ACCEPT
-A OUTPUT -d 1.1.1.1/32 -p tcp -m tcp --dport 443 -j DROP"

    firewall_snapshot_has_doh_block_rule "$snapshot"
}

@test "firewall_snapshot_has_doh_block_rule rejects rulesets without a 443 block" {
    source_firewall

    local snapshot="-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -p tcp -m tcp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 443 -j ACCEPT
-A OUTPUT -j DROP"

    ! firewall_snapshot_has_doh_block_rule "$snapshot"
}

@test "firewall_snapshot_has_vpn_interface_block_rule detects tun+ output drops" {
    source_firewall

    local snapshot="-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j DROP"

    firewall_snapshot_has_vpn_interface_block_rule "$snapshot"

    local snapshot_without="-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -j DROP"

    ! firewall_snapshot_has_vpn_interface_block_rule "$snapshot_without"
}

@test "firewall_snapshot_has_port_drop_rule matches canonical and list outputs" {
    source_firewall

    local canonical="-P OUTPUT ACCEPT
-A OUTPUT -p tcp -m tcp --dport 9050 -j DROP"
    firewall_snapshot_has_port_drop_rule "$canonical" "tcp" "9050"
    ! firewall_snapshot_has_port_drop_rule "$canonical" "udp" "9050"
    ! firewall_snapshot_has_port_drop_rule "$canonical" "tcp" "905"

    local listed="Chain OUTPUT (policy ACCEPT)
target     prot opt source    destination
DROP       tcp  --  0.0.0.0/0  0.0.0.0/0   tcp dpt:9050"
    firewall_snapshot_has_port_drop_rule "$listed" "tcp" "9050"
}

# ============== status checks ==============

write_full_canonical_snapshot() {
    cat > "$TEST_TMP_DIR/snapshot.txt" << 'EOF'
-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o tun+ -j DROP
-A OUTPUT -o tap+ -j DROP
-A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p udp -m udp --dport 53 -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p tcp -m tcp --dport 53 -j ACCEPT
-A OUTPUT -d 8.8.8.8/32 -p udp -m udp --dport 53 -j ACCEPT
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
-A OUTPUT -p tcp -m tcp --dport 80 -j ACCEPT
-A OUTPUT -p tcp -m tcp --dport 443 -j ACCEPT
-A OUTPUT -j DROP
EOF
}

mock_snapshot_iptables() {
    iptables() {
        if [ "$1" = "-S" ] && [ "$2" = "OUTPUT" ]; then
            cat "$TEST_TMP_DIR/snapshot.txt"
            return 0
        fi
        echo "Chain OUTPUT (policy ACCEPT)"
        return 0
    }
    export -f iptables
}

@test "check bypass-block statuses report active for a fully enforced ruleset" {
    write_full_canonical_snapshot
    mock_snapshot_iptables
    source_firewall

    run check_doh_block_status
    [ "$status" -eq 0 ]
    [ "$output" = "active" ]

    run check_vpn_block_status
    [ "$status" -eq 0 ]
    [ "$output" = "active" ]

    run check_tor_block_status
    [ "$status" -eq 0 ]
    [ "$output" = "active" ]
}

@test "check bypass-block statuses report inactive for a bare ruleset" {
    cat > "$TEST_TMP_DIR/snapshot.txt" << 'EOF'
-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 53 -j DROP
-A OUTPUT -j DROP
EOF
    mock_snapshot_iptables
    source_firewall

    run check_doh_block_status
    [ "$status" -eq 1 ]
    [ "$output" = "inactive" ]

    run check_vpn_block_status
    [ "$status" -eq 1 ]
    [ "$output" = "inactive" ]

    run check_tor_block_status
    [ "$status" -eq 1 ]
    [ "$output" = "inactive" ]
}

@test "check bypass-block statuses report disabled when switched off" {
    export DOH_BLOCK_ENABLED="0"
    export VPN_BLOCK_ENABLED="0"
    export TOR_BLOCK_ENABLED="0"
    source_firewall

    run check_doh_block_status
    [ "$status" -eq 0 ]
    [ "$output" = "disabled" ]

    run check_vpn_block_status
    [ "$status" -eq 0 ]
    [ "$output" = "disabled" ]

    run check_tor_block_status
    [ "$status" -eq 0 ]
    [ "$output" = "disabled" ]
}

@test "check_vpn_block_status is inactive when only the interface rule is missing" {
    write_full_canonical_snapshot
    grep -v -- "-o tun+\|-o tap+" "$TEST_TMP_DIR/snapshot.txt" > "$TEST_TMP_DIR/snapshot.tmp"
    mv "$TEST_TMP_DIR/snapshot.tmp" "$TEST_TMP_DIR/snapshot.txt"
    mock_snapshot_iptables
    source_firewall

    run check_vpn_block_status
    [ "$status" -eq 1 ]
    [ "$output" = "inactive" ]
}

# ============== verify_firewall_rules interplay ==============

@test "verify_firewall_rules warns about missing bypass blocks but stays green" {
    cat > "$TEST_TMP_DIR/snapshot.txt" << 'EOF'
-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p udp -m udp --dport 53 -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p tcp -m tcp --dport 53 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 53 -j DROP
-A OUTPUT -j DROP
EOF
    mock_snapshot_iptables
    source "$PROJECT_DIR/linux/lib/firewall.sh"

    run verify_firewall_rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"Bypass-block rule missing: DoH resolver block"* ]]
    [[ "$output" == *"Bypass-block rule missing: VPN interface block"* ]]
}

@test "verify_firewall_rules does not warn when bypass blocks are disabled" {
    export DOH_BLOCK_ENABLED="0"
    export VPN_BLOCK_ENABLED="0"
    export TOR_BLOCK_ENABLED="0"
    cat > "$TEST_TMP_DIR/snapshot.txt" << 'EOF'
-P OUTPUT ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p udp -m udp --dport 53 -j ACCEPT
-A OUTPUT -d 127.0.0.1/32 -p tcp -m tcp --dport 53 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j DROP
-A OUTPUT -p tcp -m tcp --dport 53 -j DROP
-A OUTPUT -j DROP
EOF
    mock_snapshot_iptables
    source "$PROJECT_DIR/linux/lib/firewall.sh"

    run verify_firewall_rules
    [ "$status" -eq 0 ]
    [[ "$output" != *"Bypass-block rule missing"* ]]
}
