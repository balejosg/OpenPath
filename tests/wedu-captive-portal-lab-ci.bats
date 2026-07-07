#!/usr/bin/env bats
################################################################################
# wedu-captive-portal-lab-ci.bats - Contract pins for the WEDU captive-portal
# lab CI driver (scripts/run-wedu-captive-portal-lab-ci.sh).
#
# The Windows runner (Proxmox VM) can carry a leftover OpenPath DNS-enforcement
# component across runs: AcrylicDNSProxySvc Running plus the adapter DNS pinned
# to the Acrylic loopback 127.0.0.1. That pin survives the pre-lab snapshot and
# keeps the DHCP-offered lab resolver 10.77.0.53 off the adapter, so the network
# convergence loop never sees the expected DNS and the lab fails intermittently.
#
# configure_windows_lab_network() must therefore neutralize that leftover pin
# (stop Acrylic + reset adapter DNS) BEFORE its convergence loop, mirroring the
# firewall pre-clean already present in move_windows_vm_to_lab(). These tests pin
# that step so a future edit cannot silently drop it or move it after the loop.
################################################################################

load 'test_helper'

setup() {
    SCRIPT="$PROJECT_DIR/scripts/run-wedu-captive-portal-lab-ci.sh"
}

@test "WEDU lab CI driver exists" {
    [ -f "$SCRIPT" ]
}

@test "configure_windows_lab_network stops the leftover Acrylic DNS proxy service" {
    grep -q "Stop-Service -Name 'AcrylicDNSProxySvc'" "$SCRIPT"
}

@test "configure_windows_lab_network resets the leftover adapter DNS pin to DHCP" {
    # The static 127.0.0.1 pin is cleared by resetting adapter DNS so the
    # DHCP-offered lab resolver (10.77.0.53) can take on the adapter.
    grep -q 'ResetServerAddresses' "$SCRIPT"
}

@test "Acrylic neutralization is best-effort / non-fatal like the firewall pre-clean" {
    grep -q 'Acrylic DNS pin neutralization warning (non-fatal)' "$SCRIPT"
}

@test "Acrylic neutralization runs inside configure_windows_lab_network, before the convergence loop" {
    local func_line stop_line loop_line
    func_line="$(grep -n '^configure_windows_lab_network() {' "$SCRIPT" | head -1 | cut -d: -f1)"
    stop_line="$(grep -n "Stop-Service -Name 'AcrylicDNSProxySvc'" "$SCRIPT" | head -1 | cut -d: -f1)"
    # Fixed-string match: the heredoc stores the PowerShell loop verbatim as
    # 'for (\$attempt = 1', so BRE would mis-handle the literal backslash-dollar.
    loop_line="$(grep -Fn 'for (\$attempt = 1' "$SCRIPT" | head -1 | cut -d: -f1)"

    [ -n "$func_line" ]
    [ -n "$stop_line" ]
    [ -n "$loop_line" ]
    # Must be after the function opens and strictly before the DHCP convergence loop.
    [ "$func_line" -lt "$stop_line" ]
    [ "$stop_line" -lt "$loop_line" ]
}
