import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readText } from './support.mjs';

/**
 * T6 — CLI surface parity contract tests.
 *
 * Both the Linux CLI entrypoint (openpath-cmd.sh / runtime-cli-system.sh) and
 * the Windows CLI entrypoint (OpenPath.ps1) must expose the same canonical verb
 * set.  These tests read each entrypoint as plain text so that a missing verb,
 * accidental deletion, or rename is caught before release.
 *
 * Canonical verbs: status, health, doctor browser, domains, check, enable,
 * disable, update.
 */
describe('T6: CLI surface parity — both platforms expose the canonical verb set', () => {
  // ── Windows ────────────────────────────────────────────────────────────────

  test('Windows OpenPath.ps1 dispatches the canonical verb set', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');

    for (const verb of ['status', 'update', 'health', 'enable', 'disable']) {
      assert.ok(
        openPathPs1.includes(`'${verb}'`),
        `windows/OpenPath.ps1 switch must include case '${verb}'`
      );
    }
  });

  test('Windows OpenPath.ps1 dispatches doctor with browser sub-target', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    assert.ok(
      openPathPs1.includes("'doctor'"),
      "windows/OpenPath.ps1 switch must include case 'doctor'"
    );
    assert.ok(
      openPathPs1.includes("'browser'") && openPathPs1.includes('Get-OpenPathBrowserDoctorReport'),
      "windows/OpenPath.ps1 doctor must handle 'browser' sub-target via Get-OpenPathBrowserDoctorReport"
    );
  });

  test('Windows OpenPath.ps1 dispatches domains and check', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    assert.ok(
      openPathPs1.includes("'domains'"),
      "windows/OpenPath.ps1 switch must include case 'domains'"
    );
    assert.ok(
      openPathPs1.includes("'check'"),
      "windows/OpenPath.ps1 switch must include case 'check'"
    );
  });

  test('Windows OpenPath.ps1 enable uses Enable-OpenPathFirewall and Start-AcrylicService', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    assert.ok(
      openPathPs1.includes('Enable-OpenPathFirewall'),
      'windows/OpenPath.ps1 enable must call Enable-OpenPathFirewall'
    );
    assert.ok(
      openPathPs1.includes('Start-AcrylicService'),
      'windows/OpenPath.ps1 enable must call Start-AcrylicService'
    );
  });

  test('Windows OpenPath.ps1 disable uses Disable-OpenPathFirewall and Stop-AcrylicService', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    assert.ok(
      openPathPs1.includes('Disable-OpenPathFirewall'),
      'windows/OpenPath.ps1 disable must call Disable-OpenPathFirewall'
    );
    assert.ok(
      openPathPs1.includes('Stop-AcrylicService'),
      'windows/OpenPath.ps1 disable must call Stop-AcrylicService'
    );
  });

  test('Windows OpenPath.ps1 domains reads from local whitelist file via Get-OpenPathWhitelistSectionsFromFile', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    assert.ok(
      openPathPs1.includes('Get-OpenPathWhitelistSectionsFromFile'),
      'windows/OpenPath.ps1 domains must use Get-OpenPathWhitelistSectionsFromFile to read the local whitelist'
    );
  });

  test('Windows OpenPath.ps1 check uses Test-DNSSinkhole and Test-DNSResolution', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    assert.ok(
      openPathPs1.includes('Test-DNSSinkhole'),
      'windows/OpenPath.ps1 check must call Test-DNSSinkhole'
    );
    assert.ok(
      openPathPs1.includes('Test-DNSResolution'),
      'windows/OpenPath.ps1 check must call Test-DNSResolution'
    );
  });

  test('Windows OpenPath.ps1 help text documents all canonical verbs', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    for (const verb of [
      'status',
      'update',
      'health',
      'doctor',
      'domains',
      'check',
      'enable',
      'disable',
    ]) {
      assert.ok(
        openPathPs1.includes(`'  ${verb}`),
        `windows/OpenPath.ps1 Show-OpenPathHelp must document '${verb}'`
      );
    }
  });

  // ── Linux ──────────────────────────────────────────────────────────────────

  test('Linux openpath-cmd.sh dispatches the canonical verb set', () => {
    const openpathCmd = readText('linux/scripts/runtime/openpath-cmd.sh');

    for (const verb of ['status', 'update', 'health', 'enable', 'disable', 'domains', 'check']) {
      assert.ok(
        openpathCmd.includes(`${verb})`),
        `linux/scripts/runtime/openpath-cmd.sh case statement must include '${verb})'`
      );
    }
  });

  test('Linux openpath-cmd.sh dispatches the doctor verb', () => {
    const openpathCmd = readText('linux/scripts/runtime/openpath-cmd.sh');
    assert.ok(
      openpathCmd.includes('doctor)') || openpathCmd.includes('doctor)'),
      'linux/scripts/runtime/openpath-cmd.sh must dispatch the doctor verb'
    );
    assert.ok(
      openpathCmd.includes('cmd_doctor'),
      'linux/scripts/runtime/openpath-cmd.sh must call cmd_doctor'
    );
  });

  test('Linux runtime-cli-system.sh defines cmd_doctor and cmd_doctor_browser', () => {
    const runtimeCli = readText('linux/lib/runtime-cli-system.sh');
    assert.ok(
      runtimeCli.includes('cmd_doctor()'),
      'linux/lib/runtime-cli-system.sh must define cmd_doctor()'
    );
    assert.ok(
      runtimeCli.includes('cmd_doctor_browser()'),
      'linux/lib/runtime-cli-system.sh must define cmd_doctor_browser()'
    );
  });

  test('Linux cmd_doctor_browser reports the same fact keys as Windows Get-OpenPathBrowserDoctorReport', () => {
    const runtimeCli = readText('linux/lib/runtime-cli-system.sh');
    for (const factKey of [
      'fact.request_setup',
      'fact.firefox_registration',
      'fact.firefox_native_host',
    ]) {
      assert.ok(
        runtimeCli.includes(factKey),
        `linux/lib/runtime-cli-system.sh cmd_doctor_browser must emit fact key '${factKey}' (mirrors Windows Browser Doctor report)`
      );
    }
  });

  test('Linux cmd_help documents the doctor verb', () => {
    const runtimeCli = readText('linux/lib/runtime-cli-system.sh');
    assert.ok(
      runtimeCli.includes('doctor'),
      'linux/lib/runtime-cli-system.sh cmd_help must list the doctor command'
    );
  });

  // ── Cross-platform ────────────────────────────────────────────────────────

  test('both platforms list doctor browser in their help text', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    const runtimeCli = readText('linux/lib/runtime-cli-system.sh');

    assert.ok(
      openPathPs1.includes('doctor browser') || openPathPs1.includes("'browser'"),
      'windows/OpenPath.ps1 help must document doctor browser'
    );
    assert.ok(
      runtimeCli.includes('doctor') && runtimeCli.includes('browser'),
      'linux/lib/runtime-cli-system.sh must document doctor with browser sub-target'
    );
  });

  test('both platforms implement the enable verb with enforcement semantics', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    const runtimeCli = readText('linux/lib/runtime-cli-system.sh');

    // Windows: re-enable firewall + Acrylic + trigger update
    assert.ok(
      openPathPs1.includes('Enable-OpenPathFirewall'),
      'windows/OpenPath.ps1 enable must re-enable firewall via Enable-OpenPathFirewall'
    );

    // Linux: enable_services + whitelist update (cmd_enable already existed)
    assert.ok(
      runtimeCli.includes('cmd_enable()'),
      'linux/lib/runtime-cli-system.sh must define cmd_enable()'
    );
  });

  test('both platforms implement the disable verb with passthrough semantics', () => {
    const openPathPs1 = readText('windows/OpenPath.ps1');
    const runtimeCli = readText('linux/lib/runtime-cli-system.sh');

    // Windows: disable firewall + stop Acrylic + restore DNS
    assert.ok(
      openPathPs1.includes('Disable-OpenPathFirewall'),
      'windows/OpenPath.ps1 disable must suspend firewall via Disable-OpenPathFirewall'
    );
    assert.ok(
      openPathPs1.includes('Restore-OriginalDNS'),
      'windows/OpenPath.ps1 disable must restore upstream DNS via Restore-OriginalDNS'
    );

    // Linux: enter_disabled_mode (DNS passthrough)
    assert.ok(
      runtimeCli.includes('cmd_disable()'),
      'linux/lib/runtime-cli-system.sh must define cmd_disable()'
    );
    assert.ok(
      runtimeCli.includes('enter_disabled_mode'),
      'linux/lib/runtime-cli-system.sh cmd_disable must call enter_disabled_mode'
    );
  });
});
