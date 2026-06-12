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
});
