import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readText } from './support.mjs';

/**
 * T9 — Shared health-report schema (Zod) — cross-platform field-parity contracts.
 *
 * Both the Linux agent (common-registration.sh) and the Windows agent
 * (Common.Http.Health.ps1) must emit the canonical field names aligned to
 * HealthReportSubmitInput in @openpath/shared.  These tests read each
 * platform's source as plain text and assert on the key identifiers.
 */
describe('T9: health report cross-platform field-parity contracts', () => {
  // ── Linux ───────────────────────────────────────────────────────────────────

  test('Linux send_health_report_to_api emits canonical agentVersion field', () => {
    const src = readText('linux/lib/common-registration.sh');
    assert.ok(
      src.includes('"agentVersion"'),
      'linux/lib/common-registration.sh send_health_report_to_api must emit "agentVersion"'
    );
  });

  test('Linux send_health_report_to_api emits canonical platform field with value linux', () => {
    const src = readText('linux/lib/common-registration.sh');
    assert.ok(
      src.includes('"platform"'),
      'linux/lib/common-registration.sh send_health_report_to_api must emit "platform"'
    );
    assert.ok(
      src.includes('"linux"'),
      'linux/lib/common-registration.sh send_health_report_to_api must set platform to "linux"'
    );
  });

  test('Linux send_health_report_to_api emits canonical dnsState field', () => {
    const src = readText('linux/lib/common-registration.sh');
    assert.ok(
      src.includes('"dnsState"'),
      'linux/lib/common-registration.sh send_health_report_to_api must emit "dnsState"'
    );
  });

  test('Linux send_health_report_to_api still emits legacy dnsmasqRunning and dnsResolving', () => {
    const src = readText('linux/lib/common-registration.sh');
    assert.ok(
      src.includes('"dnsmasqRunning"'),
      'linux/lib/common-registration.sh must keep legacy "dnsmasqRunning" for deployed-agent compatibility'
    );
    assert.ok(
      src.includes('"dnsResolving"'),
      'linux/lib/common-registration.sh must keep legacy "dnsResolving" for deployed-agent compatibility'
    );
  });

  test('Linux send_health_report_to_api still emits legacy version field', () => {
    const src = readText('linux/lib/common-registration.sh');
    assert.ok(
      src.includes('"version"'),
      'linux/lib/common-registration.sh must keep legacy "version" for deployed-agent compatibility'
    );
  });

  test('Linux send_health_report_to_api emits optional firefoxRegistration from the ready marker', () => {
    const src = readText('linux/lib/common-registration.sh');
    assert.ok(
      src.includes('"firefoxRegistration"'),
      'linux/lib/common-registration.sh must emit optional "firefoxRegistration"'
    );
    assert.ok(
      src.includes('"targetCount"'),
      'linux/lib/common-registration.sh firefoxRegistration must use the canonical "targetCount" key'
    );
    assert.ok(
      src.includes('read_firefox_registration_state'),
      'linux/lib/common-registration.sh must define the ready-marker reader'
    );
  });

  // ── Windows ─────────────────────────────────────────────────────────────────

  test('Windows Send-OpenPathHealthReport emits canonical agentVersion field', () => {
    const src = readText('windows/lib/internal/Common.Http.Health.ps1');
    assert.ok(
      src.includes('agentVersion'),
      'windows/lib/internal/Common.Http.Health.ps1 Send-OpenPathHealthReport must emit agentVersion'
    );
  });

  test('Windows Send-OpenPathHealthReport emits canonical platform field with value windows', () => {
    const src = readText('windows/lib/internal/Common.Http.Health.ps1');
    assert.ok(
      src.includes('platform'),
      'windows/lib/internal/Common.Http.Health.ps1 Send-OpenPathHealthReport must emit platform'
    );
    assert.ok(
      src.includes("'windows'"),
      "windows/lib/internal/Common.Http.Health.ps1 Send-OpenPathHealthReport must set platform to 'windows'"
    );
  });

  test('Windows Send-OpenPathHealthReport emits canonical dnsState field', () => {
    const src = readText('windows/lib/internal/Common.Http.Health.ps1');
    assert.ok(
      src.includes('dnsState'),
      'windows/lib/internal/Common.Http.Health.ps1 Send-OpenPathHealthReport must emit dnsState'
    );
  });

  test('Windows Send-OpenPathHealthReport still emits legacy dnsmasqRunning and dnsResolving', () => {
    const src = readText('windows/lib/internal/Common.Http.Health.ps1');
    assert.ok(
      src.includes('dnsmasqRunning'),
      'windows/lib/internal/Common.Http.Health.ps1 must keep legacy dnsmasqRunning for deployed-agent compatibility'
    );
    assert.ok(
      src.includes('dnsResolving'),
      'windows/lib/internal/Common.Http.Health.ps1 must keep legacy dnsResolving for deployed-agent compatibility'
    );
  });

  test('Windows Send-OpenPathHealthReport still emits legacy version field', () => {
    const src = readText('windows/lib/internal/Common.Http.Health.ps1');
    assert.ok(
      src.includes('version'),
      'windows/lib/internal/Common.Http.Health.ps1 must keep legacy version field for deployed-agent compatibility'
    );
  });

  // ── Shared schema alignment ─────────────────────────────────────────────────

  test('shared schema exports HealthReportSubmitInput', () => {
    const src = readText('shared/src/schemas/index.ts');
    assert.ok(
      src.includes('HealthReportSubmitInput'),
      'shared/src/schemas/index.ts must export HealthReportSubmitInput'
    );
  });

  test('shared schema HealthReportSubmitInput uses a loose object for telemetry leniency', () => {
    const src = readText('shared/src/schemas/index.ts');
    assert.ok(
      src.includes('HealthReportSubmitInput = z.looseObject({'),
      'shared/src/schemas/index.ts HealthReportSubmitInput must use z.looseObject so unknown future agent fields do not hard-fail'
    );
  });

  test('API health-reports router imports HealthReportSubmitInput from @openpath/shared', () => {
    const src = readText('api/src/trpc/routers/health-reports.ts');
    assert.ok(
      src.includes('HealthReportSubmitInput'),
      'api/src/trpc/routers/health-reports.ts must use HealthReportSubmitInput from @openpath/shared'
    );
  });

  test('HealthStatus enum includes PROTECTED (ADR-0011 Linux protected mode)', () => {
    const src = readText('shared/src/schemas/index.ts');
    // The enum values are listed as 'PROTECTED' strings
    assert.ok(
      src.includes("'PROTECTED'"),
      "shared/src/schemas/index.ts HealthStatus enum must include 'PROTECTED'"
    );
  });

  test('health-statuses.txt contract fixture includes PROTECTED', () => {
    const src = readText('tests/contracts/health-statuses.txt');
    assert.ok(
      src.includes('PROTECTED'),
      'tests/contracts/health-statuses.txt must list PROTECTED status'
    );
  });
});
