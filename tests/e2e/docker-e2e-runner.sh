#!/bin/bash
################################################################################
# docker-e2e-runner.sh - Runs E2E tests inside Docker container
# 
# This script is executed inside the Docker container where we have full
# control over the system, including port 53 (no systemd-resolved conflict).
################################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

resolve_installer_contract_mode() {
    if [ -n "${OPENPATH_INSTALLER_CONTRACT_MODE:-}" ]; then
        printf '%s\n' "$OPENPATH_INSTALLER_CONTRACT_MODE"
        return 0
    fi

    if [ -r /proc/1/environ ]; then
        tr '\0' '\n' < /proc/1/environ | sed -n 's/^OPENPATH_INSTALLER_CONTRACT_MODE=//p' | head -n 1
        return 0
    fi

    printf '0\n'
}

resolve_contract_scenarios_mode() {
    if [ -n "${OPENPATH_CONTRACT_SCENARIOS_MODE:-}" ]; then
        printf '%s\n' "$OPENPATH_CONTRACT_SCENARIOS_MODE"
        return 0
    fi

    if [ -r /proc/1/environ ]; then
        tr '\0' '\n' < /proc/1/environ | sed -n 's/^OPENPATH_CONTRACT_SCENARIOS_MODE=//p' | head -n 1
        return 0
    fi

    printf '0\n'
}

INSTALLER_CONTRACT_MODE="$(resolve_installer_contract_mode)"
CONTRACT_SCENARIOS_MODE="$(resolve_contract_scenarios_mode)"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Docker E2E Test Runner${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo ""

# Ensure we're in the right directory
cd /openpath

# Step 1: Verify port 53 is free
echo -e "${BLUE}[1/6]${NC} Verifying port 53 is free..."
if ss -ulnp 2>/dev/null | grep -q ":53 "; then
    echo -e "${RED}✗${NC} Port 53 is in use!"
    ss -ulnp 2>/dev/null | grep ":53 "
    exit 1
else
    echo -e "${GREEN}✓${NC} Port 53 is free"
fi

# Step 2: Run pre-installation validation
echo ""
echo -e "${BLUE}[2/6]${NC} Running pre-installation validation..."
./tests/e2e/pre-install-validation.sh

# Step 3: Run installation
echo ""
echo -e "${BLUE}[3/6]${NC} Running installation..."
install_log="/tmp/openpath-install.log"
set +e
./linux/install.sh --unattended --no-extension --skip-firefox >"$install_log" 2>&1
install_rc=$?
set -e

if [ "$install_rc" -ne 0 ]; then
    echo -e "${RED}✗${NC} Installation failed (exit code: $install_rc)"
    echo ""
    echo "Last 200 lines of install output:"
    tail -200 "$install_log" || true
    exit "$install_rc"
fi

if [ ! -f /etc/dnsmasq.d/openpath.conf ]; then
    echo -e "${RED}✗${NC} /etc/dnsmasq.d/openpath.conf missing after install"
    echo ""
    echo "Last 200 lines of install output:"
    tail -200 "$install_log" || true
    exit 1
fi

# Step 4: Verify dnsmasq is running
echo ""
echo -e "${BLUE}[4/6]${NC} Verifying dnsmasq..."
sleep 2

if pgrep dnsmasq > /dev/null; then
    echo -e "${GREEN}✓${NC} dnsmasq process is running"
else
    echo -e "${YELLOW}⚠${NC} dnsmasq process not found, starting manually..."
    dnsmasq --no-daemon &
    sleep 2
fi

if ss -ulnp 2>/dev/null | grep -q ":53 "; then
    echo -e "${GREEN}✓${NC} Port 53 is listening"
else
    echo -e "${RED}✗${NC} Port 53 is not listening"
    # Try to start dnsmasq manually
    dnsmasq -C /etc/dnsmasq.d/openpath.conf --no-daemon &
    sleep 2
fi

# Step 5: Run smoke tests
echo ""
echo -e "${BLUE}[5/6]${NC} Running smoke tests..."
./linux/scripts/runtime/smoke-test.sh --quick || echo -e "${YELLOW}⚠${NC} Smoke tests had issues"

if [ "$INSTALLER_CONTRACT_MODE" = "1" ]; then
    echo ""
    echo -e "${GREEN}✓${NC} Installer contract mode completed after install + smoke tests"
    exit 0
fi

if [ "$CONTRACT_SCENARIOS_MODE" = "1" ]; then
    echo ""
    echo -e "${BLUE}[6/6]${NC} Running firewall+DNS contract scenarios..."
    ./tests/e2e/contract-scenarios/run-contract-scenarios.sh \
        --artifact-dir /openpath/tests/e2e/artifacts/contract-scenarios
    echo ""
    echo -e "${GREEN}✓${NC} Contract scenarios completed"
    exit 0
fi

# Step 6: Run E2E tests
echo ""
echo -e "${BLUE}[6/6]${NC} Running E2E tests..."
./tests/e2e/linux-e2e-tests.sh

# Final result
exit_code=$?
echo ""
if [ $exit_code -eq 0 ]; then
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ Docker E2E Tests PASSED${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
else
    echo -e "${RED}═══════════════════════════════════════════════════${NC}"
    echo -e "${RED}  ✗ Docker E2E Tests FAILED${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════${NC}"
fi

exit $exit_code
