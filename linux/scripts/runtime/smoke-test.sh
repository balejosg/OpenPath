#!/bin/bash

# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

################################################################################
# smoke-test.sh - Post-installation validation tests
# Part of the OpenPath DNS system
#
# Verifies the system works correctly after installation.
# Returns 0 if OK, 1 if critical failures.
#
# Usage:
#   sudo ./smoke-test.sh           # Full test
#   sudo ./smoke-test.sh --quick   # Critical tests only
################################################################################

# Load common.sh for VERSION and shared functions
INSTALL_DIR="/usr/local/lib/openpath"
if [ -f "$INSTALL_DIR/lib/common.sh" ]; then
    source "$INSTALL_DIR/lib/common.sh" 2>/dev/null || true
fi
VERSION="${VERSION:-unknown}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Quick mode
QUICK_MODE=false
[[ "$1" == "--quick" ]] && QUICK_MODE=true

# ============== Test Functions ==============

test_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    ((PASSED++))
}

test_fail() {
    echo -e "  ${RED}✗${NC} $1"
    ((FAILED++))
}

test_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
    ((WARNINGS++))
}

test_section() {
    echo ""
    echo -e "${BLUE}[$1]${NC} $2"
}

# ============== Critical Tests ==============

test_dnsmasq_running() {
    test_section "1/6" "dnsmasq service"
    
    if systemctl is-active --quiet dnsmasq; then
        test_pass "dnsmasq is active"
    else
        test_fail "dnsmasq is not active"
        return 1
    fi
}

test_port_53() {
    test_section "2/6" "Port 53"
    
    if ss -ulnp 2>/dev/null | grep -q ":53 "; then
        local proc
        proc=$(ss -ulnp 2>/dev/null | grep ":53 " | grep -oP 'users:\(\("\K[^"]+')
        test_pass "Port 53 UDP listening ($proc)"
    else
        # In Docker/CI environments, DNS may work via --dns flag without local port 53
        # This is a warning, not a failure - actual DNS tests verify functionality
        test_warn "UDP port 53 is not listening (can be normal in Docker/CI)"
    fi
}

test_dns_resolves_whitelisted() {
    test_section "3/6" "DNS resolves allowlisted domains"
    
    # These domains should always be allowlisted.
    local test_domains=("google.com" "github.com")
    local all_ok=true
    
    for domain in "${test_domains[@]}"; do
        local result
        result=$(timeout 3 dig @127.0.0.1 "$domain" +short 2>/dev/null | head -1)
        if [ -n "$result" ]; then
            test_pass "$domain → $result"
        else
            test_fail "$domain does not resolve"
            all_ok=false
        fi
    done
    
    $all_ok
}

test_dns_blocks_unknown() {
    test_section "4/6" "DNS blocks non-allowlisted domains"
    
    # Domains that should not exist or resolve.
    local blocked_domains=("thisdomaindoesnotexist12345.com" "malware-test-blocked.net")
    local all_ok=true
    
    for domain in "${blocked_domains[@]}"; do
        local result
        result=$(timeout 3 dig @127.0.0.1 "$domain" +short 2>/dev/null | head -1)
        if [ -z "$result" ] || [ "$result" == "127.0.0.1" ] || [ "$result" == "0.0.0.0" ] || [ "$result" == "192.0.2.1" ]; then
            test_pass "$domain blocked correctly"
        else
            test_warn "$domain resolves to $result (should be blocked)"
            all_ok=false
        fi
    done
    
    $all_ok
}

test_firewall_rules() {
    test_section "5/6" "Firewall rules"
    
    if ! command -v iptables &>/dev/null; then
        test_warn "iptables is not available"
        return 0
    fi
    
    # Verify OUTPUT rules exist.
    local rules_count
    rules_count=$(iptables -L OUTPUT -n 2>/dev/null | wc -l)
    if [ "$rules_count" -gt 3 ]; then
        test_pass "Firewall configured ($((rules_count - 2)) OUTPUT rules)"
    else
        test_warn "Firewall may not be configured (few rules)"
    fi
    
    # Verify external DNS port blocking.
    if iptables -L OUTPUT -n 2>/dev/null | grep -q "dpt:53"; then
        test_pass "External DNS blocking configured"
    else
        test_warn "External DNS blocking was not detected"
    fi
}

test_config_files() {
    test_section "6/6" "Configuration files"
    
    local all_ok=true
    
    if [ -f /etc/dnsmasq.d/openpath.conf ]; then
        test_pass "/etc/dnsmasq.d/openpath.conf exists"
    else
        test_fail "dnsmasq configuration not found"
        all_ok=false
    fi
    
    if [ -f /var/lib/openpath/whitelist.txt ]; then
        local count
        count=$(grep -cv "^#\|^$" /var/lib/openpath/whitelist.txt 2>/dev/null || echo "0")
        test_pass "Allowlist downloaded ($count domains)"
    else
        test_warn "Whitelist not downloaded yet (the timer will do it)"
    fi
    
    # Config in /etc/ (Debian FHS compliant)
    if [ -f /etc/openpath/whitelist-url.conf ]; then
        test_pass "Allowlist URL configured"
    else
        test_fail "Allowlist URL not configured"
        all_ok=false
    fi
    
    $all_ok
}

# ============== Main ==============

main() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Smoke Tests - OpenPath System v$VERSION${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    
    # Critical tests always run.
    test_dnsmasq_running
    test_port_53
    
    if [ "$QUICK_MODE" = false ]; then
        # Full tests.
        test_dns_resolves_whitelisted
        test_dns_blocks_unknown
        test_firewall_rules
        test_config_files
    fi
    
    # Summary.
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "  Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}, ${YELLOW}$WARNINGS warnings${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""
    
    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}✗ SMOKE TESTS FAILED${NC}"
        echo ""
        echo "The system may not work correctly."
        echo "Run 'openpath status' for more details."
        return 1
    elif [ "$WARNINGS" -gt 0 ]; then
        echo -e "${YELLOW}⚠ SMOKE TESTS PASSED WITH WARNINGS${NC}"
        echo ""
        return 0
    else
        echo -e "${GREEN}✓ SMOKE TESTS PASSED${NC}"
        echo ""
        return 0
    fi
}

# Verify root.
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run with sudo"
    exit 1
fi

main "$@"
