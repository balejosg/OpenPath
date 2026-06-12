import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readText } from './support.mjs';

/**
 * ADR 0011 — cross-platform failure-semantics contract tests.
 *
 * Both the Linux watchdog (Bash) and the Windows watchdog (PowerShell) must
 * implement the same fail-closed-with-critical-domains-valve posture.  These
 * tests read each platform's source as plain text and assert on the key
 * identifiers that anchor the shared behaviour, so that a rename or accidental
 * deletion is caught before release.
 */
describe('ADR 0011: unified failure semantics — both platforms implement protected mode', () => {
  // ── Linux ──────────────────────────────────────────────────────────────────

  test('Linux watchdog defines the WATCHDOG_PROTECTED_FLAG state file', () => {
    const watchdog = readText('linux/scripts/runtime/dnsmasq-watchdog.sh');
    assert.ok(
      watchdog.includes('WATCHDOG_PROTECTED_FLAG'),
      'linux/scripts/runtime/dnsmasq-watchdog.sh must define WATCHDOG_PROTECTED_FLAG for protected-mode state'
    );
  });

  test('Linux watchdog defines enter_protected_mode and exit_protected_mode', () => {
    const watchdog = readText('linux/scripts/runtime/dnsmasq-watchdog.sh');
    assert.ok(
      watchdog.includes('enter_protected_mode()'),
      'linux/scripts/runtime/dnsmasq-watchdog.sh must define enter_protected_mode()'
    );
    assert.ok(
      watchdog.includes('exit_protected_mode()'),
      'linux/scripts/runtime/dnsmasq-watchdog.sh must define exit_protected_mode()'
    );
  });

  test('Linux watchdog calls enter_protected_mode on threshold exhaustion (not only deactivate_firewall)', () => {
    const watchdog = readText('linux/scripts/runtime/dnsmasq-watchdog.sh');
    assert.ok(
      watchdog.includes('enter_protected_mode'),
      'linux/scripts/runtime/dnsmasq-watchdog.sh must call enter_protected_mode when the fail threshold is reached'
    );
  });

  test('Linux watchdog implements OPENPATH_FAILURE_MODE escape hatch', () => {
    const watchdog = readText('linux/scripts/runtime/dnsmasq-watchdog.sh');
    assert.ok(
      watchdog.includes('_watchdog_failure_mode_is_open'),
      'linux/scripts/runtime/dnsmasq-watchdog.sh must define _watchdog_failure_mode_is_open() for the escape hatch'
    );
    assert.ok(
      watchdog.includes('FAILURE_MODE'),
      'linux/scripts/runtime/dnsmasq-watchdog.sh must reference FAILURE_MODE'
    );
  });

  test('Linux watchdog calls exit_protected_mode on recovery', () => {
    const watchdog = readText('linux/scripts/runtime/dnsmasq-watchdog.sh');
    assert.ok(
      watchdog.includes('exit_protected_mode'),
      'linux/scripts/runtime/dnsmasq-watchdog.sh must call exit_protected_mode() during recovery'
    );
  });

  test('Linux dns-dnsmasq.sh defines write_dnsmasq_protected_mode_config', () => {
    const dnsDnsmasq = readText('linux/lib/dns-dnsmasq.sh');
    assert.ok(
      dnsDnsmasq.includes('write_dnsmasq_protected_mode_config()'),
      'linux/lib/dns-dnsmasq.sh must define write_dnsmasq_protected_mode_config() to produce the restricted dnsmasq config'
    );
    assert.ok(
      dnsDnsmasq.includes('OPENPATH PROTECTED MODE'),
      'linux/lib/dns-dnsmasq.sh write_dnsmasq_protected_mode_config must write a recognisable OPENPATH PROTECTED MODE header'
    );
    assert.ok(
      dnsDnsmasq.includes('get_openpath_protected_domains'),
      'linux/lib/dns-dnsmasq.sh write_dnsmasq_protected_mode_config must derive domains from get_openpath_protected_domains()'
    );
  });

  test('Linux defaults.conf declares FAILURE_MODE with OPENPATH_FAILURE_MODE override', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('FAILURE_MODE="${OPENPATH_FAILURE_MODE:-protected}"'),
      'linux/lib/defaults.conf must define FAILURE_MODE with default "protected" and OPENPATH_FAILURE_MODE override'
    );
  });

  test('Linux common-protected-domains.sh exposes captive-portal probe and OS/system domain helpers', () => {
    const domains = readText('linux/lib/common-protected-domains.sh');
    assert.ok(
      domains.includes('get_openpath_captive_portal_probe_domains()'),
      'linux/lib/common-protected-domains.sh must define get_openpath_captive_portal_probe_domains()'
    );
    assert.ok(
      domains.includes('get_openpath_os_system_domains()'),
      'linux/lib/common-protected-domains.sh must define get_openpath_os_system_domains()'
    );
  });

  test('Linux common-protected-domains.sh includes captive portal probes in the protected set', () => {
    const domains = readText('linux/lib/common-protected-domains.sh');
    assert.ok(
      domains.includes('detectportal.firefox.com'),
      'linux/lib/common-protected-domains.sh must include detectportal.firefox.com as a captive-portal probe domain'
    );
    assert.ok(
      domains.includes('connectivity-check.ubuntu.com'),
      'linux/lib/common-protected-domains.sh must include connectivity-check.ubuntu.com'
    );
  });

  test('Linux common-protected-domains.sh includes OS/system domains in the protected set', () => {
    const domains = readText('linux/lib/common-protected-domains.sh');
    assert.ok(
      domains.includes('ntp.ubuntu.com'),
      'linux/lib/common-protected-domains.sh must include ntp.ubuntu.com as an OS/system domain'
    );
  });

  test('Linux ADR 0011 document exists and describes the protected-mode decision', () => {
    const adr = readText('docs/adr/0011-unified-failure-semantics.md');
    assert.ok(
      adr.includes('protected mode'),
      'docs/adr/0011-unified-failure-semantics.md must describe "protected mode"'
    );
    assert.ok(
      adr.includes('OPENPATH_FAILURE_MODE'),
      'docs/adr/0011-unified-failure-semantics.md must document the OPENPATH_FAILURE_MODE escape hatch'
    );
    assert.ok(
      adr.includes('staging') || adr.includes('lab'),
      'docs/adr/0011-unified-failure-semantics.md must mention staging/lab validation before production'
    );
  });

  // ── Windows ─────────────────────────────────────────────────────────────────

  test('Windows Update.Runtime.psm1 defines Enter-StaleWhitelistFailsafe (critical-domains valve)', () => {
    const updateRuntime = readText('windows/lib/Update.Runtime.psm1');
    assert.ok(
      updateRuntime.includes('Enter-StaleWhitelistFailsafe'),
      'windows/lib/Update.Runtime.psm1 must define Enter-StaleWhitelistFailsafe for the protected-mode (stale-failsafe) path'
    );
  });

  test('Windows stale-failsafe state is persisted to a known path', () => {
    const updateRuntime = readText('windows/lib/Update.Runtime.psm1');
    assert.ok(
      updateRuntime.includes('stale-failsafe-state.json'),
      'windows/lib/Update.Runtime.psm1 must persist protected-mode state to stale-failsafe-state.json'
    );
  });

  test('Windows EndpointPolicyState.ps1 defines ProtectedModeEligible', () => {
    const policyState = readText('windows/lib/internal/EndpointPolicyState.ps1');
    assert.ok(
      policyState.includes('ProtectedModeEligible'),
      'windows/lib/internal/EndpointPolicyState.ps1 must define ProtectedModeEligible to gate protected-mode checks'
    );
  });

  test('Windows EndpointStateReconciler.ps1 defines New-OpenPathWatchdogProtectedModeRepairPlan', () => {
    const reconciler = readText('windows/lib/internal/EndpointStateReconciler.ps1');
    assert.ok(
      reconciler.includes('New-OpenPathWatchdogProtectedModeRepairPlan'),
      'windows/lib/internal/EndpointStateReconciler.ps1 must define New-OpenPathWatchdogProtectedModeRepairPlan'
    );
  });

  test('Windows watchdog does not unconditionally open the firewall on threshold exhaustion', () => {
    const watchdog = readText('windows/lib/internal/Watchdog.Runtime.ps1');
    // The Windows watchdog must use protected-mode checks, not a raw firewall removal.
    assert.ok(
      watchdog.includes('ProtectedModeEligible') ||
        watchdog.includes('shouldRunProtectedModeChecks'),
      'windows/lib/internal/Watchdog.Runtime.ps1 must gate actions on ProtectedModeEligible / shouldRunProtectedModeChecks'
    );
    assert.ok(
      !watchdog.includes('Remove-OpenPathFirewall'),
      'windows/lib/internal/Watchdog.Runtime.ps1 must not call Remove-OpenPathFirewall unconditionally (that is fail-open)'
    );
  });

  // ── Cross-platform ───────────────────────────────────────────────────────────

  test('both platforms write a protected-mode state marker file', () => {
    const linuxWatchdog = readText('linux/scripts/runtime/dnsmasq-watchdog.sh');
    const windowsRuntime = readText('windows/lib/Update.Runtime.psm1');

    assert.ok(
      linuxWatchdog.includes('watchdog-protected.flag'),
      'Linux watchdog must write the watchdog-protected.flag state marker'
    );
    assert.ok(
      windowsRuntime.includes('stale-failsafe-state.json'),
      'Windows runtime must write the stale-failsafe-state.json state marker'
    );
  });

  test('both platforms keep DNS enforcement active (not passthrough) during failure', () => {
    const linuxDnsDnsmasq = readText('linux/lib/dns-dnsmasq.sh');
    const windowsReconciler = readText('windows/lib/internal/EndpointStateReconciler.ps1');

    // Linux: protected-mode config must include sinkhole directives
    assert.ok(
      linuxDnsDnsmasq.includes('address=/#/') || linuxDnsDnsmasq.includes('sinkhole_ipv4'),
      'linux/lib/dns-dnsmasq.sh write_dnsmasq_protected_mode_config must retain sinkhole directives during protected mode'
    );

    // Windows: the watchdog protected-mode repair plan (New-OpenPathWatchdogProtectedModeRepairPlan)
    // must not add a RemoveFirewall action — that action is only for the explicit FailOpen mode
    // in New-OpenPathEndpointStateRepairPlan.  Verify this by checking that the watchdog-specific
    // plan function does not include RemoveFirewall in its actions array.
    const watchdogRepairPlanStart = windowsReconciler.indexOf(
      'function New-OpenPathWatchdogProtectedModeRepairPlan'
    );
    const watchdogRepairPlanEnd = windowsReconciler.indexOf(
      '\nfunction ',
      watchdogRepairPlanStart + 1
    );
    const watchdogRepairPlanBody =
      watchdogRepairPlanEnd > 0
        ? windowsReconciler.slice(watchdogRepairPlanStart, watchdogRepairPlanEnd)
        : windowsReconciler.slice(watchdogRepairPlanStart);

    assert.ok(
      watchdogRepairPlanStart >= 0,
      'windows/lib/internal/EndpointStateReconciler.ps1 must define New-OpenPathWatchdogProtectedModeRepairPlan'
    );
    assert.ok(
      !watchdogRepairPlanBody.includes("'RemoveFirewall'"),
      'New-OpenPathWatchdogProtectedModeRepairPlan must not include RemoveFirewall in its actions (that is fail-open, not protected mode)'
    );
  });
});
