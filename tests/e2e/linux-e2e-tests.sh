#!/bin/bash
################################################################################
# linux-e2e-tests.sh - End-to-End tests for Linux whitelist system
# 
# Validates the complete installation and operation of the dnsmasq-based
# OpenPath system including DNS resolution, blocking, and firewall.
#
# Usage: sudo ./linux-e2e-tests.sh
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0

# ============== Helper Functions ==============

test_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    PASSED=$((PASSED + 1))
}

test_fail() {
    echo -e "  ${RED}✗${NC} $1"
    FAILED=$((FAILED + 1))
}

test_section() {
    echo ""
    echo -e "${BLUE}[$1]${NC} $2"
}

# ============== E2E Tests ==============

test_dnsmasq_active() {
    test_section "1/7" "dnsmasq service status"
    
    if systemctl is-active --quiet dnsmasq; then
        test_pass "dnsmasq is active"
    else
        test_fail "dnsmasq is not active"
    fi
}

test_port_53_listening() {
    test_section "2/7" "Port 53 listening"
    
    if ss -ulnp 2>/dev/null | grep -q ":53 "; then
        test_pass "Port 53 UDP is listening"
    else
        # In Docker/CI, DNS may work via --dns flag without local port 53
        echo -e "  ${YELLOW}⚠${NC} Port 53 UDP not listening (expected in Docker/CI)"
    fi
    
    if ss -tlnp 2>/dev/null | grep -q ":53 "; then
        test_pass "Port 53 TCP is listening"
    else
        # TCP is optional for dnsmasq
        echo -e "  ${YELLOW}⚠${NC} Port 53 TCP not listening (optional)"
    fi
}

test_whitelisted_domains_resolve() {
    test_section "3/7" "Whitelisted domains resolve"
    
    local domains=("google.com" "github.com")
    
    for domain in "${domains[@]}"; do
        local result
        result=$(timeout 5 dig @127.0.0.1 "$domain" +short 2>/dev/null | head -1)
        
        if [ -n "$result" ]; then
            test_pass "$domain → $result"
        else
            test_fail "$domain does not resolve"
        fi
    done
}

test_blocked_domains_nxdomain() {
    test_section "4/7" "Non-whitelisted domains blocked"
    
    local blocked_domains=(
        "malware-test-domain.com"
        "should-be-blocked-12345.net"
        "random-blocked-site.org"
    )
    
    for domain in "${blocked_domains[@]}"; do
        local result
        result=$(timeout 3 dig @127.0.0.1 "$domain" +short 2>/dev/null | head -1)
        
        if [ -z "$result" ] || [ "$result" == "0.0.0.0" ] || [ "$result" == "192.0.2.1" ] || [ "$result" == "127.0.0.1" ]; then
            test_pass "$domain blocked (NXDOMAIN/sinkhole)"
        else
            test_fail "$domain resolved to $result (should be blocked)"
        fi
    done
}

test_config_files_exist() {
    test_section "5/7" "Configuration files"

    if [ -f "/etc/dnsmasq.d/openpath.conf" ]; then
        test_pass "/etc/dnsmasq.d/openpath.conf exists"
    else
        test_fail "/etc/dnsmasq.d/openpath.conf missing"
    fi

    if [ -f "/etc/openpath/whitelist-url.conf" ]; then
        test_pass "/etc/openpath/whitelist-url.conf exists"
    else
        local request_setup_markers=0
        for file in /etc/openpath/api-url.conf /etc/openpath/classroom.conf /etc/openpath/classroom-id.conf; do
            if [ -f "$file" ]; then
                request_setup_markers=$((request_setup_markers + 1))
            fi
        done

        if [ "$request_setup_markers" -gt 0 ]; then
            test_fail "whitelist-url.conf missing while request setup markers exist"
        else
            test_pass "Request setup not configured (installer mode)"
        fi
    fi
    
    # Check whitelist was downloaded
    if [ -f "/var/lib/openpath/whitelist.txt" ]; then
        local count
        count=$(grep -cv "^#\|^$" /var/lib/openpath/whitelist.txt 2>/dev/null || echo "0")
        test_pass "Whitelist downloaded ($count entries)"
    else
        echo -e "  ${YELLOW}⚠${NC} Whitelist not yet downloaded (timer will fetch)"
    fi
}

test_systemd_timers() {
    test_section "6/7" "Systemd timers"
    
    if systemctl is-active --quiet openpath-dnsmasq.timer 2>/dev/null; then
        test_pass "openpath-dnsmasq.timer is active"
    else
        echo -e "  ${YELLOW}⚠${NC} openpath-dnsmasq.timer not active"
    fi
    
    if systemctl is-active --quiet dnsmasq-watchdog.timer 2>/dev/null; then
        test_pass "dnsmasq-watchdog.timer is active"
    else
        echo -e "  ${YELLOW}⚠${NC} dnsmasq-watchdog.timer not active"
    fi
}

test_iptables_rules() {
    test_section "7/9" "Firewall rules"
    
    if ! command -v iptables &>/dev/null; then
        echo -e "  ${YELLOW}⚠${NC} iptables not available"
        return 0
    fi
    
    # Check for DNS blocking rules
    local output_rules
    output_rules=$(iptables -L OUTPUT -n 2>/dev/null | wc -l)
    
    if [ "$output_rules" -gt 3 ]; then
        test_pass "OUTPUT chain has rules ($((output_rules - 2)) rules)"
    else
        echo -e "  ${YELLOW}⚠${NC} OUTPUT chain appears empty"
    fi
    
    # Check for port 53 rules specifically
    if iptables -L OUTPUT -n 2>/dev/null | grep -q "dpt:53"; then
        test_pass "DNS port blocking rules exist"
    else
        echo -e "  ${YELLOW}⚠${NC} No explicit DNS port blocking rules"
    fi
}

test_firefox_esr_installed() {
    test_section "8/9" "Firefox ESR installation"
    
    # Check if Firefox ESR or Firefox (non-snap) is installed
    if command -v firefox-esr &>/dev/null; then
        test_pass "firefox-esr command available"
    elif command -v firefox &>/dev/null; then
        test_pass "firefox command available"
    else
        echo -e "  ${YELLOW}⚠${NC} Firefox not installed"
        return 0
    fi
    
    # Check Snap Firefox is NOT installed
    if snap list firefox &>/dev/null 2>&1; then
        test_fail "Firefox Snap still installed (should be removed)"
    else
        test_pass "Firefox Snap not present"
    fi
    
    # Check Firefox directories
    local firefox_found=false
    for dir in /usr/lib/firefox-esr /usr/lib/firefox /opt/firefox; do
        if [ -d "$dir" ]; then
            test_pass "Firefox directory exists: $dir"
            firefox_found=true
            break
        fi
    done
    
    if [ "$firefox_found" = false ]; then
        echo -e "  ${YELLOW}⚠${NC} Firefox directory not found"
    fi
}

test_firefox_extension_installed() {
    test_section "9/9" "Firefox extension installation"
    
    local ext_id="openpath-block-monitor@openpath"
    local firefox_app_id="{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
    local ext_dir="/usr/share/mozilla/extensions/$firefox_app_id/$ext_id"
    local expect_firefox_extension="${OPENPATH_EXPECT_FIREFOX_EXTENSION:-0}"
    local release_metadata="/usr/share/openpath/firefox-release/metadata.json"
    local release_xpi="/usr/share/openpath/firefox-release/openpath-firefox-extension.xpi"
    
    # Check extension directory exists
    if [ -d "$ext_dir" ]; then
        test_pass "Extension directory exists"
    elif [ -f "$release_metadata" ] || [ -f "$release_xpi" ]; then
        test_pass "Firefox release artifacts available for managed install"
    else
        if [ "$expect_firefox_extension" = "1" ]; then
            test_fail "Extension directory not found"
        else
            echo -e "  ${YELLOW}⚠${NC} Extension directory not found (may be installed with --no-extension)"
        fi
        return 0
    fi
    
    # Check manifest.json exists
    if [ ! -d "$ext_dir" ]; then
        :
    elif [ -f "$ext_dir/manifest.json" ]; then
        test_pass "Extension manifest.json exists"
    else
        test_fail "Extension manifest.json missing"
    fi
    
    # Check built scripts required by manifest and popup
    if [ ! -d "$ext_dir" ]; then
        :
    elif [ -f "$ext_dir/dist/background.js" ]; then
        test_pass "Extension dist/background.js exists"
    else
        test_fail "Extension dist/background.js missing"
    fi

    if [ ! -d "$ext_dir" ]; then
        :
    elif [ -f "$ext_dir/dist/popup.js" ]; then
        test_pass "Extension dist/popup.js exists"
    else
        test_fail "Extension dist/popup.js missing"
    fi

    if [ ! -d "$ext_dir" ]; then
        :
    elif [ -f "$ext_dir/dist/lib/logger.js" ]; then
        test_pass "Extension dist/lib/logger.js exists"
    else
        test_fail "Extension dist/lib/logger.js missing"
    fi

    if [ ! -d "$ext_dir" ]; then
        :
    elif [ -f "$ext_dir/blocked/blocked.html" ] && [ -f "$ext_dir/blocked/blocked.css" ] && [ -f "$ext_dir/blocked/blocked.js" ]; then
        test_pass "Extension blocked screen assets exist"
    else
        test_fail "Extension blocked screen assets missing"
    fi
    
    # Check autoconfig files
    local autoconfig_found=false
    for firefox_dir in /usr/lib/firefox-esr /usr/lib/firefox /opt/firefox; do
        if [ -f "$firefox_dir/mozilla.cfg" ] && [ -f "$firefox_dir/defaults/pref/autoconfig.js" ]; then
            test_pass "Firefox autoconfig configured in $firefox_dir"
            autoconfig_found=true
            
            # Check signature verification is disabled
            if grep -q "xpinstall.signatures.required.*false" "$firefox_dir/mozilla.cfg" 2>/dev/null; then
                test_pass "Signature verification disabled"
            else
                test_fail "Signature verification not disabled"
            fi
            break
        fi
    done
    
    if [ "$autoconfig_found" = false ]; then
        echo -e "  ${YELLOW}⚠${NC} Firefox autoconfig not found"
    fi
    
    # Check extension in policies.json
    if [ -f "/etc/firefox/policies/policies.json" ]; then
        if grep -q "ExtensionSettings" "/etc/firefox/policies/policies.json" 2>/dev/null; then
            test_pass "ExtensionSettings in policies.json"
        else
            echo -e "  ${YELLOW}⚠${NC} ExtensionSettings not in policies.json"
        fi
        
        if grep -q "$ext_id" "/etc/firefox/policies/policies.json" 2>/dev/null; then
            test_pass "Extension ID in policies.json"
        else
            echo -e "  ${YELLOW}⚠${NC} Extension ID not in policies.json"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} policies.json not found"
    fi
    
    # Check native messaging host (optional)
    if [ -f "/usr/lib/mozilla/native-messaging-hosts/whitelist_native_host.json" ]; then
        test_pass "Native messaging host installed"
    else
        echo -e "  ${YELLOW}ℹ${NC} Native messaging host not installed (optional)"
    fi
}

# ============== Failure Scenario Tests ==============

test_corrupted_whitelist_recovery() {
    test_section "10/12" "Corrupted whitelist recovery"
    
    local whitelist_file="/var/lib/openpath/whitelist.txt"
    local backup_file="/tmp/whitelist-backup.txt"
    
    # Backup original
    if [ -f "$whitelist_file" ]; then
        cp "$whitelist_file" "$backup_file"
    fi
    
    # Corrupt the whitelist
    echo "CORRUPTED_CONTENT_$RANDOM" > "$whitelist_file"
    
    # Run whitelist update and check it handles corruption gracefully
    if /usr/local/bin/openpath-update.sh 2>/dev/null; then
        # Check dnsmasq is still running
        if systemctl is-active --quiet dnsmasq; then
            test_pass "System survived corrupted whitelist"
        else
            test_fail "dnsmasq crashed after corrupted whitelist"
        fi
    else
        # Script may fail, but system should remain stable
        if systemctl is-active --quiet dnsmasq; then
            test_pass "System stable after whitelist update failure"
        else
            test_fail "dnsmasq not running after failure"
        fi
    fi
    
    # Restore original
    if [ -f "$backup_file" ]; then
        cp "$backup_file" "$whitelist_file"
        rm -f "$backup_file"
    fi
}

test_emergency_disable() {
    test_section "11/12" "Emergency disable detection"
    
    local whitelist_file="/var/lib/openpath/whitelist.txt"
    local backup_file="/tmp/whitelist-backup.txt"
    
    # Backup original
    if [ -f "$whitelist_file" ]; then
        cp "$whitelist_file" "$backup_file"
    fi
    
    # Create emergency disable whitelist
    cat > "$whitelist_file" << 'EOF'
# DESACTIVADO
# Emergency disable triggered
google.com
EOF
    
    # Run whitelist update
    /usr/local/bin/openpath-update.sh 2>/dev/null || true
    
    # Check system entered fail-open mode
    if [ -f "/var/lib/openpath/system-disabled.flag" ]; then
        test_pass "Emergency disable detected and activated"
    else
        echo -e "  ${YELLOW}⚠${NC} Emergency disable flag not set (may be expected)"
    fi
    
    # Restore original and reactivate
    if [ -f "$backup_file" ]; then
        cp "$backup_file" "$whitelist_file"
        rm -f "$backup_file"
        rm -f "/var/lib/openpath/system-disabled.flag" 2>/dev/null || true
        /usr/local/bin/openpath-update.sh 2>/dev/null || true
    fi
}

test_watchdog_recovery() {
    test_section "12/12" "Watchdog recovery mechanism"
    
    # Check watchdog health file exists
    local health_file="/var/lib/openpath/health-status"
    
    if [ -f "$health_file" ]; then
        test_pass "Health status file exists"
        
        # Parse status
        local status
        status=$(grep -o '"status": "[^"]*"' "$health_file" | cut -d'"' -f4)
        if [ "$status" = "OK" ] || [ "$status" = "RECOVERED" ]; then
            test_pass "Watchdog reports healthy status: $status"
        else
            echo -e "  ${YELLOW}⚠${NC} Watchdog status: $status"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} Health status file not found (watchdog may not have run yet)"
    fi
    
    # Check checkpoint directory exists
    local checkpoint_dir="/var/lib/openpath/checkpoints"
    if [ -d "$checkpoint_dir" ]; then
        local checkpoint_count
        checkpoint_count=$(find "$checkpoint_dir" -maxdepth 1 -name "checkpoint-*" -type d 2>/dev/null | wc -l)
        if [ "$checkpoint_count" -gt 0 ]; then
            test_pass "Rollback checkpoints available: $checkpoint_count"
        else
            echo -e "  ${YELLOW}ℹ${NC} No checkpoints yet (first run)"
        fi
    else
        echo -e "  ${YELLOW}ℹ${NC} Checkpoint directory not created yet"
    fi
}

# ============== Main ==============

main() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  E2E Tests - OpenPath System${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    
    test_dnsmasq_active
    test_port_53_listening
    test_whitelisted_domains_resolve
    test_blocked_domains_nxdomain
    test_config_files_exist
    test_systemd_timers
    test_iptables_rules
    test_firefox_esr_installed
    test_firefox_extension_installed
    
    # Failure scenario tests
    test_corrupted_whitelist_recovery
    test_emergency_disable
    test_watchdog_recovery
    
    # Summary
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "  Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""
    
    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}✗ E2E TESTS FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}✓ E2E TESTS PASSED${NC}"
        exit 0
    fi
}

# Require root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run with sudo"
    exit 1
fi

main "$@"
