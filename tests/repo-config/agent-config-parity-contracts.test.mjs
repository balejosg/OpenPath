import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readText } from './support.mjs';

/**
 * Cross-platform agent config parity contract tests.
 *
 * These tests read the platform config sources and the parity doc as plain
 * text and assert that documented defaults match the actual source values.
 * A drift between the doc and source (e.g., someone bumps the Windows default
 * without updating the doc, or vice versa) will be caught here before release.
 *
 * Golden rule: update both the source AND the doc together; this test enforces
 * that they stay in sync.
 *
 * Source of truth: docs/agent-config-parity.md
 */
describe('agent-config-parity: documented defaults match source values', () => {
  // ── Update interval ────────────────────────────────────────────────────────

  test('Linux defaults.conf: TIMER_INTERVAL_MINUTES defaults to 5', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('TIMER_INTERVAL_MINUTES="${OPENPATH_TIMER_INTERVAL:-5}"'),
      'linux/lib/defaults.conf must set TIMER_INTERVAL_MINUTES with default 5 (OPENPATH_TIMER_INTERVAL override)'
    );
  });

  test('Windows Installer.Config.ps1: updateIntervalMinutes defaults to 5', () => {
    const config = readText('windows/lib/install/Installer.Config.ps1');
    assert.ok(
      config.includes('updateIntervalMinutes = 5'),
      'windows/lib/install/Installer.Config.ps1 must set updateIntervalMinutes = 5'
    );
  });

  test('Windows Common.Update.ps1: in-process fallback for updateIntervalMinutes is 5', () => {
    const update = readText('windows/lib/internal/Common.Update.ps1');
    assert.ok(
      update.includes('$updateInterval = 5'),
      'windows/lib/internal/Common.Update.ps1 must default $updateInterval to 5 when the key is absent from config'
    );
  });

  test('Windows Install-OpenPath.ps1: registers scheduled task with UpdateIntervalMinutes 5', () => {
    const installer = readText('windows/Install-OpenPath.ps1');
    assert.ok(
      installer.includes(
        'Register-OpenPathTask -UpdateIntervalMinutes 5 -WatchdogIntervalMinutes 1'
      ),
      'windows/Install-OpenPath.ps1 must call Register-OpenPathTask with -UpdateIntervalMinutes 5'
    );
  });

  // ── Failure semantics ──────────────────────────────────────────────────────

  test('Linux defaults.conf: FAILURE_MODE defaults to protected', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('FAILURE_MODE="${OPENPATH_FAILURE_MODE:-protected}"'),
      'linux/lib/defaults.conf must define FAILURE_MODE with default "protected"'
    );
  });

  test('Windows Installer.Config.ps1: enableStaleFailsafe defaults to true', () => {
    const config = readText('windows/lib/install/Installer.Config.ps1');
    assert.ok(
      config.includes('enableStaleFailsafe = $true'),
      'windows/lib/install/Installer.Config.ps1 must set enableStaleFailsafe = $true'
    );
  });

  // ── Whitelist max age ──────────────────────────────────────────────────────

  test('Linux defaults.conf: WHITELIST_MAX_AGE_HOURS defaults to 24', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('WHITELIST_MAX_AGE_HOURS="${OPENPATH_WHITELIST_MAX_AGE_HOURS:-24}"'),
      'linux/lib/defaults.conf must define WHITELIST_MAX_AGE_HOURS with default 24'
    );
  });

  test('Windows Installer.Config.ps1: staleWhitelistMaxAgeHours defaults to 24', () => {
    const config = readText('windows/lib/install/Installer.Config.ps1');
    assert.ok(
      config.includes('staleWhitelistMaxAgeHours = 24'),
      'windows/lib/install/Installer.Config.ps1 must set staleWhitelistMaxAgeHours = 24'
    );
  });

  // ── Checkpoints ────────────────────────────────────────────────────────────

  test('Linux defaults.conf: MAX_CHECKPOINTS defaults to 3', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('MAX_CHECKPOINTS="${OPENPATH_MAX_CHECKPOINTS:-3}"'),
      'linux/lib/defaults.conf must define MAX_CHECKPOINTS with default 3'
    );
  });

  test('Windows Installer.Config.ps1: maxCheckpoints defaults to 3', () => {
    const config = readText('windows/lib/install/Installer.Config.ps1');
    assert.ok(
      config.includes('maxCheckpoints = 3'),
      'windows/lib/install/Installer.Config.ps1 must set maxCheckpoints = 3'
    );
  });

  // ── Logging (Windows-only) ─────────────────────────────────────────────────

  test('Windows OpenPathConfig.Model.ps1: logMaxSizeMb defaults to 5', () => {
    const model = readText('windows/lib/internal/OpenPathConfig.Model.ps1');
    assert.ok(
      model.includes(
        "Get-OpenPathConfigValue -Config $normalized -Name 'logMaxSizeMb' -DefaultValue 5"
      ),
      'windows/lib/internal/OpenPathConfig.Model.ps1 must default logMaxSizeMb to 5'
    );
  });

  test('Windows OpenPathConfig.Model.ps1: logKeepFiles defaults to 3', () => {
    const model = readText('windows/lib/internal/OpenPathConfig.Model.ps1');
    assert.ok(
      model.includes(
        "Get-OpenPathConfigValue -Config $normalized -Name 'logKeepFiles' -DefaultValue 3"
      ),
      'windows/lib/internal/OpenPathConfig.Model.ps1 must default logKeepFiles to 3'
    );
  });

  // ── SSE cooldown ───────────────────────────────────────────────────────────

  test('Linux defaults.conf: SSE_UPDATE_COOLDOWN defaults to 10', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('SSE_UPDATE_COOLDOWN="${OPENPATH_SSE_UPDATE_COOLDOWN:-10}"'),
      'linux/lib/defaults.conf must define SSE_UPDATE_COOLDOWN with default 10'
    );
  });

  test('Windows OpenPathConfig.Model.ps1: sseUpdateCooldown defaults to 10', () => {
    const model = readText('windows/lib/internal/OpenPathConfig.Model.ps1');
    assert.ok(
      model.includes(
        "Get-OpenPathConfigValue -Config $normalized -Name 'sseUpdateCooldown' -DefaultValue 10"
      ),
      'windows/lib/internal/OpenPathConfig.Model.ps1 must default sseUpdateCooldown to 10'
    );
  });

  // ── DoH blocking ──────────────────────────────────────────────────────────

  test('Linux defaults.conf: DOH_BLOCK_ENABLED defaults to 1', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('DOH_BLOCK_ENABLED="${OPENPATH_DOH_BLOCK_ENABLED:-1}"'),
      'linux/lib/defaults.conf must define DOH_BLOCK_ENABLED with default 1'
    );
  });

  test('Windows Installer.Config.ps1: enableDohIpBlocking defaults to true', () => {
    const config = readText('windows/lib/install/Installer.Config.ps1');
    assert.ok(
      config.includes('enableDohIpBlocking = $true'),
      'windows/lib/install/Installer.Config.ps1 must set enableDohIpBlocking = $true'
    );
  });

  // ── VPN blocking ──────────────────────────────────────────────────────────

  test('Linux defaults.conf: VPN_BLOCK_ENABLED defaults to 1', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('VPN_BLOCK_ENABLED="${OPENPATH_VPN_BLOCK_ENABLED:-1}"'),
      'linux/lib/defaults.conf must define VPN_BLOCK_ENABLED with default 1'
    );
  });

  test('Linux defaults.conf: VPN_BLOCK_INTERFACES defaults to tun+,tap+', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('VPN_BLOCK_INTERFACES="${OPENPATH_VPN_BLOCK_INTERFACES:-tun+,tap+}"'),
      'linux/lib/defaults.conf must define VPN_BLOCK_INTERFACES with default tun+,tap+'
    );
  });

  // ── Tor blocking ──────────────────────────────────────────────────────────

  test('Linux defaults.conf: TOR_BLOCK_ENABLED defaults to 1', () => {
    const defaults = readText('linux/lib/defaults.conf');
    assert.ok(
      defaults.includes('TOR_BLOCK_ENABLED="${OPENPATH_TOR_BLOCK_ENABLED:-1}"'),
      'linux/lib/defaults.conf must define TOR_BLOCK_ENABLED with default 1'
    );
  });

  // ── Parity doc existence and content ──────────────────────────────────────

  test('docs/agent-config-parity.md exists and documents the 5-minute alignment decision', () => {
    const doc = readText('docs/agent-config-parity.md');
    assert.ok(
      doc.includes('5-minute'),
      'docs/agent-config-parity.md must document the 5-minute polling interval alignment'
    );
    assert.ok(
      doc.includes('SSE') && doc.includes('primary'),
      'docs/agent-config-parity.md must state that SSE is the primary update trigger'
    );
    assert.ok(
      doc.includes('TIMER_INTERVAL_MINUTES'),
      'docs/agent-config-parity.md must document TIMER_INTERVAL_MINUTES (Linux key)'
    );
    assert.ok(
      doc.includes('updateIntervalMinutes'),
      'docs/agent-config-parity.md must document updateIntervalMinutes (Windows key)'
    );
  });

  test('docs/agent-config-parity.md documents all major tunables', () => {
    const doc = readText('docs/agent-config-parity.md');
    const required = [
      'FAILURE_MODE',
      'WHITELIST_MAX_AGE_HOURS',
      'MAX_CHECKPOINTS',
      'SSE_UPDATE_COOLDOWN',
      'DOH_BLOCK_ENABLED',
      'VPN_BLOCK_ENABLED',
      'TOR_BLOCK_ENABLED',
      'logMaxSizeMb',
      'logKeepFiles',
      'sseUpdateCooldown',
      'maxCheckpoints',
      'enableDohIpBlocking',
    ];
    for (const key of required) {
      assert.ok(doc.includes(key), `docs/agent-config-parity.md must document key: ${key}`);
    }
  });
});
