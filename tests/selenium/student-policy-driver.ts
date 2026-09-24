import assert from 'node:assert';
import { promises as dnsPromises } from 'node:dns';

import { Builder, By, until, type WebDriver, type WebElement } from 'selenium-webdriver';
import * as firefox from 'selenium-webdriver/firefox';

import { waitForFirefoxExtensionUuid } from './firefox-extension-uuid';
import {
  buildPopupUrl,
  buildWindowsBlockedDnsCommand,
  buildWindowsHttpProbeCommand,
  DEFAULT_BLOCKED_TIMEOUT_MS,
  DEFAULT_TIMEOUT_MS,
  ensureDirectory,
  FIREFOX_EXTENSION_ID,
  getDiagnosticsDir,
  getPolicyMode,
  normalizeBoolean,
  optionalEnv,
  runPlatformCommand,
  shouldSkipBundledExtension,
  DEFAULT_EXTENSION_PATH,
} from './student-policy-env';
import {
  openAndExpectBlocked,
  openAndExpectLoaded,
  saveDiagnostics,
  submitBlockedScreenRequest,
  waitForBlockedScreen,
  waitForDomStatus,
} from './student-policy-driver-browser';
import {
  assertDnsAllowed,
  assertDnsBlocked,
  assertHttpBlocked,
  assertHttpReachable,
  assertWhitelistContains,
  assertWhitelistMissing,
  forceLocalUpdate,
  waitForConvergence,
  withSseDisabled,
} from './student-policy-driver-platform';
import {
  evaluateBlockedPathDebug,
  getActiveTabId,
  getBlockedPathRulesDebug,
  getDomainStatuses,
  getNativeBlockedPathsDebug,
  refreshBlockedSubdomainRules,
  refreshBlockedPathRules,
  runCrossOriginElementProbe,
  rerunFetchProbe,
  rerunIframeProbe,
  rerunPortalSubdomainProbe,
  rerunXhrProbe,
  runCrossOriginFetchProbe,
  runCrossOriginXhrProbe,
  sendRuntimeMessage,
  type CrossOriginElementProbeType,
} from './student-policy-driver-runtime';
import type { StudentPolicyDriverState } from './student-policy-driver-state';
import type {
  BlockedScreenExpectation,
  BlockedScreenRequestOptions,
  ConvergenceOptions,
  DomainStatusPayload,
  OpenAndExpectBlockedOptions,
  OpenAndExpectLoadedOptions,
  RuntimeResponse,
  StudentPolicyDriverOptions,
  StudentScenario,
} from './student-policy-types';

async function discoverFirefoxExtensionUuid(profileDir: string): Promise<string> {
  return waitForFirefoxExtensionUuid({
    profileDir,
    extensionId: FIREFOX_EXTENSION_ID,
    timeoutMs: DEFAULT_TIMEOUT_MS,
  });
}

export async function waitForFirefoxExtensionRuntimeReady(
  driver: WebDriver,
  extensionUuid: string,
  timeoutMs = DEFAULT_TIMEOUT_MS
): Promise<void> {
  try {
    await driver.get(buildPopupUrl(extensionUuid));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes('Navigation timed out')) {
      throw error;
    }
  }

  await driver.wait(async () => {
    try {
      return await driver.executeScript<boolean>(
        `return typeof globalThis.browser?.runtime?.sendMessage === 'function';`
      );
    } catch {
      return false;
    }
  }, timeoutMs);
}

function isBlockedNavigationError(message: string): boolean {
  return (
    message.includes('blockedByPolicy') ||
    message.includes('Reached error page') ||
    message.includes('Navigation timed out')
  );
}

function isNavigationTimeout(message: string): boolean {
  return message.includes('Navigation timed out');
}

function buildBlockedScreenFallbackUrl(
  extensionUuid: string,
  url: string,
  expectation: BlockedScreenExpectation
): string {
  const target = new URL(url);
  const blockedUrl = new URL(`moz-extension://${extensionUuid}/blocked/blocked.html`);
  blockedUrl.searchParams.set('domain', target.hostname);
  blockedUrl.searchParams.set('error', expectation.reasonPrefix ?? 'blockedByPolicy');
  blockedUrl.searchParams.set('origin', url);
  return blockedUrl.toString();
}

async function openBlockedScreenFallback(
  driver: WebDriver,
  extensionUuid: string,
  url: string,
  expectation: BlockedScreenExpectation
): Promise<void> {
  try {
    await driver.get(buildBlockedScreenFallbackUrl(extensionUuid, url, expectation));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!isNavigationTimeout(message)) {
      throw error;
    }
  }
}

export class StudentPolicyDriver implements StudentPolicyDriverState {
  public readonly scenario: StudentScenario;

  public readonly diagnosticsDir: string;

  private readonly extensionPath: string;

  private readonly firefoxBinaryPath?: string;

  private readonly headless: boolean;

  private driver: WebDriver | null = null;

  private extensionUuid: string | null = null;

  public constructor(scenario: StudentScenario, options: StudentPolicyDriverOptions = {}) {
    this.scenario = scenario;
    this.diagnosticsDir =
      options.diagnosticsDir ??
      optionalEnv('OPENPATH_STUDENT_DIAGNOSTICS_DIR') ??
      getDiagnosticsDir();
    this.extensionPath =
      options.extensionPath ?? optionalEnv('OPENPATH_EXTENSION_PATH') ?? DEFAULT_EXTENSION_PATH;
    this.firefoxBinaryPath = options.firefoxBinaryPath ?? optionalEnv('OPENPATH_FIREFOX_BINARY');
    this.headless = options.headless ?? normalizeBoolean(optionalEnv('CI'), true);
  }

  public async setup(): Promise<void> {
    await ensureDirectory(this.diagnosticsDir);

    const options = new firefox.Options();
    if (!shouldSkipBundledExtension()) {
      options.addExtensions(this.extensionPath);
    }
    if (this.firefoxBinaryPath !== undefined) {
      options.setBinary(this.firefoxBinaryPath);
    }
    options.setPreference('network.dns.disablePrefetch', true);
    options.setPreference('network.trr.mode', 5);
    options.setPreference('network.trr.uri', '');
    options.setPreference('network.dnsCacheExpiration', 0);
    options.setPreference('network.dnsCacheExpirationGracePeriod', 0);
    options.setPreference('dom.webnotifications.enabled', true);
    options.setPreference('xpinstall.signatures.required', false);
    options.setPreference('extensions.blocklist.enabled', false);
    options.setPreference('extensions.experiments.enabled', true);

    if (this.headless) {
      options.addArguments('-headless');
    }

    this.driver = await new Builder().forBrowser('firefox').setFirefoxOptions(options).build();
    await this.driver
      .manage()
      .setTimeouts({ implicit: 2_000, pageLoad: DEFAULT_BLOCKED_TIMEOUT_MS, script: 15_000 });

    const capabilities = await this.driver.getCapabilities();
    const profileDir = capabilities.get('moz:profile') as string | undefined;
    if (profileDir !== undefined && profileDir !== '') {
      this.extensionUuid = await discoverFirefoxExtensionUuid(profileDir);
      await waitForFirefoxExtensionRuntimeReady(this.driver, this.extensionUuid);
    }
  }

  public async teardown(): Promise<void> {
    if (this.driver !== null) {
      try {
        await this.driver.quit();
      } catch {
        // Best-effort cleanup. The browser process may already be gone.
      }
      this.driver = null;
    }
  }

  public async restart(): Promise<void> {
    await this.teardown();
    await this.setup();
  }

  public async ensureReady(): Promise<void> {
    if (this.driver === null) {
      await this.setup();
      return;
    }

    try {
      await this.driver.getTitle();
    } catch {
      this.driver = null;
      this.extensionUuid = null;
      await this.setup();
    }
  }

  public getDriver(): WebDriver {
    if (this.driver === null) {
      throw new Error('Firefox WebDriver is not initialized. Call setup() first.');
    }
    return this.driver;
  }

  public getExtensionUuid(): string {
    if (this.extensionUuid === null) {
      throw new Error('Extension UUID is not available; setup() must complete successfully first.');
    }
    return this.extensionUuid;
  }

  public async openAndExpectLoaded(options: OpenAndExpectLoadedOptions): Promise<void> {
    await this.withSessionRetry(async () => {
      await openAndExpectLoaded(this, options);
    });
  }

  public async openAndExpectBlocked(options: OpenAndExpectBlockedOptions): Promise<void> {
    await this.withSessionRetry(async () => {
      await openAndExpectBlocked(this, options);
    });
  }

  public async waitForBlockedScreen(expectation: BlockedScreenExpectation = {}): Promise<void> {
    await waitForBlockedScreen(this, expectation);
  }

  public async openAndExpectBlockedScreen(
    url: string,
    expectation: BlockedScreenExpectation = {}
  ): Promise<void> {
    await this.withSessionRetry(async () => {
      const driver = this.getDriver();
      let navigationTimedOut = false;
      try {
        await driver.get(url);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        if (!isBlockedNavigationError(message)) {
          throw error;
        }
        navigationTimedOut = isNavigationTimeout(message);
      }

      try {
        await this.waitForBlockedScreen(expectation);
      } catch (error) {
        if (!navigationTimedOut) {
          throw error;
        }

        await openBlockedScreenFallback(driver, this.getExtensionUuid(), url, expectation);
        await this.waitForBlockedScreen(expectation);
      }
    });
  }

  public async openBlockedScreenAndSubmitRequest(
    url: string,
    options: BlockedScreenRequestOptions
  ): Promise<string> {
    let statusText = '';
    await this.withSessionRetry(async () => {
      await this.openAndExpectBlockedScreen(url, { timeoutMs: options.timeoutMs });
      statusText = await submitBlockedScreenRequest(this, options);
    });
    return statusText;
  }

  public async waitForDomStatus(
    selector: string,
    expectedValue: string,
    options: ConvergenceOptions = {}
  ): Promise<void> {
    await waitForDomStatus(this, selector, expectedValue, options);
  }

  public async assertDnsBlocked(hostname: string): Promise<void> {
    await assertDnsBlocked(hostname);
  }

  public async assertDnsAllowed(hostname: string): Promise<void> {
    await assertDnsAllowed(hostname);
  }

  public async assertWhitelistContains(hostname: string): Promise<void> {
    await assertWhitelistContains(hostname);
  }

  public async waitForDnsAddress(
    hostname: string,
    expectedAddress = '127.0.0.1',
    timeoutMs = 90_000
  ): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    let lastError: unknown = null;
    for (;;) {
      try {
        const resolved = await dnsPromises.lookup(hostname, { all: true });
        if (resolved.some((entry) => entry.address === expectedAddress)) {
          return;
        }
        lastError = new Error(
          `resolved to ${resolved.map((entry) => entry.address).join(', ') || 'no addresses'}`
        );
      } catch (error) {
        lastError = error;
      }
      if (Date.now() >= deadline) {
        throw new Error(
          `DNS did not resolve ${hostname} to ${expectedAddress} within ${timeoutMs}ms: ${String(
            lastError
          )}`
        );
      }
      await new Promise((resolve) => {
        setTimeout(resolve, 2_000);
      });
    }
  }

  public async assertWhitelistMissing(hostname: string): Promise<void> {
    await assertWhitelistMissing(hostname);
  }

  public async refreshBlockedPathRules(): Promise<void> {
    await refreshBlockedPathRules(this);
  }

  public async refreshBlockedSubdomainRules(): Promise<void> {
    await refreshBlockedSubdomainRules(this);
  }

  public async forceLocalUpdate(): Promise<void> {
    await forceLocalUpdate();
  }

  public async withSseDisabled<T>(callback: () => Promise<T>): Promise<T> {
    return withSseDisabled(callback);
  }

  public async saveDiagnostics(name: string): Promise<void> {
    await saveDiagnostics(this, name);
  }

  public async find(selector: string): Promise<WebElement> {
    return this.getDriver().findElement(By.css(selector));
  }

  public async waitForConvergence(
    assertion: () => Promise<void>,
    options: ConvergenceOptions = {}
  ): Promise<void> {
    await waitForConvergence(assertion, options);
  }

  public async sendRuntimeMessage<T>(message: Record<string, unknown>): Promise<T> {
    return sendRuntimeMessage(this, message);
  }

  public async getActiveTabId(): Promise<number> {
    return getActiveTabId(this);
  }

  public async getDomainStatuses(): Promise<Record<string, DomainStatusPayload>> {
    return getDomainStatuses(this);
  }

  public async getBlockedPathRulesDebug(): Promise<{
    version: string;
    count: number;
    rawRules: string[];
    compiledPatterns: string[];
  }> {
    return getBlockedPathRulesDebug(this);
  }

  public async getNativeBlockedPathsDebug(): Promise<{
    success: boolean;
    count: number;
    paths: string[];
    source?: string;
    error?: string;
  }> {
    return getNativeBlockedPathsDebug(this);
  }

  public async evaluateBlockedPathDebug(url: string, type: string): Promise<unknown> {
    return evaluateBlockedPathDebug(this, url, type);
  }

  public async runCrossOriginFetchProbe(targetUrl: string): Promise<'ok' | 'blocked'> {
    return runCrossOriginFetchProbe(this, targetUrl);
  }

  public async runCrossOriginXhrProbe(targetUrl: string): Promise<'ok' | 'blocked'> {
    return runCrossOriginXhrProbe(this, targetUrl);
  }

  public async runCrossOriginElementProbe(
    targetUrl: string,
    probeType: CrossOriginElementProbeType
  ): Promise<'ok' | 'blocked'> {
    return runCrossOriginElementProbe(this, targetUrl, probeType);
  }

  public async rerunPortalSubdomainProbe(): Promise<void> {
    await rerunPortalSubdomainProbe(this);
  }

  public async rerunIframeProbe(): Promise<void> {
    await rerunIframeProbe(this);
  }

  public async rerunXhrProbe(): Promise<void> {
    await rerunXhrProbe(this);
  }

  public async rerunFetchProbe(): Promise<void> {
    await rerunFetchProbe(this);
  }

  public async assertHttpReachable(url: string): Promise<void> {
    await assertHttpReachable(url);
  }

  public async assertHttpBlocked(url: string): Promise<void> {
    await assertHttpBlocked(url);
  }

  private async withSessionRetry<T>(callback: () => Promise<T>): Promise<T> {
    try {
      return await callback();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!message.includes('NoSuchSession')) {
        throw error;
      }

      await this.restart();
      return callback();
    }
  }
}
