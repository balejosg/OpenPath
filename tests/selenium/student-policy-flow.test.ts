import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  buildWindowsHttpProbeCommand,
  buildWindowsBlockedDnsCommand,
  getStudentPolicyScenarioGroup,
  StudentPolicyDriver,
  waitForFirefoxExtensionRuntimeReady,
  type StudentScenario,
} from './student-policy-flow.e2e';
import { matchesRequestDomain } from './student-policy-client';
import { openAndExpectBlocked, submitBlockedScreenRequest } from './student-policy-driver-browser';
import { getStudentPolicyCoverageProfile } from './student-policy-env';
import { getBlockedPathRulesDebug } from './student-policy-driver-runtime';
import { getStudentPolicyPhasePlan } from './student-policy-harness';
import {
  buildBaselineWhitelistHosts,
  buildDnsEvidenceMatrixArtifact,
  buildDnsEvidenceMatrixPlan,
  buildDnsDiscoverySpikeArtifact,
  buildDnsDiscoverySpikePlan,
  buildBrowserDependencyObservabilitySpikeArtifact,
  buildBrowserDependencyObservabilitySpikePlan,
  buildLinuxRuntimeDependencyApplyPlan,
  findResidualWhitelistEntries,
} from './student-policy-scenarios';

function createScenario(): StudentScenario {
  return {
    scenarioName: 'test',
    apiUrl: 'http://127.0.0.1:3201',
    auth: {
      admin: {
        email: 'admin@openpath.local',
        accessToken: 'admin-token',
        userId: 'admin-user',
      },
      teacher: {
        email: 'teacher@openpath.local',
        accessToken: 'teacher-token',
        userId: 'teacher-user',
      },
    },
    groups: {
      restricted: {
        id: 'restricted-group',
        name: 'restricted-group',
        displayName: 'Restricted Group',
      },
      alternate: {
        id: 'alternate-group',
        name: 'alternate-group',
        displayName: 'Alternate Group',
      },
    },
    classroom: {
      id: 'classroom-1',
      name: 'classroom-1',
      displayName: 'Classroom 1',
      defaultGroupId: 'restricted-group',
    },
    schedules: {
      activeRestriction: {
        id: 'schedule-1',
        classroomId: 'classroom-1',
        groupId: 'restricted-group',
        startAt: '2026-03-30T11:30:00.000Z',
        endAt: '2026-03-30T14:30:00.000Z',
      },
      futureAlternate: {
        id: 'schedule-2',
        classroomId: 'classroom-1',
        groupId: 'alternate-group',
        startAt: '2026-03-30T15:45:00.000Z',
        endAt: '2026-03-30T16:15:00.000Z',
      },
    },
    machine: {
      id: 'machine-1',
      classroomId: 'classroom-1',
      machineHostname: 'windows-student-e2e',
      reportedHostname: 'windows-student-e2e',
      machineToken: 'machine-token',
      whitelistUrl: 'http://127.0.0.1:3201/w/token/whitelist.txt',
    },
    fixtures: {
      portal: 'portal.127.0.0.1.sslip.io',
      cdnPortal: 'cdn.portal.127.0.0.1.sslip.io',
      site: 'site.127.0.0.1.sslip.io',
      apiSite: 'api.site.127.0.0.1.sslip.io',
    },
  };
}

test('assertWhitelistContains accepts Windows whitelist files with BOM and CRLF', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openpath-whitelist-'));
  const whitelistPath = path.join(tempDir, 'whitelist.txt');
  const previousWhitelistPath = process.env.OPENPATH_WHITELIST_PATH;

  fs.writeFileSync(
    whitelistPath,
    '\uFEFF## WHITELIST\r\nportal.127.0.0.1.sslip.io\r\nsite.127.0.0.1.sslip.io\r\n',
    'utf8'
  );

  process.env.OPENPATH_WHITELIST_PATH = whitelistPath;

  try {
    const driver = new StudentPolicyDriver(createScenario(), {
      diagnosticsDir: tempDir,
      headless: true,
    });

    await assert.doesNotReject(() => driver.assertWhitelistContains('portal.127.0.0.1.sslip.io'));
  } finally {
    if (previousWhitelistPath === undefined) {
      delete process.env.OPENPATH_WHITELIST_PATH;
    } else {
      process.env.OPENPATH_WHITELIST_PATH = previousWhitelistPath;
    }

    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test('buildWindowsBlockedDnsCommand treats NXDOMAIN as a blocked result instead of a command failure', () => {
  const command = buildWindowsBlockedDnsCommand('cdn.base-only.127.0.0.1.sslip.io');

  assert.match(command, /Resolve-DnsName -Name 'cdn\.base-only\.127\.0\.0\.1\.sslip\.io'/);
  assert.match(command, /-ErrorAction Stop/);
  assert.match(command, /DNS name does not exist/);
  assert.match(command, /DNS_ERROR_RCODE_NAME_ERROR/);
  assert.match(command, /\bthrow\b/);
  assert.doesNotMatch(command, /catch \{ exit 0 \}/);
});

test('buildWindowsHttpProbeCommand uses a Windows-safe HTTP probe without POSIX redirection', () => {
  const command = buildWindowsHttpProbeCommand(
    'http://exempted-domain.127.0.0.1.sslip.io:18082/ok'
  );

  assert.match(command, /^powershell -NoLogo -EncodedCommand /);
  assert.doesNotMatch(command, />\/dev\/null/);
});

test('buildWindowsHttpProbeCommand avoids exposing raw URLs to cmd quoting and expansion', () => {
  const url = "http://exempted-domain.127.0.0.1.sslip.io:18082/o'k?token=%TEMP%";
  const command = buildWindowsHttpProbeCommand(url);

  assert.match(command, /^powershell -NoLogo -EncodedCommand /);
  assert.doesNotMatch(command, /%TEMP%/);
  assert.doesNotMatch(command, /o'k/);

  const encodedCommand = command.replace(/^powershell -NoLogo -EncodedCommand /, '');
  const decodedCommand = Buffer.from(encodedCommand, 'base64').toString('utf16le');

  assert.match(
    decodedCommand,
    /Invoke-WebRequest -Uri 'http:\/\/exempted-domain\.127\.0\.0\.1\.sslip\.io:18082\/o''k\?token=%TEMP%'/
  );
  assert.match(decodedCommand, /-UseBasicParsing/);
  assert.match(decodedCommand, /\| Out-Null/);
});

test('buildWindowsHttpProbeCommand can direct-connect to sslip fixture IP while preserving Host', () => {
  const command = buildWindowsHttpProbeCommand(
    'http://exempted-domain.127.0.0.1.sslip.io:18082/ok',
    { useFixtureIp: true }
  );

  const encodedCommand = command.replace(/^powershell -NoLogo -EncodedCommand /, '');
  const decodedCommand = Buffer.from(encodedCommand, 'base64').toString('utf16le');

  assert.match(decodedCommand, /Invoke-WebRequest -Uri 'http:\/\/127\.0\.0\.1:18082\/ok'/);
  assert.match(
    decodedCommand,
    /-Headers @\{ Host = 'exempted-domain\.127\.0\.0\.1\.sslip\.io:18082' \}/
  );
});

test('matchesRequestDomain accepts API-normalized parent domains', () => {
  assert.equal(
    matchesRequestDomain('sslip.io', 'request-domain-ed8c931d.127.0.0.1.sslip.io'),
    true
  );
  assert.equal(matchesRequestDomain('Example.COM.', 'www.example.com'), true);
  assert.equal(matchesRequestDomain('example.com', 'notexample.com'), false);
});

test('findResidualWhitelistEntries detects request lifecycle residue before temporary exemptions', () => {
  const residual = findResidualWhitelistEntries(
    [
      'portal.127.0.0.1.sslip.io',
      'request-domain-ed8c931d.127.0.0.1.sslip.io',
      'site.127.0.0.1.sslip.io',
    ].join('\n'),
    ['request-domain-ed8c931d.127.0.0.1.sslip.io', 'duplicate-domain-ed8c931d.127.0.0.1.sslip.io']
  );

  assert.deepEqual(residual, ['request-domain-ed8c931d.127.0.0.1.sslip.io']);
});

test('findResidualWhitelistEntries treats API-normalized parent rules as request residue', () => {
  const residual = findResidualWhitelistEntries('request-domain-ed8c931d.127.0.0.1.sslip.io\n', [
    'api.request-domain-ed8c931d.127.0.0.1.sslip.io',
  ]);

  assert.deepEqual(residual, ['request-domain-ed8c931d.127.0.0.1.sslip.io']);
});

test('student policy coverage plan keeps full SSE coverage and narrows fallback to propagation proof', () => {
  assert.deepStrictEqual(
    getStudentPolicyPhasePlan('sse', 'full').map(({ name, suite, useBrowser }) => ({
      name,
      suite,
      useBrowser,
    })),
    [
      { name: 'phase-one', suite: 'matrix', useBrowser: true },
      { name: 'phase-two', suite: 'matrix-phase-two', useBrowser: false },
    ]
  );

  assert.deepStrictEqual(
    getStudentPolicyPhasePlan('fallback', 'fallback-propagation').map(
      ({ name, suite, useBrowser }) => ({
        name,
        suite,
        useBrowser,
      })
    ),
    [{ name: 'fallback-propagation', suite: 'fallback-propagation', useBrowser: true }]
  );
});

test('student policy coverage profile accepts the DNS discovery spike without changing the default', () => {
  const original = process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;

  try {
    delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    assert.equal(getStudentPolicyCoverageProfile(), 'full');

    process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = 'dns-discovery-spike';
    assert.equal(getStudentPolicyCoverageProfile(), 'dns-discovery-spike');
  } finally {
    if (original === undefined) {
      delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    } else {
      process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = original;
    }
  }
});

test('student policy coverage profile accepts the DNS evidence matrix without changing the default', () => {
  const original = process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;

  try {
    delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    assert.equal(getStudentPolicyCoverageProfile(), 'full');

    process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = 'dns-evidence-matrix';
    assert.equal(getStudentPolicyCoverageProfile(), 'dns-evidence-matrix');
  } finally {
    if (original === undefined) {
      delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    } else {
      process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = original;
    }
  }
});

test('student policy coverage profile accepts the controlled DNS evidence matrix v2', () => {
  const original = process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;

  try {
    delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    assert.equal(getStudentPolicyCoverageProfile(), 'full');

    process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = 'dns-evidence-matrix-v2';
    assert.equal(getStudentPolicyCoverageProfile(), 'dns-evidence-matrix-v2');
  } finally {
    if (original === undefined) {
      delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    } else {
      process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = original;
    }
  }
});

test('student policy coverage profile accepts the browser dependency observability spike', () => {
  const original = process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;

  try {
    delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    assert.equal(getStudentPolicyCoverageProfile(), 'full');

    process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = 'browser-dependency-observability-spike';
    assert.equal(getStudentPolicyCoverageProfile(), 'browser-dependency-observability-spike');
  } finally {
    if (original === undefined) {
      delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    } else {
      process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = original;
    }
  }
});

test('student policy coverage profile accepts linux runtime dependency apply', () => {
  const original = process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;

  try {
    delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    assert.equal(getStudentPolicyCoverageProfile(), 'full');

    process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = 'linux-runtime-dependency-apply';
    assert.equal(getStudentPolicyCoverageProfile(), 'linux-runtime-dependency-apply');
  } finally {
    if (original === undefined) {
      delete process.env.OPENPATH_STUDENT_COVERAGE_PROFILE;
    } else {
      process.env.OPENPATH_STUDENT_COVERAGE_PROFILE = original;
    }
  }
});

test('DNS discovery spike plans a browser-only phase outside the full matrix', () => {
  assert.deepEqual(
    getStudentPolicyPhasePlan('sse', 'dns-discovery-spike').map(({ name, suite, useBrowser }) => ({
      name,
      suite,
      useBrowser,
    })),
    [{ name: 'dns-discovery-spike', suite: 'dns-discovery-spike', useBrowser: true }]
  );
});

test('DNS evidence matrix plans the full browser phase sequence outside the full matrix', () => {
  assert.deepEqual(
    getStudentPolicyPhasePlan('sse', 'dns-evidence-matrix').map(({ name, suite, useBrowser }) => ({
      name,
      suite,
      useBrowser,
    })),
    [{ name: 'dns-evidence-matrix', suite: 'dns-evidence-matrix', useBrowser: true }]
  );
});

test('DNS evidence matrix v2 plans a browser-only diagnostic phase outside the full matrix', () => {
  assert.deepEqual(
    getStudentPolicyPhasePlan('sse', 'dns-evidence-matrix-v2').map(
      ({ name, suite, useBrowser }) => ({
        name,
        suite,
        useBrowser,
      })
    ),
    [{ name: 'dns-evidence-matrix-v2', suite: 'dns-evidence-matrix-v2', useBrowser: true }]
  );
});

test('browser dependency observability spike plans a browser-only diagnostic phase', () => {
  assert.deepEqual(
    getStudentPolicyPhasePlan('sse', 'browser-dependency-observability-spike').map(
      ({ name, suite, useBrowser }) => ({
        name,
        suite,
        useBrowser,
      })
    ),
    [
      {
        name: 'browser-dependency-observability-spike',
        suite: 'browser-dependency-observability-spike',
        useBrowser: true,
      },
    ]
  );
});

test('linux runtime dependency apply plans a browser-only diagnostic phase', () => {
  assert.deepEqual(
    getStudentPolicyPhasePlan('sse', 'linux-runtime-dependency-apply').map(
      ({ name, suite, useBrowser }) => ({
        name,
        suite,
        useBrowser,
      })
    ),
    [
      {
        name: 'linux-runtime-dependency-apply',
        suite: 'linux-runtime-dependency-apply',
        useBrowser: true,
      },
    ]
  );
});

test('DNS discovery spike uses site origin and unpreseeded typed dependency hosts', () => {
  const scenario = createScenario();
  const plan = buildDnsDiscoverySpikePlan(scenario);

  assert.equal(plan.origin.host, 'site.127.0.0.1.sslip.io');
  assert.equal(new URL(plan.origin.url).hostname, plan.origin.host);

  assert.deepEqual(
    plan.dependencies.map(({ type, host }) => [
      type,
      host.replace(/\.127\.0\.0\.1\.sslip\.io$/, ''),
    ]),
    [
      ['fetch', 'api.dns-discovery-fetch-assroom1'],
      ['xhr', 'api.dns-discovery-xhr-assroom1'],
      ['script', 'cdn.dns-discovery-script-assroom1'],
      ['image', 'image.dns-discovery-image-assroom1'],
      ['css', 'style.dns-discovery-css-assroom1'],
      ['font', 'font.dns-discovery-font-assroom1'],
    ]
  );

  const preseededHosts = new Set([
    scenario.fixtures.portal,
    scenario.fixtures.cdnPortal,
    scenario.fixtures.site,
    scenario.fixtures.apiSite,
  ]);
  for (const dependency of plan.dependencies) {
    assert.equal(preseededHosts.has(dependency.host), false, `${dependency.host} is preseeded`);
  }
});

test('DNS evidence matrix uses approved anchors and unpreseeded typed dependency hosts', () => {
  const scenario = createScenario();
  const plan = buildDnsEvidenceMatrixPlan(scenario);

  assert.equal(plan.origin.host, 'site.127.0.0.1.sslip.io');
  assert.equal(plan.alternateOrigin.host, 'portal.127.0.0.1.sslip.io');
  assert.equal(new URL(plan.origin.url).hostname, plan.origin.host);
  assert.equal(new URL(plan.alternateOrigin.url).hostname, plan.alternateOrigin.host);

  assert.deepEqual(
    plan.dependencies.map(({ type, host }) => [
      type,
      host.replace(/\.127\.0\.0\.1\.sslip\.io$/, ''),
    ]),
    [
      ['fetch', 'api.dns-matrix-fetch-assroom1'],
      ['xhr', 'api.dns-matrix-xhr-assroom1'],
      ['script', 'cdn.dns-matrix-script-assroom1'],
      ['image', 'image.dns-matrix-image-assroom1'],
      ['css', 'style.dns-matrix-css-assroom1'],
      ['font', 'font.dns-matrix-font-assroom1'],
    ]
  );

  const preseededHosts = new Set([
    scenario.fixtures.portal,
    scenario.fixtures.cdnPortal,
    scenario.fixtures.site,
    scenario.fixtures.apiSite,
  ]);
  for (const dependency of plan.dependencies) {
    assert.equal(preseededHosts.has(dependency.host), false, `${dependency.host} is preseeded`);
  }
});

test('browser dependency observability spike uses approved anchors and unpreseeded dependencies', () => {
  const scenario = createScenario();
  const plan = buildBrowserDependencyObservabilitySpikePlan(scenario);

  assert.equal(plan.origin.host, 'site.127.0.0.1.sslip.io');
  assert.equal(plan.alternateOrigin.host, 'portal.127.0.0.1.sslip.io');
  assert.deepEqual(
    plan.dependencies.map(({ type, host }) => [
      type,
      host.replace(/\.127\.0\.0\.1\.sslip\.io$/, ''),
    ]),
    [
      ['fetch', 'api.browser-dependency-fetch-assroom1'],
      ['xhr', 'api.browser-dependency-xhr-assroom1'],
      ['script', 'cdn.browser-dependency-script-assroom1'],
      ['image', 'image.browser-dependency-image-assroom1'],
      ['css', 'style.browser-dependency-css-assroom1'],
      ['font', 'font.browser-dependency-font-assroom1'],
    ]
  );
});

test('linux runtime dependency route applies local overlay without remote whitelist mutation', () => {
  const scenario = createScenario();
  const plan = buildLinuxRuntimeDependencyApplyPlan(scenario);

  assert.equal(plan.profile, 'linux-runtime-dependency-apply');
  assert.equal(plan.dependencies.length > 0, true);
  assert.equal(plan.origin.host.includes('site.'), true);
  assert.equal(plan.expectedRemoteWhitelistMutation, false);
  assert.equal(plan.expectedLocalRuntimeDependencyApply, true);
  assert.deepEqual(
    plan.dependencies.map(({ type, host }) => [
      type,
      host.replace(/\.127\.0\.0\.1\.sslip\.io$/, ''),
    ]),
    [['fetch', 'api.linux-runtime-dependency-fetch-assroom1']]
  );
});

test('browser dependency observability spike artifact records decision evidence', () => {
  const scenario = createScenario();
  const plan = buildBrowserDependencyObservabilitySpikePlan(scenario);
  const artifact = buildBrowserDependencyObservabilitySpikeArtifact({
    plan,
    success: true,
    phases: [
      {
        name: 'dependency-observation-blocked',
        runtimeEvents: [
          {
            phase: 'dependency-observation-blocked',
            source: 'webRequest.onBeforeRequest',
            hostname: plan.dependencies[0]?.host,
          },
        ],
        nativeChecks: [{ host: plan.dependencies[0]?.host, inWhitelist: false }],
        outcomes: { fetch: { status: 'blocked', durationMs: 12 } },
      },
      {
        name: 'dependency-observation-allowed',
        runtimeEvents: [
          {
            phase: 'dependency-observation-allowed',
            source: 'webRequest.onBeforeRequest',
            hostname: plan.dependencies[0]?.host,
          },
        ],
        nativeChecks: [{ host: plan.dependencies[0]?.host, inWhitelist: true }],
        outcomes: { fetch: { status: 'ok', durationMs: 8 } },
      },
    ],
    remoteRulesBefore: 'site.127.0.0.1.sslip.io\n',
    remoteRulesAfterExplicitApply: `${plan.dependencies[0]?.host}\n`,
    explicitRulesApplied: plan.dependencies.map((dependency) => dependency.host),
    decision: 'runtimeRouteViable',
    writtenAt: '2026-05-11T00:00:00.000Z',
  });

  assert.equal(artifact.profile, 'browser-dependency-observability-spike');
  assert.equal(artifact.resultPath, 'browser-dependency-observability-spike-result.json');
  assert.equal(artifact.decision, 'runtimeRouteViable');
  assert.equal(artifact.phases[0]?.name, 'dependency-observation-blocked');
  assert.equal(artifact.noAutomaticRuleCreation, true);
  assert.equal(artifact.explicitRulesApplied.length, plan.dependencies.length);
});

test('DNS discovery spike browser artifact records cold and warm results by dependency type', () => {
  const scenario = createScenario();
  const plan = buildDnsDiscoverySpikePlan(scenario);
  const artifact = buildDnsDiscoverySpikeArtifact({
    plan,
    success: true,
    hitLogClear: {
      status: 'not-configured',
      phase: 'warm',
      envName: 'OPENPATH_STUDENT_DNS_DISCOVERY_HITLOG_CLEAR_COMMAND',
    },
    phaseResults: {
      cold: {
        fetch: { status: 'blocked', durationMs: 12 },
      },
      warm: {
        fetch: { status: 'ok', durationMs: 8 },
      },
    },
    writtenAt: '2026-05-11T00:00:00.000Z',
  });

  assert.equal(artifact.profile, 'dns-discovery-spike');
  assert.equal(artifact.origin.host, 'site.127.0.0.1.sslip.io');
  assert.equal(artifact.success, true);
  assert.equal(artifact.dependencyResults.fetch.host, plan.dependencies[0]?.host);
  assert.equal(artifact.dependencyResults.fetch.cold.status, 'blocked');
  assert.equal(artifact.dependencyResults.fetch.warm.status, 'ok');
  assert.equal(artifact.dependencyResults.css.host.startsWith('style.'), true);
  assert.equal(artifact.hitLogClear.status, 'not-configured');
});

test('DNS evidence matrix browser artifact records every browser phase by dependency type', () => {
  const scenario = createScenario();
  const plan = buildDnsEvidenceMatrixPlan(scenario);
  const artifact = buildDnsEvidenceMatrixArtifact({
    plan,
    success: true,
    hooks: [
      {
        status: 'ok',
        phase: 'browser-warm-ajax',
        action: 'clear',
        envName: 'OPENPATH_STUDENT_DNS_EVIDENCE_MATRIX_CLEAR_COMMAND',
      },
    ],
    phaseResults: {
      'browser-cold-navigation': {
        fetch: { status: 'blocked', durationMs: 12 },
      },
      'browser-warm-ajax': {
        fetch: { status: 'blocked', durationMs: 8 },
      },
      'browser-multi-anchor': {
        fetch: { status: 'blocked', durationMs: 9 },
      },
      'sinkhole-capture': {
        fetch: { status: 'ok', durationMs: 6 },
      },
    },
    writtenAt: '2026-05-11T00:00:00.000Z',
  });

  assert.equal(artifact.profile, 'dns-evidence-matrix');
  assert.equal(artifact.origin.host, 'site.127.0.0.1.sslip.io');
  assert.equal(artifact.alternateOrigin.host, 'portal.127.0.0.1.sslip.io');
  assert.equal(artifact.success, true);
  assert.equal(artifact.dependencyResults.fetch.host, plan.dependencies[0]?.host);
  assert.equal(artifact.dependencyResults.fetch['browser-cold-navigation'].status, 'blocked');
  assert.equal(artifact.dependencyResults.fetch['sinkhole-capture'].status, 'ok');
  assert.equal(artifact.hooks[0]?.status, 'ok');
});

test('student policy scenario group defaults to full and accepts narrow groups', () => {
  const original = process.env.OPENPATH_STUDENT_SCENARIO_GROUP;

  try {
    delete process.env.OPENPATH_STUDENT_SCENARIO_GROUP;
    assert.strictEqual(getStudentPolicyScenarioGroup(), 'full');

    for (const group of ['request-lifecycle', 'path-blocking', 'exemptions', 'full']) {
      process.env.OPENPATH_STUDENT_SCENARIO_GROUP = group;
      assert.strictEqual(getStudentPolicyScenarioGroup(), group);
    }

    process.env.OPENPATH_STUDENT_SCENARIO_GROUP = 'fast';
    assert.throws(() => getStudentPolicyScenarioGroup(), /OPENPATH_STUDENT_SCENARIO_GROUP/);
  } finally {
    if (original === undefined) {
      delete process.env.OPENPATH_STUDENT_SCENARIO_GROUP;
    } else {
      process.env.OPENPATH_STUDENT_SCENARIO_GROUP = original;
    }
  }
});

test('StudentPolicyDriver refreshes blocked subdomain rules through runtime message', async () => {
  const executedScripts: string[] = [];
  const driver = new StudentPolicyDriver(createScenario(), {
    diagnosticsDir: os.tmpdir(),
    headless: true,
  });
  (driver as unknown as { driver: unknown; extensionUuid: string }).driver = {
    async get(_url: string) {},
    async executeScript() {
      return true;
    },
    async executeAsyncScript(script: string) {
      executedScripts.push(script);
      return { ok: true, value: { success: true } };
    },
    async wait(condition: (driver: unknown) => Promise<boolean>) {
      return condition(this);
    },
  };
  (driver as unknown as { extensionUuid: string }).extensionUuid = 'extension-id';

  await driver.refreshBlockedSubdomainRules();

  assert.match(executedScripts.join('\n'), /refreshBlockedSubdomainRules/);
});

test('student policy scenario groups select narrow Selenium suites without weakening full coverage', () => {
  assert.deepStrictEqual(
    getStudentPolicyPhasePlan('sse', 'full', 'full').map(({ suite }) => suite),
    ['matrix', 'matrix-phase-two']
  );
  assert.deepStrictEqual(
    getStudentPolicyPhasePlan('sse', 'full', 'path-blocking').map(({ suite }) => suite),
    ['path-blocking']
  );
  assert.deepStrictEqual(
    getStudentPolicyPhasePlan('sse', 'full', 'request-lifecycle').map(({ suite }) => suite),
    ['request-lifecycle']
  );
  assert.deepStrictEqual(
    getStudentPolicyPhasePlan('sse', 'full', 'exemptions').map(({ suite }) => suite),
    ['exemptions']
  );
});

test('student policy baseline whitelists the native API hostname when it is policy-routable', () => {
  const scenario = createScenario();
  scenario.apiUrl = 'http://host.docker.internal:3101';

  const targets = {
    hosts: {
      baseOnly: 'base-only.127.0.0.1.sslip.io',
      alternateOnly: 'alternate-only.127.0.0.1.sslip.io',
    },
  };

  const baseline = buildBaselineWhitelistHosts(scenario, targets as never);

  assert.ok(baseline.restricted.includes('host.docker.internal'));
  assert.ok(baseline.alternate.includes('host.docker.internal'));
});

test('student policy baseline ignores literal API addresses that cannot be DNS whitelist rules', () => {
  const scenario = createScenario();
  scenario.apiUrl = 'http://127.0.0.1:3201';

  const targets = {
    hosts: {
      baseOnly: 'base-only.127.0.0.1.sslip.io',
      alternateOnly: 'alternate-only.127.0.0.1.sslip.io',
    },
  };

  const baseline = buildBaselineWhitelistHosts(scenario, targets as never);

  assert.ok(!baseline.restricted.includes('127.0.0.1'));
  assert.ok(!baseline.alternate.includes('127.0.0.1'));
});

test('openAndExpectBlocked treats navigation timeout as blocked navigation', async () => {
  const timeoutError = new Error('Navigation timed out after 30000 ms');
  timeoutError.name = 'TimeoutError';

  const state = {
    getDriver() {
      return {
        async get() {
          throw timeoutError;
        },
      };
    },
  };

  await assert.doesNotReject(() =>
    openAndExpectBlocked(state as never, {
      url: 'http://blocked.example.test/',
    })
  );
});

test('submitBlockedScreenRequest fills the blocked page request form and waits for success status', async () => {
  const events: string[] = [];
  const elements = new Map([
    [
      '#request-reason',
      {
        async clear() {
          events.push('clear');
        },
        async sendKeys(value: string) {
          events.push(`reason:${value}`);
        },
      },
    ],
    [
      '#submit-unblock-request',
      {
        async click() {
          events.push('click');
        },
      },
    ],
    [
      '#request-status',
      {
        async getText() {
          return 'Solicitud enviada. Quedara pendiente hasta que la revisen.';
        },
      },
    ],
  ]);

  const state = {
    getDriver() {
      return {
        async findElement(locator: { value: string }) {
          const element = elements.get(locator.value);
          assert.ok(element, `Missing fake element for ${locator.value}`);
          return element;
        },
        async wait(condition: (driver: unknown) => Promise<boolean>) {
          const result = await condition(this);
          assert.equal(result, true);
          return result;
        },
      };
    },
  };

  const statusText = await submitBlockedScreenRequest(state as never, {
    reason: 'Necesario para una actividad de clase',
  });

  assert.deepEqual(events, ['clear', 'reason:Necesario para una actividad de clase', 'click']);
  assert.match(statusText, /Solicitud enviada/);
});

test('submitBlockedScreenRequest retries once when Firefox swaps the blocked page document', async () => {
  const events: string[] = [];
  let waitAttempts = 0;
  const elements = new Map([
    [
      '#request-reason',
      {
        async clear() {
          events.push('clear');
        },
        async sendKeys(value: string) {
          events.push(`reason:${value}`);
        },
      },
    ],
    [
      '#submit-unblock-request',
      {
        async click() {
          events.push('click');
        },
      },
    ],
    [
      '#request-status',
      {
        async getText() {
          return waitAttempts > 1
            ? 'Solicitud enviada. Quedara pendiente hasta que la revisen.'
            : '';
        },
      },
    ],
  ]);

  const state = {
    getDriver() {
      return {
        async findElement(locator: { value: string }) {
          const element = elements.get(locator.value);
          assert.ok(element, `Missing fake element for ${locator.value}`);
          return element;
        },
        async getCurrentUrl() {
          return 'moz-extension://extension-id/blocked/blocked.html?domain=blocked.test';
        },
        async getTitle() {
          return 'Sitio bloqueado';
        },
        async executeScript(script: string, element?: unknown) {
          if (element === elements.get('#request-status')) {
            return waitAttempts > 1
              ? 'Solicitud enviada. Quedara pendiente hasta que la revisen.'
              : '';
          }

          if (script.includes('__openpathBlockedPageSubmitProbe')) {
            return { installed: false };
          }

          if (script.includes('document.readyState')) {
            return {
              readyState: 'complete',
              reasonValueLength: 0,
              requestStatusTextContent: '',
              submitDisabled: false,
            };
          }

          return '';
        },
        async wait(condition: (driver: unknown) => Promise<boolean>, timeoutMs: number) {
          waitAttempts += 1;
          const result = await condition(this);
          if (waitAttempts === 1) {
            assert.equal(result, false);
            throw new Error(`Wait timed out after ${timeoutMs.toString()}ms`);
          }

          assert.equal(result, true);
          return result;
        },
      };
    },
  };

  const statusText = await submitBlockedScreenRequest(state as never, {
    reason: 'Necesario para una actividad de clase',
    timeoutMs: 123,
  });

  assert.deepEqual(events, [
    'clear',
    'reason:Necesario para una actividad de clase',
    'click',
    'clear',
    'reason:Necesario para una actividad de clase',
    'click',
  ]);
  assert.match(statusText, /Solicitud enviada/);
});

test('submitBlockedScreenRequest includes blocked page status when success wait times out', async () => {
  const elements = new Map([
    [
      '#request-reason',
      {
        async clear() {},
        async sendKeys() {},
      },
    ],
    [
      '#submit-unblock-request',
      {
        async click() {},
      },
    ],
    [
      '#request-status',
      {
        async getText() {
          return 'No se pudo enviar la solicitud. runtime disconnected';
        },
      },
    ],
  ]);

  const state = {
    getDriver() {
      return {
        async findElement(locator: { value: string }) {
          const element = elements.get(locator.value);
          assert.ok(element, `Missing fake element for ${locator.value}`);
          return element;
        },
        async getCurrentUrl() {
          return 'moz-extension://extension-id/blocked/blocked.html?domain=blocked.test';
        },
        async getTitle() {
          return 'Sitio bloqueado';
        },
        async executeScript(script: string) {
          if (script.includes('__openpathBlockedPageSubmitProbe')) {
            return {
              documentId: 'blocked-page-doc-1',
              browserRuntimeAvailable: true,
              chromeRuntimeAvailable: true,
              events: [
                {
                  type: 'probe-installed',
                  state: {
                    reasonValueLength: 38,
                    requestStatusTextContent: '',
                    submitDisabled: false,
                  },
                },
              ],
              currentState: {
                reasonValueLength: 0,
                requestStatusTextContent: '',
                submitDisabled: false,
              },
            };
          }

          if (script.includes('document.readyState')) {
            return {
              bodyText: 'Este sitio esta bloqueado por ahora Solicitar desbloqueo',
              readyState: 'complete',
              reasonValueLength: 38,
              requestStatusClass: 'feedback request-feedback',
              requestStatusTextContent: '',
              submitDisabled: false,
            };
          }

          return '';
        },
        async wait(condition: (driver: unknown) => Promise<boolean>, timeoutMs: number) {
          const result = await condition(this);
          assert.equal(result, false);
          throw new Error(`Wait timed out after ${timeoutMs.toString()}ms`);
        },
      };
    },
  };

  await assert.rejects(
    () =>
      submitBlockedScreenRequest(state as never, {
        reason: 'Necesario para una actividad de clase',
        timeoutMs: 123,
      }),
    (error) => {
      assert.ok(error instanceof Error);
      assert.match(error.message, /Wait timed out after 123ms/);
      assert.match(error.message, /latest #request-status: No se pudo enviar la solicitud/);
      assert.match(error.message, /currentUrl: moz-extension:\/\/extension-id\/blocked/);
      assert.match(error.message, /title: Sitio bloqueado/);
      assert.match(error.message, /blocked page DOM:/);
      assert.match(error.message, /blocked page submit diagnostics:/);
      assert.match(error.message, /"readyState":"complete"/);
      assert.match(error.message, /"requestStatusTextContent":""/);
      assert.match(error.message, /"submitDisabled":false/);
      assert.match(error.message, /"documentId":"blocked-page-doc-1"/);
      assert.match(error.message, /"browserRuntimeAvailable":true/);
      assert.match(error.message, /"events":\[/);
      return true;
    }
  );
});

test('submitBlockedScreenRequest reads request status textContent when WebDriver getText is empty', async () => {
  const events: string[] = [];
  const elements = new Map([
    [
      '#request-reason',
      {
        async clear() {
          events.push('clear');
        },
        async sendKeys(value: string) {
          events.push(`reason:${value}`);
        },
      },
    ],
    [
      '#submit-unblock-request',
      {
        async click() {
          events.push('click');
        },
      },
    ],
    [
      '#request-status',
      {
        async getText() {
          return '';
        },
      },
    ],
  ]);

  const state = {
    getDriver() {
      return {
        async findElement(locator: { value: string }) {
          const element = elements.get(locator.value);
          assert.ok(element, `Missing fake element for ${locator.value}`);
          return element;
        },
        async executeScript(script: string, element: unknown) {
          if (script.includes('__openpathBlockedPageSubmitProbe')) {
            return {
              documentId: 'blocked-page-doc-1',
              browserRuntimeAvailable: true,
              chromeRuntimeAvailable: true,
              events: [{ type: 'probe-installed' }],
            };
          }

          assert.match(script, /textContent/);
          assert.equal(element, elements.get('#request-status'));
          return 'Solicitud enviada. Quedara pendiente hasta que la revisen.';
        },
        async getCurrentUrl() {
          return 'moz-extension://extension-id/blocked/blocked.html?domain=blocked.test';
        },
        async getTitle() {
          return 'Sitio bloqueado';
        },
        async wait(condition: (driver: unknown) => Promise<boolean>) {
          const result = await condition(this);
          assert.equal(result, true);
          return result;
        },
      };
    },
  };

  const statusText = await submitBlockedScreenRequest(state as never, {
    reason: 'Necesario para una actividad de clase',
  });

  assert.deepEqual(events, ['clear', 'reason:Necesario para una actividad de clase', 'click']);
  assert.match(statusText, /Solicitud enviada/);
});

test('submitBlockedScreenRequest keeps polling when the blocked page status element is stale', async () => {
  let statusReads = 0;
  const events: string[] = [];
  const elements = new Map([
    [
      '#request-reason',
      {
        async clear() {
          events.push('clear');
        },
        async sendKeys(value: string) {
          events.push(`reason:${value}`);
        },
      },
    ],
    [
      '#submit-unblock-request',
      {
        async click() {
          events.push('click');
        },
      },
    ],
    [
      '#request-status',
      {
        async getText() {
          statusReads += 1;
          if (statusReads === 1) {
            throw new Error(
              'The element with the reference stale-id is stale; either its node document is not the active document, or it is no longer connected to the DOM'
            );
          }
          return 'Solicitud enviada. Quedara pendiente hasta que la revisen.';
        },
      },
    ],
  ]);

  const state = {
    getDriver() {
      return {
        async findElement(locator: { value: string }) {
          const element = elements.get(locator.value);
          assert.ok(element, `Missing fake element for ${locator.value}`);
          return element;
        },
        async getCurrentUrl() {
          return 'moz-extension://extension-id/blocked/blocked.html?domain=blocked.test';
        },
        async getTitle() {
          return 'Sitio bloqueado';
        },
        async wait(condition: (driver: unknown) => Promise<boolean>) {
          const firstResult = await condition(this);
          assert.equal(firstResult, false);
          const secondResult = await condition(this);
          assert.equal(secondResult, true);
          return secondResult;
        },
      };
    },
  };

  const statusText = await submitBlockedScreenRequest(state as never, {
    reason: 'Necesario para una actividad de clase',
  });

  assert.deepEqual(events, ['clear', 'reason:Necesario para una actividad de clase', 'click']);
  assert.equal(statusReads, 2);
  assert.match(statusText, /Solicitud enviada/);
});

test('StudentPolicyDriver submits requests after blocked-page navigation timeout with the requested timeout', async () => {
  const timeoutError = new Error('Navigation timed out after 8000 ms');
  timeoutError.name = 'TimeoutError';
  const waits: number[] = [];
  const events: string[] = [];
  const elements = new Map([
    [
      '#request-reason',
      {
        async clear() {
          events.push('clear');
        },
        async sendKeys(value: string) {
          events.push(`reason:${value}`);
        },
      },
    ],
    [
      '#submit-unblock-request',
      {
        async click() {
          events.push('click');
        },
      },
    ],
    [
      '#request-status',
      {
        async getText() {
          return 'Solicitud enviada. Quedara pendiente hasta que la revisen.';
        },
      },
    ],
  ]);
  const fakeWebDriver = {
    async get() {
      throw timeoutError;
    },
    async getCurrentUrl() {
      return 'moz-extension://extension-id/blocked/blocked.html?url=http%3A%2F%2Fblocked.test';
    },
    async getTitle() {
      return 'Blocked Page';
    },
    async findElement(locator: { value: string }) {
      const element = elements.get(locator.value);
      assert.ok(element, `Missing fake element for ${locator.value}`);
      return element;
    },
    async wait(condition: (driver: unknown) => Promise<boolean>, timeoutMs: number) {
      waits.push(timeoutMs);
      const result = await condition(this);
      assert.equal(result, true);
      return result;
    },
  };
  const driver = new StudentPolicyDriver(createScenario(), {
    diagnosticsDir: os.tmpdir(),
    headless: true,
  });
  (driver as unknown as { driver: unknown }).driver = fakeWebDriver;

  const statusText = await driver.openBlockedScreenAndSubmitRequest('http://blocked.test/', {
    reason: 'Needed for class',
    timeoutMs: 30_000,
  });

  assert.match(statusText, /Solicitud enviada/);
  assert.deepEqual(events, ['clear', 'reason:Needed for class', 'click']);
  assert.deepEqual(waits, [30_000, 30_000]);
});

test('StudentPolicyDriver opens the extension blocked page when Firefox keeps the previous page after timeout', async () => {
  const timeoutError = new Error('Navigation timed out after 8000 ms');
  timeoutError.name = 'TimeoutError';
  const navigations: string[] = [];
  const waits: number[] = [];
  let currentUrl = 'http://site.127.0.0.1.sslip.io:18081/ok';
  let title = 'OpenPath Site Fixture';
  const elements = new Map([
    [
      '#request-reason',
      {
        async clear() {},
        async sendKeys() {},
      },
    ],
    [
      '#submit-unblock-request',
      {
        async click() {},
      },
    ],
    [
      '#request-status',
      {
        async getText() {
          return 'Solicitud enviada. Quedara pendiente hasta que la revisen.';
        },
      },
    ],
  ]);
  const fakeWebDriver = {
    async get(url: string) {
      navigations.push(url);
      if (navigations.length === 1) {
        throw timeoutError;
      }
      currentUrl = url;
      title = 'Sitio bloqueado';
    },
    async getCurrentUrl() {
      return currentUrl;
    },
    async getTitle() {
      return title;
    },
    async findElement(locator: { value: string }) {
      const element = elements.get(locator.value);
      assert.ok(element, `Missing fake element for ${locator.value}`);
      return element;
    },
    async wait(condition: (driver: unknown) => Promise<boolean>, timeoutMs: number) {
      waits.push(timeoutMs);
      const result = await condition(this);
      if (result !== true) {
        throw new Error(`Wait timed out after ${timeoutMs.toString()}ms`);
      }
      return result;
    },
  };
  const driver = new StudentPolicyDriver(createScenario(), {
    diagnosticsDir: os.tmpdir(),
    headless: true,
  });
  (driver as unknown as { driver: unknown; extensionUuid: string }).driver = fakeWebDriver;
  (driver as unknown as { extensionUuid: string }).extensionUuid = 'extension-id';

  await driver.openBlockedScreenAndSubmitRequest('http://blocked.test/lesson', {
    reason: 'Needed for class',
    timeoutMs: 250,
  });

  assert.equal(navigations[0], 'http://blocked.test/lesson');
  assert.match(navigations[1] ?? '', /^moz-extension:\/\/extension-id\/blocked\/blocked\.html\?/);
  const fallbackUrl = new URL(navigations[1] ?? '');
  assert.equal(fallbackUrl.searchParams.get('domain'), 'blocked.test');
  assert.equal(fallbackUrl.searchParams.get('origin'), 'http://blocked.test/lesson');
  assert.equal(fallbackUrl.searchParams.get('error'), 'blockedByPolicy');
  assert.deepEqual(waits, [250, 250, 250]);
});

test('StudentPolicyDriver waits for blocked page when fallback navigation also times out', async () => {
  const timeoutError = new Error('Navigation timed out after 8000 ms');
  timeoutError.name = 'TimeoutError';
  const navigations: string[] = [];
  const waits: number[] = [];
  let currentUrl = 'http://site.127.0.0.1.sslip.io:18081/ok';
  let title = 'OpenPath Site Fixture';
  const elements = new Map([
    [
      '#request-reason',
      {
        async clear() {},
        async sendKeys() {},
      },
    ],
    [
      '#submit-unblock-request',
      {
        async click() {},
      },
    ],
    [
      '#request-status',
      {
        async getText() {
          return 'Solicitud enviada. Quedara pendiente hasta que la revisen.';
        },
      },
    ],
  ]);
  const fakeWebDriver = {
    async get(url: string) {
      navigations.push(url);
      if (navigations.length === 2) {
        currentUrl = url;
        title = 'Sitio bloqueado';
      }
      throw timeoutError;
    },
    async getCurrentUrl() {
      return currentUrl;
    },
    async getTitle() {
      return title;
    },
    async findElement(locator: { value: string }) {
      const element = elements.get(locator.value);
      assert.ok(element, `Missing fake element for ${locator.value}`);
      return element;
    },
    async wait(condition: (driver: unknown) => Promise<boolean>, timeoutMs: number) {
      waits.push(timeoutMs);
      const result = await condition(this);
      if (result !== true) {
        throw new Error(`Wait timed out after ${timeoutMs.toString()}ms`);
      }
      return result;
    },
  };
  const driver = new StudentPolicyDriver(createScenario(), {
    diagnosticsDir: os.tmpdir(),
    headless: true,
  });
  (driver as unknown as { driver: unknown; extensionUuid: string }).driver = fakeWebDriver;
  (driver as unknown as { extensionUuid: string }).extensionUuid = 'extension-id';

  await driver.openBlockedScreenAndSubmitRequest('http://blocked.test/lesson', {
    reason: 'Needed for class',
    timeoutMs: 250,
  });

  assert.equal(navigations.length, 2);
  assert.match(navigations[1] ?? '', /^moz-extension:\/\/extension-id\/blocked\/blocked\.html\?/);
  assert.deepEqual(waits, [250, 250, 250]);
});

test('runtime messages wait until the extension popup exposes browser.runtime', async () => {
  const navigations: string[] = [];
  let runtimeReady = false;
  const state = {
    getDriver() {
      return {
        async get(url: string) {
          navigations.push(url);
        },
        async executeScript() {
          const ready = runtimeReady;
          runtimeReady = true;
          return ready;
        },
        async executeAsyncScript(script: string, _message: unknown) {
          assert.match(script, /browser\.runtime\.sendMessage/);
          return {
            ok: true,
            value: {
              count: 1,
              version: 'v1',
              rawRules: ['https://example.test/*private*'],
              compiledPatterns: ['^https://example\\.test/.*private.*$'],
            },
          };
        },
        async wait(condition: (driver: unknown) => Promise<boolean>) {
          assert.equal(await condition(this), false);
          assert.equal(await condition(this), true);
          return true;
        },
      };
    },
    getExtensionUuid() {
      return 'extension-id';
    },
  };

  const debug = await getBlockedPathRulesDebug(state as never);

  assert.match(navigations[0] ?? '', /^moz-extension:\/\/extension-id\/popup\/popup\.html/);
  assert.deepEqual(debug, {
    count: 1,
    version: 'v1',
    rawRules: ['https://example.test/*private*'],
    compiledPatterns: ['^https://example\\.test/.*private.*$'],
  });
});

test('Firefox setup primes extension runtime before fixture navigation', async () => {
  const calls: string[] = [];
  const driver = {
    async get(url: string) {
      calls.push(`get:${url}`);
    },
    async executeScript(script: string) {
      calls.push(`script:${script}`);
      return true;
    },
    async wait(condition: () => Promise<boolean>, timeoutMs: number) {
      calls.push(`wait:${timeoutMs.toString()}`);
      assert.equal(await condition(), true);
      return true;
    },
  };

  await waitForFirefoxExtensionRuntimeReady(driver as never, 'extension-id', 12_345);

  assert.equal(calls[0], 'get:moz-extension://extension-id/popup/popup.html');
  assert.equal(calls[1], 'wait:12345');
  assert.match(calls[2] ?? '', /browser\?\.runtime\?\.sendMessage/);
});
