import { describe, it } from 'node:test';
import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { HealthReportSubmitInput } from '../src/schemas/index.js';

const currentFilePath = fileURLToPath(import.meta.url);
const currentDir = dirname(currentFilePath);
const contractsDir = resolve(currentDir, '../../tests/contracts');

function readFixture(name: string): unknown {
  const raw = readFileSync(resolve(contractsDir, name), 'utf8');
  return JSON.parse(raw);
}

describe('HealthReportSubmitInput schema', () => {
  // ── Base field validation ───────────────────────────────────────────────────

  it('accepts a minimal valid payload (hostname + status only)', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({ hostname: 'pc-01', status: 'HEALTHY' })
    );
  });

  it('rejects payload missing hostname', () => {
    assert.throws(() => HealthReportSubmitInput.parse({ status: 'HEALTHY' }));
  });

  it('rejects payload with empty hostname', () => {
    assert.throws(() => HealthReportSubmitInput.parse({ hostname: '', status: 'HEALTHY' }));
  });

  it('rejects payload missing status', () => {
    assert.throws(() => HealthReportSubmitInput.parse({ hostname: 'pc-01' }));
  });

  // ── Canonical new fields ────────────────────────────────────────────────────

  it('accepts canonical dnsState boolean', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({ hostname: 'pc-01', status: 'HEALTHY', dnsState: true })
    );
  });

  it('accepts firewallState boolean', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({ hostname: 'pc-01', status: 'HEALTHY', firewallState: false })
    );
  });

  it('accepts whitelistAgeHours as non-negative number', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        whitelistAgeHours: 1.5,
      })
    );
  });

  it('rejects negative whitelistAgeHours', () => {
    assert.throws(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        whitelistAgeHours: -1,
      })
    );
  });

  it('accepts captivePortalMode boolean', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        captivePortalMode: true,
      })
    );
  });

  it('accepts agentVersion string (canonical alias for version)', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        agentVersion: '1.2.3',
      })
    );
  });

  it('accepts platform linux', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({ hostname: 'pc-01', status: 'HEALTHY', platform: 'linux' })
    );
  });

  it('accepts platform windows', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({ hostname: 'pc-01', status: 'HEALTHY', platform: 'windows' })
    );
  });

  it('rejects unknown platform value', () => {
    assert.throws(() =>
      HealthReportSubmitInput.parse({ hostname: 'pc-01', status: 'HEALTHY', platform: 'darwin' })
    );
  });

  // ── Legacy fields (backward compat) ─────────────────────────────────────────

  it('accepts legacy dnsmasqRunning + dnsResolving without new fields', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'DEGRADED',
        dnsmasqRunning: false,
        dnsResolving: false,
        failCount: 3,
        actions: 'dnsmasq_restart',
        version: '1.0.2',
      })
    );
  });

  it('accepts legacy version without agentVersion', () => {
    const parsed = HealthReportSubmitInput.parse({
      hostname: 'pc-01',
      status: 'HEALTHY',
      version: '1.0.4',
    });
    assert.strictEqual(parsed.version, '1.0.4');
    assert.strictEqual(parsed.agentVersion, undefined);
  });

  // ── Windows extension block ──────────────────────────────────────────────────

  it('accepts windows extension block with appLockerState and browserEnforcement', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'win-pc-01',
        status: 'HEALTHY',
        platform: 'windows',
        windows: {
          appLockerState: 'Enforced',
          browserEnforcement: 'Active',
        },
      })
    );
  });

  it('accepts partial windows extension block (only appLockerState)', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'win-pc-01',
        status: 'HEALTHY',
        platform: 'windows',
        windows: { appLockerState: 'Enforced' },
      })
    );
  });

  // ── passthrough (unknown extra fields must not hard-fail telemetry) ──────────

  it('passes through unknown extra fields without throwing', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        someNewFutureField: 'value',
      })
    );
  });

  // ── PROTECTED status (Linux ADR-0011 protected mode) ────────────────────────

  it('accepts PROTECTED status (ADR-0011 protected mode)', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({ hostname: 'pc-01', status: 'PROTECTED' })
    );
  });

  // ── Fixture-based round-trip tests ──────────────────────────────────────────

  it('parses Linux agent fixture (post-alignment payload)', () => {
    const fixture = readFixture('health-report-linux.fixture.json') as { json: unknown };
    assert.doesNotThrow(() => HealthReportSubmitInput.parse(fixture.json));
    const parsed = HealthReportSubmitInput.parse(fixture.json);
    assert.strictEqual(parsed.platform, 'linux');
    assert.strictEqual(parsed.agentVersion, '1.0.4');
    assert.strictEqual(parsed.dnsState, true);
  });

  it('parses Windows agent fixture (post-alignment payload)', () => {
    const fixture = readFixture('health-report-windows.fixture.json') as { json: unknown };
    assert.doesNotThrow(() => HealthReportSubmitInput.parse(fixture.json));
    const parsed = HealthReportSubmitInput.parse(fixture.json);
    assert.strictEqual(parsed.platform, 'windows');
    assert.strictEqual(parsed.agentVersion, '1.0.4');
    assert.strictEqual(parsed.windows?.appLockerState, 'Enforced');
    assert.strictEqual(parsed.windows?.browserEnforcement, 'Active');
  });

  it('parses legacy agent fixture (pre-alignment, no canonical fields)', () => {
    const fixture = readFixture('health-report-legacy.fixture.json') as { json: unknown };
    assert.doesNotThrow(() => HealthReportSubmitInput.parse(fixture.json));
    const parsed = HealthReportSubmitInput.parse(fixture.json);
    // Legacy agents do not send platform or agentVersion — both must be undefined.
    assert.strictEqual(parsed.platform, undefined);
    assert.strictEqual(parsed.agentVersion, undefined);
    // Legacy agents send version and dnsmasqRunning — must be preserved.
    assert.strictEqual(parsed.version, '1.0.2');
    assert.strictEqual(parsed.dnsmasqRunning, false);
  });

  // ── configPosture (effective flag posture) + healthReportFailStreak ───────

  it('accepts a full linux configPosture and a windows-only posture', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        configPosture: {
          ipv6FirewallEnabled: 'true',
          sinkholeFastFail: 'true',
          captivePortalScopedPassthrough: 'false',
          rfc1918EgressMode: 'all',
          allowSetEgressEnabled: 'true',
          failureMode: 'protected',
        },
      })
    );
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-02',
        status: 'HEALTHY',
        configPosture: { outboundEgressFloorEnabled: 'false' },
      })
    );
  });

  it('strips free-form configPosture keys (allowlist only reaches storage)', () => {
    const parsed = HealthReportSubmitInput.parse({
      hostname: 'pc-01',
      status: 'HEALTHY',
      configPosture: { sinkholeFastFail: 'true', freeFormKey: 'x' },
    });
    assert.deepEqual(parsed.configPosture, { sinkholeFastFail: 'true' });
  });

  it('rejects non-string, empty, or oversized configPosture values', () => {
    assert.throws(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        configPosture: { sinkholeFastFail: true },
      })
    );
    assert.throws(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        configPosture: { failureMode: '' },
      })
    );
    assert.throws(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        configPosture: { failureMode: 'x'.repeat(33) },
      })
    );
  });

  it('accepts healthReportFailStreak and rejects negative or fractional values', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        healthReportFailStreak: 3,
      })
    );
    assert.throws(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        healthReportFailStreak: -1,
      })
    );
    assert.throws(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        healthReportFailStreak: 1.5,
      })
    );
  });

  it('still accepts payloads without configPosture (old agents)', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({ hostname: 'pc-01', status: 'HEALTHY' })
    );
  });

  // ── firefoxRegistration (Firefox managed-extension registration state) ────

  it('accepts firefoxRegistration with registered, targetCount and lastCheckedAt', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        firefoxRegistration: {
          registered: 2,
          targetCount: 3,
          lastCheckedAt: '2026-07-02T10:00:00Z',
        },
      })
    );
  });

  it('accepts firefoxRegistration without lastCheckedAt', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        firefoxRegistration: { registered: 0, targetCount: 0 },
      })
    );
  });

  it('rejects firefoxRegistration with negative or non-integer counts', () => {
    assert.throws(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        firefoxRegistration: { registered: -1, targetCount: 3 },
      })
    );
    assert.throws(() =>
      HealthReportSubmitInput.parse({
        hostname: 'pc-01',
        status: 'HEALTHY',
        firefoxRegistration: { registered: 1.5, targetCount: 3 },
      })
    );
  });

  it('still accepts payloads without firefoxRegistration (old agents)', () => {
    assert.doesNotThrow(() =>
      HealthReportSubmitInput.parse({ hostname: 'pc-01', status: 'HEALTHY' })
    );
  });
});
