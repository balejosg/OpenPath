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
import { openAndExpectBlocked, submitBlockedScreenRequest } from './student-policy-driver-browser';
import { getBlockedPathRulesDebug } from './student-policy-driver-runtime';
import { getStudentPolicyPhasePlan } from './student-policy-harness';
import { buildBaselineWhitelistHosts } from './student-policy-scenarios';

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

test('student policy scenario group defaults to full and accepts narrow groups', () => {
  const original = process.env.OPENPATH_STUDENT_SCENARIO_GROUP;

  try {
    delete process.env.OPENPATH_STUDENT_SCENARIO_GROUP;
    assert.strictEqual(getStudentPolicyScenarioGroup(), 'full');

    for (const group of [
      'request-lifecycle',
      'ajax-auto-allow',
      'path-blocking',
      'exemptions',
      'full',
    ]) {
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
    getStudentPolicyPhasePlan('sse', 'full', 'ajax-auto-allow').map(({ suite }) => suite),
    ['ajax-auto-allow']
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
