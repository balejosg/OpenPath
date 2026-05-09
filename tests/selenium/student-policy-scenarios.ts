import assert from 'node:assert';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  type LinuxAutoAllowDiagnosticPhase,
  type LinuxAutoAllowPhaseId,
  type LinuxAutoAllowProbe,
  upsertLinuxAutoAllowPhase,
  writeLinuxAutoAllowBoundaryArtifact,
} from './linux-auto-allow-diagnostics';
import {
  buildFixtureUrl,
  buildScenarioHost,
  escapeRegExp,
  readWhitelistFile,
} from './student-policy-env';
import { StudentPolicyServerClient } from './student-policy-client';
import { StudentPolicyDriver } from './student-policy-driver';
import type { PolicyMode, StudentScenario } from './student-policy-types';

interface StudentPolicyTargets {
  portalOkUrl: string;
  portalCdnAssetUrl: string;
  siteOkUrl: string;
  sitePrivateUrl: string;
  siteXhrPrivateUrl: string;
  requestDomainUrl: string;
  rejectedDomainUrl: string;
  duplicateDomainUrl: string;
  exemptedDomainUrl: string;
  baseOnlyUrl: string;
  baseOnlyCdnAssetUrl: string;
  alternateOnlyUrl: string;
  autoDomainFetchUrl: string;
  ajaxDependencyFetchUrl: string;
  ajaxDependencyXhrUrl: string;
  ajaxDependencyScriptUrl: string;
  ajaxDependencyImageUrl: string;
  ajaxDependencyStylesheetUrl: string;
  ajaxDependencyFontUrl: string;
  ajaxBlockedSubdomainFetchUrl: string;
  ajaxBlockedPathFetchUrl: string;
  hosts: {
    request: string;
    rejected: string;
    duplicate: string;
    exempted: string;
    baseOnly: string;
    alternateOnly: string;
    auto: string;
    ajaxDependency: string;
    ajaxDependencyFetch: string;
    ajaxDependencyXhr: string;
    ajaxDependencyScript: string;
    ajaxDependencyImage: string;
    ajaxDependencyStylesheet: string;
    ajaxDependencyFont: string;
    ajaxBlockedSubdomain: string;
    ajaxBlockedPath: string;
  };
}

interface StudentPolicyScenarioTiming {
  name: string;
  startedAt: string;
  endedAt: string;
  durationMs: number;
  durationSeconds: number;
}

interface PageResourceObserverState {
  installed?: boolean;
  lastError?: string | null;
  lastNotification?: { kind?: string; url?: string } | null;
  notifications?: Record<string, number>;
  patched?: Record<string, boolean>;
}

let activeScenarioTiming: {
  name: string;
  startedAt: string;
  startedAtNs: bigint;
} | null = null;

const scenarioTimings: StudentPolicyScenarioTiming[] = [];

function buildTargets(scenario: StudentScenario): StudentPolicyTargets {
  const requestHost = buildScenarioHost(scenario, 'request-domain');
  const rejectedHost = buildScenarioHost(scenario, 'rejected-domain');
  const duplicateHost = buildScenarioHost(scenario, 'duplicate-domain');
  const exemptedHost = buildScenarioHost(scenario, 'exempted-domain');
  const baseOnlyHost = buildScenarioHost(scenario, 'base-only');
  const alternateOnlyHost = buildScenarioHost(scenario, 'alternate-only');
  const autoHost = buildScenarioHost(scenario, 'auto-domain');
  const ajaxDependencyFetchHost = `api.${buildScenarioHost(scenario, 'ajax-dependency-fetch')}`;
  const ajaxDependencyXhrHost = `api.${buildScenarioHost(scenario, 'ajax-dependency-xhr')}`;
  const ajaxDependencyScriptHost = `cdn.${buildScenarioHost(scenario, 'ajax-dependency-script')}`;
  const ajaxDependencyImageHost = `image.${buildScenarioHost(scenario, 'ajax-dependency-image')}`;
  const ajaxDependencyStylesheetHost = `style.${buildScenarioHost(
    scenario,
    'ajax-dependency-stylesheet'
  )}`;
  const ajaxDependencyFontHost = `font.${buildScenarioHost(scenario, 'ajax-dependency-font')}`;
  const ajaxBlockedSubdomainHost = `api.${buildScenarioHost(scenario, 'ajax-blocked-subdomain')}`;
  const ajaxBlockedPathHost = `api.${buildScenarioHost(scenario, 'ajax-blocked-path')}`;

  return {
    portalOkUrl: buildFixtureUrl(scenario.fixtures.portal, '/ok'),
    portalCdnAssetUrl: buildFixtureUrl(scenario.fixtures.cdnPortal, '/asset.js'),
    siteOkUrl: buildFixtureUrl(scenario.fixtures.site, '/ok'),
    sitePrivateUrl: buildFixtureUrl(scenario.fixtures.site, '/private'),
    siteXhrPrivateUrl: buildFixtureUrl(scenario.fixtures.site, '/xhr/private.json'),
    requestDomainUrl: buildFixtureUrl(requestHost, '/ok'),
    rejectedDomainUrl: buildFixtureUrl(rejectedHost, '/ok'),
    duplicateDomainUrl: buildFixtureUrl(duplicateHost, '/ok'),
    exemptedDomainUrl: buildFixtureUrl(exemptedHost, '/ok'),
    baseOnlyUrl: buildFixtureUrl(baseOnlyHost, '/ok'),
    baseOnlyCdnAssetUrl: buildFixtureUrl(`cdn.${baseOnlyHost}`, '/asset.js'),
    alternateOnlyUrl: buildFixtureUrl(alternateOnlyHost, '/ok'),
    autoDomainFetchUrl: buildFixtureUrl(autoHost, '/fetch/private.json'),
    ajaxDependencyFetchUrl: buildFixtureUrl(ajaxDependencyFetchHost, '/fetch/private.json'),
    ajaxDependencyXhrUrl: buildFixtureUrl(ajaxDependencyXhrHost, '/xhr/private.json'),
    ajaxDependencyScriptUrl: buildFixtureUrl(ajaxDependencyScriptHost, '/asset.js'),
    ajaxDependencyImageUrl: buildFixtureUrl(ajaxDependencyImageHost, '/pixel.png'),
    ajaxDependencyStylesheetUrl: buildFixtureUrl(ajaxDependencyStylesheetHost, '/style.css'),
    ajaxDependencyFontUrl: buildFixtureUrl(ajaxDependencyFontHost, '/font.woff2'),
    ajaxBlockedSubdomainFetchUrl: buildFixtureUrl(ajaxBlockedSubdomainHost, '/fetch/private.json'),
    ajaxBlockedPathFetchUrl: buildFixtureUrl(ajaxBlockedPathHost, '/fetch/private.json'),
    hosts: {
      request: requestHost,
      rejected: rejectedHost,
      duplicate: duplicateHost,
      exempted: exemptedHost,
      baseOnly: baseOnlyHost,
      alternateOnly: alternateOnlyHost,
      auto: autoHost,
      ajaxDependency: ajaxDependencyFetchHost,
      ajaxDependencyFetch: ajaxDependencyFetchHost,
      ajaxDependencyXhr: ajaxDependencyXhrHost,
      ajaxDependencyScript: ajaxDependencyScriptHost,
      ajaxDependencyImage: ajaxDependencyImageHost,
      ajaxDependencyStylesheet: ajaxDependencyStylesheetHost,
      ajaxDependencyFont: ajaxDependencyFontHost,
      ajaxBlockedSubdomain: ajaxBlockedSubdomainHost,
      ajaxBlockedPath: ajaxBlockedPathHost,
    },
  };
}

function isWhitelistableHost(hostname: string): boolean {
  const labels = hostname.split('.');
  const tld = labels[labels.length - 1] ?? '';
  return labels.length >= 2 && /^[a-z]{2,63}$/i.test(tld);
}

export function buildBaselineWhitelistHosts(
  scenario: StudentScenario,
  targets: StudentPolicyTargets
): {
  restricted: string[];
  alternate: string[];
} {
  const hosts = [
    scenario.fixtures.portal,
    scenario.fixtures.cdnPortal,
    scenario.fixtures.site,
    scenario.fixtures.apiSite,
  ];

  const apiHostname = new URL(scenario.apiUrl).hostname;
  if (isWhitelistableHost(apiHostname)) {
    hosts.push(apiHostname);
  }

  return {
    restricted: [...new Set([...hosts, targets.hosts.baseOnly])],
    alternate: [...new Set([...hosts, targets.hosts.alternateOnly])],
  };
}

async function settlePolicyChange(
  driver: StudentPolicyDriver,
  mode: PolicyMode,
  assertion: () => Promise<void>,
  options: {
    refreshBlockedPaths?: boolean;
    refreshBlockedSubdomains?: boolean;
    timeoutMs?: number;
  } = {}
): Promise<void> {
  const runAssertion = async (): Promise<void> => {
    await driver.waitForConvergence(assertion, { timeoutMs: options.timeoutMs });
  };

  const forceConvergence = async (): Promise<void> => {
    await driver.forceLocalUpdate();
    if (options.refreshBlockedPaths === true) {
      await driver.refreshBlockedPathRules();
    }
    if (options.refreshBlockedSubdomains === true) {
      await driver.refreshBlockedSubdomainRules();
    }
  };

  if (mode === 'fallback') {
    await driver.waitForConvergence(
      async () => {
        await forceConvergence();
        await assertion();
      },
      { timeoutMs: options.timeoutMs ?? 45_000, pollMs: 1_000 }
    );
    return;
  }

  try {
    await runAssertion();
  } catch {
    await forceConvergence();
    await runAssertion();
  }
}

function logScenarioStep(message: string): void {
  finishActiveScenarioTiming();
  activeScenarioTiming = {
    name: message,
    startedAt: new Date().toISOString(),
    startedAtNs: process.hrtime.bigint(),
  };
  process.stdout.write(`student-policy: ${message}\n`);
}

function finishActiveScenarioTiming(): void {
  if (activeScenarioTiming === null) {
    return;
  }

  const endedAt = new Date().toISOString();
  const durationMs = Number(
    (process.hrtime.bigint() - activeScenarioTiming.startedAtNs) / 1_000_000n
  );
  scenarioTimings.push({
    name: activeScenarioTiming.name,
    startedAt: activeScenarioTiming.startedAt,
    endedAt,
    durationMs,
    durationSeconds: Number((durationMs / 1000).toFixed(3)),
  });
  activeScenarioTiming = null;
}

export function writeStudentPolicyScenarioTimings(diagnosticsDir: string): void {
  finishActiveScenarioTiming();
  if (scenarioTimings.length === 0) {
    return;
  }

  mkdirSync(diagnosticsDir, { recursive: true });
  writeFileSync(
    join(diagnosticsDir, 'student-policy-scenario-timings.json'),
    `${JSON.stringify(scenarioTimings, null, 2)}\n`,
    'utf8'
  );
}

function observerKindForProbe(probeId: string): string {
  return probeId === 'xhr' ? 'xmlhttprequest' : probeId;
}

function urlsMatchIgnoringCacheBust(actual: string | undefined, expected: string): boolean {
  if (!actual) {
    return false;
  }
  try {
    const actualUrl = new URL(actual);
    const expectedUrl = new URL(expected);
    actualUrl.searchParams.delete('cache');
    expectedUrl.searchParams.delete('cache');
    actualUrl.hash = '';
    expectedUrl.hash = '';
    return actualUrl.toString() === expectedUrl.toString();
  } catch {
    return actual === expected;
  }
}

async function readPageResourceObserverState(
  driver: StudentPolicyDriver
): Promise<PageResourceObserverState | null> {
  const state = await driver
    .getDriver()
    .executeScript('return window.__openpathPageResourceObserverState ?? null;');
  if (!state || typeof state !== 'object') {
    return null;
  }
  return state as PageResourceObserverState;
}

async function waitForPageResourceObserver(
  driver: StudentPolicyDriver,
  timeoutMs = 10_000
): Promise<PageResourceObserverState | null> {
  const deadline = Date.now() + timeoutMs;
  let lastState: PageResourceObserverState | null = null;

  while (Date.now() < deadline) {
    lastState = await readPageResourceObserverState(driver);
    if (lastState?.installed === true) {
      return lastState;
    }

    await new Promise((resolve) => {
      setTimeout(resolve, 100);
    });
  }

  return lastState;
}

async function seedBaselineWhitelist(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode,
  targets: StudentPolicyTargets,
  options: { verifyBrowser?: boolean } = {}
): Promise<void> {
  const restrictedGroupId = driver.scenario.groups.restricted.id;
  const alternateGroupId = driver.scenario.groups.alternate.id;
  const baselineHosts = buildBaselineWhitelistHosts(driver.scenario, targets);

  for (const host of baselineHosts.restricted) {
    await client.ensureWhitelistRule(restrictedGroupId, host, 'Student policy restricted baseline');
  }

  for (const host of baselineHosts.alternate) {
    await client.ensureWhitelistRule(alternateGroupId, host, 'Student policy alternate baseline');
  }

  await driver.forceLocalUpdate();

  await settlePolicyChange(driver, mode, async () => {
    await driver.assertWhitelistContains(driver.scenario.fixtures.portal);
    await driver.assertWhitelistContains(driver.scenario.fixtures.site);
    if (options.verifyBrowser !== false) {
      await driver.openAndExpectLoaded({
        url: targets.portalOkUrl,
        title: 'OpenPath Portal Fixture',
        selector: '#page-status',
      });
      await driver.waitForDomStatus('#subdomain-status', 'ok');
      await driver.openAndExpectLoaded({
        url: targets.siteOkUrl,
        title: 'OpenPath Site Fixture',
        selector: '#page-status',
      });
    }
  });
}

async function runRequestLifecycleScenarioSet(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode,
  targets: StudentPolicyTargets
): Promise<void> {
  logScenarioStep('SP-001 to SP-005 request lifecycle');

  await driver.assertDnsBlocked(targets.hosts.request);
  const requestStatusText = await driver.openBlockedScreenAndSubmitRequest(
    targets.requestDomainUrl,
    {
      reason: 'Request host needed for lesson flow',
      timeoutMs: 30_000,
    }
  );
  assert.match(requestStatusText, /Solicitud enviada/);

  const pending = await client.findPendingRequestByDomain(targets.hosts.request);
  const pendingStatus = await client.getRequestStatus(pending.id);
  assert.strictEqual(pendingStatus.status, 'pending');
  await driver.openAndExpectBlocked({
    url: targets.requestDomainUrl,
    forbiddenText: 'Site Fixture',
  });

  await client.approveRequest(pending.id, driver.scenario.groups.restricted.id);
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertDnsAllowed(targets.hosts.request);
    await driver.assertWhitelistContains(targets.hosts.request);
    await driver.openAndExpectLoaded({
      url: targets.requestDomainUrl,
      title: 'OpenPath Site Fixture',
      selector: '#page-status',
    });
  });

  const rejected = await client.submitManualRequest(
    targets.hosts.rejected,
    'This request should be rejected for policy verification'
  );
  assert.strictEqual(rejected.success, true);
  assert.ok(rejected.id !== undefined);
  await client.rejectRequest(rejected.id ?? '', 'Rejected during Selenium policy test');
  const rejectedStatus = await client.getRequestStatus(rejected.id ?? '');
  assert.strictEqual(rejectedStatus.status, 'rejected');
  await driver.assertDnsBlocked(targets.hosts.rejected);
  await driver.openAndExpectBlocked({
    url: targets.rejectedDomainUrl,
    forbiddenText: 'Site Fixture',
  });

  const duplicateInitial = await client.submitManualRequest(
    targets.hosts.duplicate,
    'Duplicate request first submission'
  );
  assert.strictEqual(duplicateInitial.success, true);
  assert.ok(duplicateInitial.id !== undefined);

  const duplicateFollowUp = await client.submitManualRequest(
    targets.hosts.duplicate,
    'Duplicate request second submission'
  );
  assert.strictEqual(duplicateFollowUp.success, false);
  assert.ok((duplicateFollowUp.error ?? '').length > 0);
  await driver.assertDnsBlocked(targets.hosts.duplicate);
}

async function runAjaxAutoAllowScenarioSet(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode,
  targets: StudentPolicyTargets
): Promise<void> {
  await client.setAutoApprove(false);
  let linuxAutoAllowPhases: LinuxAutoAllowDiagnosticPhase[] = [
    {
      id: 'firefox-extension-ready',
      status: 'passed',
      message: 'Selenium reached SP-006 with the Firefox extension and native host ready.',
    },
  ];
  const linuxAutoAllowProbes: LinuxAutoAllowProbe[] = [];

  const recordLinuxAutoAllowPhase = (
    phase: LinuxAutoAllowDiagnosticPhase
  ): LinuxAutoAllowDiagnosticPhase[] => {
    linuxAutoAllowPhases = upsertLinuxAutoAllowPhase(linuxAutoAllowPhases, phase);
    return linuxAutoAllowPhases;
  };

  const runLinuxDiagnosticPhase = async <T>(
    id: LinuxAutoAllowPhaseId,
    callback: () => Promise<T>
  ): Promise<T> => {
    try {
      const result = await callback();
      recordLinuxAutoAllowPhase({ id, status: 'passed' });
      return result;
    } catch (error) {
      recordLinuxAutoAllowPhase({
        id,
        status: 'failed',
        message: error instanceof Error ? error.message : String(error),
      });
      throw error;
    }
  };

  const writeLinuxArtifact = async (success: boolean): Promise<void> => {
    try {
      await writeLinuxAutoAllowBoundaryArtifact({
        diagnosticsDir: driver.diagnosticsDir,
        success,
        phases: linuxAutoAllowPhases,
        probes: linuxAutoAllowProbes,
        fetchRemoteWhitelist: () => client.fetchMachineWhitelist(),
      });
    } catch (error) {
      logScenarioStep(
        `linux auto-allow artifact write error: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  };

  const dependencyProbes: Array<{
    id: string;
    diagnosticId?: LinuxAutoAllowProbe['id'];
    host: string;
    url: string;
    run: () => Promise<'ok' | 'blocked'>;
  }> = [
    {
      id: 'fetch',
      diagnosticId: 'fetch',
      host: targets.hosts.ajaxDependencyFetch,
      url: targets.ajaxDependencyFetchUrl,
      run: () => driver.runCrossOriginFetchProbe(targets.ajaxDependencyFetchUrl),
    },
    {
      id: 'xhr',
      diagnosticId: 'xhr',
      host: targets.hosts.ajaxDependencyXhr,
      url: targets.ajaxDependencyXhrUrl,
      run: () => driver.runCrossOriginXhrProbe(targets.ajaxDependencyXhrUrl),
    },
    {
      id: 'script',
      diagnosticId: 'script',
      host: targets.hosts.ajaxDependencyScript,
      url: targets.ajaxDependencyScriptUrl,
      run: () => driver.runCrossOriginElementProbe(targets.ajaxDependencyScriptUrl, 'script'),
    },
    {
      id: 'image',
      diagnosticId: 'image',
      host: targets.hosts.ajaxDependencyImage,
      url: targets.ajaxDependencyImageUrl,
      run: () => driver.runCrossOriginElementProbe(targets.ajaxDependencyImageUrl, 'image'),
    },
    {
      id: 'stylesheet',
      diagnosticId: 'stylesheet',
      host: targets.hosts.ajaxDependencyStylesheet,
      url: targets.ajaxDependencyStylesheetUrl,
      run: () =>
        driver.runCrossOriginElementProbe(targets.ajaxDependencyStylesheetUrl, 'stylesheet'),
    },
    {
      id: 'font',
      diagnosticId: 'font',
      host: targets.hosts.ajaxDependencyFont,
      url: targets.ajaxDependencyFontUrl,
      run: () => driver.runCrossOriginElementProbe(targets.ajaxDependencyFontUrl, 'font'),
    },
  ];

  try {
    for (const probe of dependencyProbes) {
      logScenarioStep(`SP-006 ${probe.id} dependency auto-allow from whitelisted origin`);

      const linuxProbe: LinuxAutoAllowProbe | null =
        probe.diagnosticId === undefined
          ? null
          : {
              id: probe.diagnosticId,
              host: probe.host,
              url: probe.url,
            };
      if (linuxProbe !== null) {
        linuxAutoAllowProbes.push(linuxProbe);
      }

      await driver.assertWhitelistMissing(probe.host);
      await driver.assertDnsBlocked(probe.host);
      await runLinuxDiagnosticPhase('origin-page-load', async () => {
        await driver.openAndExpectLoaded({
          url: targets.siteOkUrl,
          title: 'OpenPath Site Fixture',
          selector: '#page-status',
        });
      });
      await runLinuxDiagnosticPhase('page-observer', async () => {
        const observerState = await waitForPageResourceObserver(driver);
        assert.strictEqual(
          observerState?.installed === true,
          true,
          'page resource observer should be installed'
        );
      });

      const firstResult = await runLinuxDiagnosticPhase('probe-traffic', async () => {
        const result = await probe.run();
        assert.ok(
          result === 'blocked' || result === 'ok',
          `${probe.id} dependency probe should complete before auto-allow convergence`
        );
        return result;
      });
      if (linuxProbe !== null) {
        linuxProbe.firstResult = firstResult;
      }
      await runLinuxDiagnosticPhase('page-resource-candidates', async () => {
        const observerState = await readPageResourceObserverState(driver);
        if (linuxProbe !== null) {
          linuxProbe.observerState = observerState ?? undefined;
        }
        assert.ok(observerState, 'page resource observer state should be readable');
        assert.strictEqual(
          observerState.lastError ?? null,
          null,
          `page resource observer should not report an error for ${probe.id}`
        );
        const expectedKind = observerKindForProbe(probe.id);
        const notifications = observerState.notifications ?? {};
        assert.ok(
          (notifications[expectedKind] ?? 0) > 0,
          `${probe.id} dependency should emit a ${expectedKind} page-resource candidate`
        );
        assert.ok(
          urlsMatchIgnoringCacheBust(observerState.lastNotification?.url, probe.url),
          `${probe.id} dependency should emit the probed async dependency URL`
        );
      });

      await runLinuxDiagnosticPhase('remote-rule-creation', async () => {
        await driver.waitForConvergence(
          async () => {
            assert.match(
              await client.fetchMachineWhitelist(),
              new RegExp(`(^|\\n)${escapeRegExp(probe.host)}($|\\n)`)
            );
          },
          { timeoutMs: 45_000, pollMs: 1_000 }
        );
      });

      await runLinuxDiagnosticPhase('local-whitelist-apply', async () => {
        await settlePolicyChange(
          driver,
          mode,
          async () => {
            await driver.assertWhitelistContains(probe.host);
          },
          { timeoutMs: 45_000 }
        );
      });

      await runLinuxDiagnosticPhase('dns-policy-apply', async () => {
        await settlePolicyChange(
          driver,
          mode,
          async () => {
            await driver.assertDnsAllowed(probe.host);
          },
          { timeoutMs: 45_000 }
        );
      });

      await driver.openAndExpectLoaded({
        url: targets.siteOkUrl,
        title: 'OpenPath Site Fixture',
        selector: '#page-status',
      });
      let secondResult: 'ok' | 'blocked' = 'blocked';
      await runLinuxDiagnosticPhase('probe-traffic', async () => {
        await driver.waitForConvergence(
          async () => {
            await driver.openAndExpectLoaded({
              url: targets.siteOkUrl,
              title: 'OpenPath Site Fixture',
              selector: '#page-status',
            });
            secondResult = await probe.run();
            assert.strictEqual(
              secondResult,
              'ok',
              `${probe.id} dependency should load after auto-allow`
            );
          },
          { timeoutMs: 45_000, pollMs: 2_000 }
        );
        return secondResult;
      });
      if (linuxProbe !== null) {
        linuxProbe.secondResult = secondResult;
      }
    }
    await writeLinuxArtifact(true);
  } catch (error) {
    if (!linuxAutoAllowPhases.some((phase) => phase.status === 'failed')) {
      recordLinuxAutoAllowPhase({
        id: 'probe-traffic',
        status: 'failed',
        message: error instanceof Error ? error.message : String(error),
      });
    }
    await writeLinuxArtifact(false);
    throw error;
  }

  logScenarioStep('SP-006 blocked subdomain prevents ajax auto-allow');
  const blockedSubdomainRule = await client.createGroupRule(
    driver.scenario.groups.restricted.id,
    'blocked_subdomain',
    targets.hosts.ajaxBlockedSubdomain,
    'Block AJAX dependency subdomain for Selenium policy test'
  );

  try {
    await driver.forceLocalUpdate();
    await driver.openAndExpectLoaded({
      url: targets.siteOkUrl,
      title: 'OpenPath Site Fixture',
      selector: '#page-status',
    });
    const blockedSubdomainFetch = await driver.runCrossOriginFetchProbe(
      targets.ajaxBlockedSubdomainFetchUrl
    );
    assert.strictEqual(blockedSubdomainFetch, 'blocked');
    const blockedSubdomainRequest = await client.submitAutoRequest(
      targets.hosts.ajaxBlockedSubdomain,
      'Blocked subdomain must prevent AJAX dependency auto-allow',
      {
        originPage: targets.siteOkUrl,
        targetUrl: targets.ajaxBlockedSubdomainFetchUrl,
      }
    );
    assert.strictEqual(blockedSubdomainRequest.success, false);
    assert.match(blockedSubdomainRequest.error ?? '', /blocked subdomain/i);
    await driver.waitForConvergence(
      async () => {
        await driver.assertDnsBlocked(targets.hosts.ajaxBlockedSubdomain);
      },
      { timeoutMs: 20_000, pollMs: 1_000 }
    );
  } finally {
    await client.deleteGroupRule(blockedSubdomainRule.id, driver.scenario.groups.restricted.id);
    await driver.forceLocalUpdate();
  }

  logScenarioStep('SP-006 blocked path prevents ajax auto-allow');
  const blockedPathRule = await client.createGroupRule(
    driver.scenario.groups.restricted.id,
    'blocked_path',
    `${targets.hosts.ajaxBlockedPath}/fetch/private`,
    'Block AJAX dependency path for Selenium policy test'
  );

  try {
    await driver.forceLocalUpdate();
    await driver.refreshBlockedPathRules();
    await settlePolicyChange(
      driver,
      mode,
      async () => {
        assert.deepStrictEqual(
          await driver.evaluateBlockedPathDebug(targets.ajaxBlockedPathFetchUrl, 'fetch'),
          {
            cancel: true,
            reason: `BLOCKED_PATH_POLICY:${targets.hosts.ajaxBlockedPath}/fetch/private`,
          }
        );
      },
      { refreshBlockedPaths: true, timeoutMs: 20_000 }
    );
    await driver.openAndExpectLoaded({
      url: targets.siteOkUrl,
      title: 'OpenPath Site Fixture',
      selector: '#page-status',
    });
    const blockedPathFetch = await driver.runCrossOriginFetchProbe(targets.ajaxBlockedPathFetchUrl);
    assert.strictEqual(blockedPathFetch, 'blocked');
    const blockedPathRequest = await client.submitAutoRequest(
      targets.hosts.ajaxBlockedPath,
      'Blocked path must prevent AJAX dependency auto-allow',
      {
        originPage: targets.siteOkUrl,
        targetUrl: targets.ajaxBlockedPathFetchUrl,
      }
    );
    assert.strictEqual(blockedPathRequest.success, false);
    assert.match(blockedPathRequest.error ?? '', /blocked path/i);
    await driver.assertWhitelistMissing(targets.hosts.ajaxBlockedPath);
    await driver.assertDnsBlocked(targets.hosts.ajaxBlockedPath);
  } finally {
    await client.deleteGroupRule(blockedPathRule.id, driver.scenario.groups.restricted.id);
    await driver.forceLocalUpdate();
    try {
      await driver.refreshBlockedPathRules();
    } catch (error) {
      logScenarioStep(
        `blocked-path cleanup refresh error: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }
}

async function runBlockedSubdomainScenarios(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode,
  targets: StudentPolicyTargets
): Promise<void> {
  logScenarioStep('SP-008 to SP-010 blocked subdomain');

  const blockedSubdomainHost = `cdn.${targets.hosts.baseOnly}`;

  const rule = await client.createGroupRule(
    driver.scenario.groups.restricted.id,
    'blocked_subdomain',
    blockedSubdomainHost,
    'Block CDN subdomain for Selenium policy test'
  );

  await driver.forceLocalUpdate();
  await driver.refreshBlockedSubdomainRules();
  await driver.restart();

  await settlePolicyChange(
    driver,
    mode,
    async () => {
      await driver.assertDnsAllowed(targets.hosts.baseOnly);
      await driver.assertDnsBlocked(blockedSubdomainHost);
      await driver.openAndExpectLoaded({
        url: targets.baseOnlyUrl,
        title: 'OpenPath Site Fixture',
        selector: '#page-status',
      });
      await driver.rerunPortalSubdomainProbe();
      await driver.waitForDomStatus('#subdomain-status', 'blocked');
      await driver.openAndExpectBlocked({
        url: targets.baseOnlyCdnAssetUrl,
        forbiddenText: '__openpathPortalAssetLoaded',
      });
    },
    { refreshBlockedSubdomains: true }
  );

  await client.deleteGroupRule(rule.id, driver.scenario.groups.restricted.id);
  await driver.forceLocalUpdate();
  await driver.refreshBlockedSubdomainRules();
  await driver.restart();
  await settlePolicyChange(
    driver,
    mode,
    async () => {
      await driver.assertDnsAllowed(blockedSubdomainHost);
      await driver.openAndExpectLoaded({
        url: targets.baseOnlyUrl,
        title: 'OpenPath Site Fixture',
        selector: '#page-status',
      });
      await driver.rerunPortalSubdomainProbe();
      await driver.waitForDomStatus('#subdomain-status', 'ok');
    },
    { refreshBlockedSubdomains: true }
  );
}

async function runBlockedPathScenarios(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode,
  targets: StudentPolicyTargets
): Promise<void> {
  logScenarioStep('SP-011 to SP-015 blocked path');

  const rule = await client.createGroupRule(
    driver.scenario.groups.restricted.id,
    'blocked_path',
    `${driver.scenario.fixtures.site}/*private*`,
    'Block private route for Selenium policy test'
  );

  await driver.forceLocalUpdate();
  await driver.restart();

  try {
    await driver.refreshBlockedPathRules();
  } catch (error) {
    logScenarioStep(
      `blocked-path refresh error: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  const blockedPathDebug = await driver.getBlockedPathRulesDebug();
  const nativeBlockedPathDebug = await driver.getNativeBlockedPathsDebug();
  logScenarioStep(
    `blocked-path debug: count=${blockedPathDebug.count.toString()} rules=${blockedPathDebug.rawRules.join(',')}`
  );
  logScenarioStep(
    `native blocked-path debug: success=${String(nativeBlockedPathDebug.success)} count=${nativeBlockedPathDebug.count.toString()} rules=${nativeBlockedPathDebug.paths.join(',')} source=${nativeBlockedPathDebug.source ?? '-'} error=${nativeBlockedPathDebug.error ?? '-'}`
  );
  logScenarioStep(
    `blocked-path evaluate xhr debug: ${JSON.stringify(
      await driver.evaluateBlockedPathDebug(targets.siteXhrPrivateUrl, 'xmlhttprequest')
    )}`
  );

  await settlePolicyChange(
    driver,
    mode,
    async () => {
      logScenarioStep('SP-011 verify main-frame path block');
      await driver.openAndExpectLoaded({
        url: targets.siteOkUrl,
        title: 'OpenPath Site Fixture',
        selector: '#page-status',
      });
      await driver.openAndExpectBlockedScreen(targets.sitePrivateUrl, {
        reasonPrefix: 'BLOCKED_PATH_POLICY:',
      });
      logScenarioStep('SP-012 verify iframe path block');
      await driver.openAndExpectLoaded({
        url: targets.siteOkUrl,
        title: 'OpenPath Site Fixture',
        selector: '#page-status',
      });
      await driver.rerunIframeProbe();
      await driver.waitForDomStatus('#iframe-status', 'blocked');
      logScenarioStep('SP-013 verify XHR path block');
      await driver.rerunXhrProbe();
      await driver.waitForDomStatus('#xhr-status', 'blocked');
      logScenarioStep('SP-014 verify fetch path block');
      await driver.rerunFetchProbe();
      await driver.waitForDomStatus('#fetch-status', 'blocked');
    },
    { refreshBlockedPaths: true }
  );

  await client.deleteGroupRule(rule.id, driver.scenario.groups.restricted.id);
  await driver.forceLocalUpdate();
  await driver.restart();
  await settlePolicyChange(
    driver,
    mode,
    async () => {
      logScenarioStep('SP-015 verify path unblock');
      await driver.openAndExpectLoaded({
        url: targets.sitePrivateUrl,
        title: 'Private Fixture',
        selector: '#page-status',
      });
      await driver.openAndExpectLoaded({
        url: targets.siteOkUrl,
        title: 'OpenPath Site Fixture',
        selector: '#page-status',
      });
      await driver.rerunIframeProbe();
      await driver.waitForDomStatus('#iframe-status', 'ok');
      await driver.rerunXhrProbe();
      await driver.waitForDomStatus('#xhr-status', 'ok');
      await driver.rerunFetchProbe();
      await driver.waitForDomStatus('#fetch-status', 'ok');
    },
    { refreshBlockedPaths: true }
  );
}

async function runTemporaryExemptionScenarios(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode,
  targets: StudentPolicyTargets
): Promise<void> {
  logScenarioStep('SP-016 to SP-018 temporary exemptions');

  await driver.assertDnsBlocked(targets.hosts.exempted);

  const exemption = await client.createTemporaryExemption(
    driver.scenario.schedules.activeRestriction.id
  );
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertHttpReachable(targets.exemptedDomainUrl);
    await driver.assertWhitelistMissing(targets.hosts.exempted);
  });

  await client.deleteTemporaryExemption(exemption.id);
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertDnsBlocked(targets.hosts.exempted);
    await driver.assertHttpBlocked(targets.exemptedDomainUrl);
  });

  const expiringExemption = await client.createTemporaryExemption(
    driver.scenario.schedules.activeRestriction.id
  );
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertHttpReachable(targets.exemptedDomainUrl);
  });

  await client.setTestClock(driver.scenario.schedules.activeRestriction.endAt);
  await client.tickBoundaries(driver.scenario.schedules.activeRestriction.endAt);
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertDnsBlocked(targets.hosts.exempted);
    await driver.assertHttpBlocked(targets.exemptedDomainUrl);
  });
  await client.setTestClock(null);

  void expiringExemption;
}

async function runActiveGroupAndScheduleScenarios(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode,
  targets: StudentPolicyTargets
): Promise<void> {
  logScenarioStep('SP-019 to SP-022 active group and schedule');

  await settlePolicyChange(driver, mode, async () => {
    await driver.assertWhitelistContains(targets.hosts.baseOnly);
    await driver.assertWhitelistMissing(targets.hosts.alternateOnly);
  });

  const currentGroup = await client.setActiveGroup(driver.scenario.groups.alternate.id);
  assert.strictEqual(currentGroup, driver.scenario.groups.alternate.id);
  logScenarioStep(
    `machine context after setActiveGroup: ${JSON.stringify(await client.getMachineContext())}`
  );
  logScenarioStep(`whitelist after setActiveGroup:\n${await client.fetchMachineWhitelist()}`);
  await settlePolicyChange(driver, mode, async () => {
    logScenarioStep(`local whitelist snapshot after setActiveGroup:\n${await readWhitelistFile()}`);
    await driver.assertWhitelistContains(targets.hosts.alternateOnly);
    await driver.assertWhitelistMissing(targets.hosts.baseOnly);
  });

  const restoredGroup = await client.setActiveGroup(null);
  assert.strictEqual(restoredGroup, driver.scenario.groups.restricted.id);
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertWhitelistContains(targets.hosts.baseOnly);
    await driver.assertWhitelistMissing(targets.hosts.alternateOnly);
  });

  await client.tickBoundaries(driver.scenario.schedules.futureAlternate.startAt);
  await client.setTestClock(driver.scenario.schedules.futureAlternate.startAt);
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertWhitelistContains(targets.hosts.alternateOnly);
  });

  await client.setTestClock(driver.scenario.schedules.futureAlternate.endAt);
  await client.tickBoundaries(driver.scenario.schedules.futureAlternate.endAt);
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertWhitelistMissing(targets.hosts.alternateOnly);
  });
  await client.setTestClock(null);
}

async function runAutoApproveProbe(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode,
  targets: StudentPolicyTargets
): Promise<void> {
  logScenarioStep('SP-006 and SP-007 auto-approve');

  await client.setAutoApprove(false);
  const pendingAutoRequest = await client.submitAutoRequest(
    targets.hosts.auto,
    'Auto-approve disabled should keep request pending',
    {
      originPage: targets.rejectedDomainUrl,
    }
  );
  assert.strictEqual(pendingAutoRequest.success, true);
  assert.strictEqual(pendingAutoRequest.autoApproved, false);
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertDnsBlocked(targets.hosts.auto);
  });

  await client.setAutoApprove(true);
  const autoRequest = await client.submitAutoRequest(
    targets.hosts.auto,
    'Auto-approve test trigger'
  );
  assert.strictEqual(autoRequest.success, true);
  await settlePolicyChange(driver, mode, async () => {
    await driver.assertWhitelistContains(targets.hosts.auto);
  });
}

export async function runStudentPolicyMatrix(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode
): Promise<void> {
  const targets = buildTargets(driver.scenario);

  await seedBaselineWhitelist(client, driver, mode, targets);
  await runAjaxAutoAllowScenarioSet(client, driver, mode, targets);
  await runRequestLifecycleScenarioSet(client, driver, mode, targets);
  await runBlockedSubdomainScenarios(client, driver, mode, targets);
  await runBlockedPathScenarios(client, driver, mode, targets);
}

export async function runPathBlockingScenarios(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode
): Promise<void> {
  const targets = buildTargets(driver.scenario);

  await seedBaselineWhitelist(client, driver, mode, targets);
  await runBlockedSubdomainScenarios(client, driver, mode, targets);
  await runBlockedPathScenarios(client, driver, mode, targets);
}

export async function runRequestLifecycleScenarios(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode
): Promise<void> {
  const targets = buildTargets(driver.scenario);

  await seedBaselineWhitelist(client, driver, mode, targets);
  await runRequestLifecycleScenarioSet(client, driver, mode, targets);
}

export async function runAjaxAutoAllowScenarios(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode
): Promise<void> {
  const targets = buildTargets(driver.scenario);

  await seedBaselineWhitelist(client, driver, mode, targets);
  await runAjaxAutoAllowScenarioSet(client, driver, mode, targets);
}

export async function runExemptionAndScheduleScenarios(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode
): Promise<void> {
  const targets = buildTargets(driver.scenario);

  await seedBaselineWhitelist(client, driver, mode, targets, { verifyBrowser: false });
  await runTemporaryExemptionScenarios(client, driver, mode, targets);
  await runActiveGroupAndScheduleScenarios(client, driver, mode, targets);
}

export async function runStudentPolicyMatrixPhaseTwo(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode
): Promise<void> {
  const targets = buildTargets(driver.scenario);

  await seedBaselineWhitelist(client, driver, mode, targets, { verifyBrowser: false });
  await runTemporaryExemptionScenarios(client, driver, mode, targets);
  await runActiveGroupAndScheduleScenarios(client, driver, mode, targets);
  await runAutoApproveProbe(client, driver, mode, targets);
}

export async function runFallbackPropagationProbe(
  client: StudentPolicyServerClient,
  driver: StudentPolicyDriver,
  mode: PolicyMode
): Promise<void> {
  const targets = buildTargets(driver.scenario);

  await seedBaselineWhitelist(client, driver, mode, targets);

  logScenarioStep('SP-FB-001 fallback request approval propagation');
  await driver.assertDnsBlocked(targets.hosts.request);
  const requestStatusText = await driver.openBlockedScreenAndSubmitRequest(
    targets.requestDomainUrl,
    {
      reason: 'Fallback propagation request approval proof',
      timeoutMs: 30_000,
    }
  );
  assert.match(requestStatusText, /Solicitud enviada/);

  const pending = await client.findPendingRequestByDomain(targets.hosts.request);
  await client.approveRequest(pending.id, driver.scenario.groups.restricted.id);
  await settlePolicyChange(
    driver,
    mode,
    async () => {
      await driver.assertDnsAllowed(targets.hosts.request);
      await driver.assertWhitelistContains(targets.hosts.request);
      await driver.openAndExpectLoaded({
        url: targets.requestDomainUrl,
        title: 'OpenPath Site Fixture',
        selector: '#page-status',
      });
    },
    { timeoutMs: 45_000 }
  );

  logScenarioStep('SP-FB-002 fallback blocked-path propagation');
  const rule = await client.createGroupRule(
    driver.scenario.groups.restricted.id,
    'blocked_path',
    `${driver.scenario.fixtures.site}/*private*`,
    'Fallback blocked-path propagation proof'
  );

  try {
    await driver.forceLocalUpdate();
    await driver.refreshBlockedPathRules();
    await settlePolicyChange(
      driver,
      mode,
      async () => {
        const blockedPathOutcome = (await driver.evaluateBlockedPathDebug(
          targets.sitePrivateUrl,
          'main_frame'
        )) as { reason?: string; redirectUrl?: string };
        assert.strictEqual(
          blockedPathOutcome.reason,
          `BLOCKED_PATH_POLICY:${driver.scenario.fixtures.site}/*private*`
        );
        assert.match(String(blockedPathOutcome.redirectUrl ?? ''), /\/blocked\/blocked\.html/);
        await driver.openAndExpectBlockedScreen(targets.sitePrivateUrl, {
          reasonPrefix: 'BLOCKED_PATH_POLICY:',
        });
      },
      { refreshBlockedPaths: true, timeoutMs: 20_000 }
    );
  } finally {
    await client.deleteGroupRule(rule.id, driver.scenario.groups.restricted.id);
    await driver.forceLocalUpdate();
    try {
      await driver.refreshBlockedPathRules();
    } catch (error) {
      logScenarioStep(
        `fallback blocked-path cleanup refresh error: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }
}
