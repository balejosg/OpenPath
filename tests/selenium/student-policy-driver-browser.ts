import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert';

import { By, until, type WebElement } from 'selenium-webdriver';

import {
  DEFAULT_BLOCKED_TIMEOUT_MS,
  DEFAULT_TIMEOUT_MS,
  getPolicyMode,
} from './student-policy-env';
import type {
  BlockedScreenExpectation,
  BlockedScreenRequestOptions,
  ConvergenceOptions,
  OpenAndExpectBlockedOptions,
  OpenAndExpectLoadedOptions,
} from './student-policy-types';
import type { StudentPolicyDriverState } from './student-policy-driver-state';

async function readElementText(
  state: StudentPolicyDriverState,
  element: WebElement
): Promise<string> {
  const driver = state.getDriver();
  try {
    const textContent = await driver.executeScript<string>(
      'return arguments[0]?.textContent ?? "";',
      element
    );
    if (typeof textContent === 'string' && textContent.trim().length > 0) {
      return textContent.trim();
    }
  } catch {
    // Fall back to WebDriver's visible-text extraction below.
  }

  return (await element.getText()).trim();
}

function isStaleElementError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /\bstale\b|no longer connected to the DOM|node document is not the active document/i.test(
    message
  );
}

async function readBlockedPageDomDiagnostics(state: StudentPolicyDriverState): Promise<string> {
  const driver = state.getDriver();
  try {
    const snapshot = await driver.executeScript<Record<string, unknown>>(`
      const readText = (selector) => document.querySelector(selector)?.textContent?.trim() ?? null;
      const requestStatus = document.querySelector('#request-status');
      const reasonInput = document.querySelector('#request-reason');
      const submitButton = document.querySelector('#submit-unblock-request');
      const runtimeGlobal = globalThis;
      return {
        readyState: document.readyState,
        locationHref: window.location.href,
        bodyText: (document.body?.innerText ?? '').replace(/\\s+/g, ' ').trim().slice(0, 1000),
        blockedDomainText: readText('#blocked-domain'),
        blockedErrorText: readText('#blocked-error'),
        requestStatusTextContent: requestStatus?.textContent ?? null,
        requestStatusClass: requestStatus?.className ?? null,
        reasonValueLength: typeof reasonInput?.value === 'string' ? reasonInput.value.length : null,
        submitDisabled: typeof submitButton?.disabled === 'boolean' ? submitButton.disabled : null,
        hasChromeRuntime: typeof runtimeGlobal.chrome?.runtime?.sendMessage === 'function',
        hasBrowserRuntime: typeof runtimeGlobal.browser?.runtime?.sendMessage === 'function'
      };
    `);

    return JSON.stringify(snapshot);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return `<unavailable: ${message}>`;
  }
}

async function installBlockedPageSubmitDiagnostics(
  state: StudentPolicyDriverState
): Promise<string> {
  const driver = state.getDriver();
  try {
    const snapshot = await driver.executeScript<Record<string, unknown>>(`
      const root = window;
      const now = () => new Date().toISOString();
      const readRequestState = () => {
        const requestStatus = document.querySelector('#request-status');
        const reasonInput = document.querySelector('#request-reason');
        const submitButton = document.querySelector('#submit-unblock-request');
        return {
          readyState: document.readyState,
          locationHref: window.location.href,
          reasonValueLength: typeof reasonInput?.value === 'string' ? reasonInput.value.length : null,
          requestStatusTextContent: requestStatus?.textContent ?? null,
          requestStatusClass: requestStatus?.className ?? null,
          submitDisabled: typeof submitButton?.disabled === 'boolean' ? submitButton.disabled : null
        };
      };
      const probeKey = '__openpathBlockedPageSubmitProbe';
      const counterKey = '__openpathBlockedPageSubmitProbeCounter';
      if (!root[probeKey]) {
        root[counterKey] = (Number(root[counterKey]) || 0) + 1;
        const probe = {
          documentId: 'blocked-page-doc-' + String(root[counterKey]),
          installedAt: now(),
          events: [],
          browserRuntimeAvailable: typeof globalThis.browser?.runtime?.sendMessage === 'function',
          chromeRuntimeAvailable: typeof globalThis.chrome?.runtime?.sendMessage === 'function'
        };
        const push = (event) => {
          probe.events.push({ at: now(), ...event, state: readRequestState() });
          if (probe.events.length > 30) {
            probe.events.shift();
          }
        };
        const wrapRuntime = (namespaceName) => {
          const runtime = globalThis[namespaceName]?.runtime;
          if (typeof runtime?.sendMessage !== 'function' || runtime.sendMessage.__openpathSubmitProbeWrapped) {
            return;
          }
          const originalSendMessage = runtime.sendMessage.bind(runtime);
          const wrappedSendMessage = (...args) => {
            const message = args[0];
            push({
              type: namespaceName + '.runtime.sendMessage:start',
              action: message && typeof message === 'object' ? message.action ?? null : null,
              domain: message && typeof message === 'object' ? message.domain ?? null : null
            });
            const lastArg = args[args.length - 1];
            if (typeof lastArg === 'function') {
              const callback = lastArg;
              args[args.length - 1] = (response) => {
                push({
                  type: namespaceName + '.runtime.sendMessage:callback',
                  success: response && typeof response === 'object' ? response.success ?? null : null,
                  error: response && typeof response === 'object' ? response.error ?? null : null
                });
                callback(response);
              };
            }
            try {
              const result = originalSendMessage(...args);
              if (result && typeof result.then === 'function') {
                return result.then(
                  (response) => {
                    push({
                      type: namespaceName + '.runtime.sendMessage:resolve',
                      success: response && typeof response === 'object' ? response.success ?? null : null,
                      error: response && typeof response === 'object' ? response.error ?? null : null
                    });
                    return response;
                  },
                  (error) => {
                    push({
                      type: namespaceName + '.runtime.sendMessage:reject',
                      error: error instanceof Error ? error.message : String(error)
                    });
                    throw error;
                  }
                );
              }
              push({ type: namespaceName + '.runtime.sendMessage:return-sync' });
              return result;
            } catch (error) {
              push({
                type: namespaceName + '.runtime.sendMessage:throw',
                error: error instanceof Error ? error.message : String(error)
              });
              throw error;
            }
          };
          Object.defineProperty(wrappedSendMessage, '__openpathSubmitProbeWrapped', {
            value: true
          });
          runtime.sendMessage = wrappedSendMessage;
        };
        ['pagehide', 'pageshow', 'beforeunload'].forEach((type) => {
          window.addEventListener(type, (event) => {
            push({
              type,
              persisted: typeof event.persisted === 'boolean' ? event.persisted : null
            });
          });
        });
        wrapRuntime('browser');
        wrapRuntime('chrome');
        root[probeKey] = probe;
        push({ type: 'probe-installed' });
      }
      root[probeKey].lastReadAt = now();
      root[probeKey].lastState = readRequestState();
      return root[probeKey];
    `);

    return JSON.stringify(snapshot);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return `<unavailable: ${message}>`;
  }
}

async function readBlockedPageSubmitDiagnostics(state: StudentPolicyDriverState): Promise<string> {
  const driver = state.getDriver();
  try {
    const snapshot = await driver.executeScript<Record<string, unknown>>(`
      const probe = window.__openpathBlockedPageSubmitProbe ?? null;
      const requestStatus = document.querySelector('#request-status');
      const reasonInput = document.querySelector('#request-reason');
      const submitButton = document.querySelector('#submit-unblock-request');
      return {
        ...(probe ?? { installed: false }),
        currentState: {
          readyState: document.readyState,
          locationHref: window.location.href,
          reasonValueLength: typeof reasonInput?.value === 'string' ? reasonInput.value.length : null,
          requestStatusTextContent: requestStatus?.textContent ?? null,
          requestStatusClass: requestStatus?.className ?? null,
          submitDisabled: typeof submitButton?.disabled === 'boolean' ? submitButton.disabled : null,
          browserRuntimeAvailable: typeof globalThis.browser?.runtime?.sendMessage === 'function',
          chromeRuntimeAvailable: typeof globalThis.chrome?.runtime?.sendMessage === 'function'
        }
      };
    `);

    return JSON.stringify(snapshot);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return `<unavailable: ${message}>`;
  }
}

async function grantBlockedPageDataCollectionConsentForSelenium(
  state: StudentPolicyDriverState
): Promise<void> {
  const driver = state.getDriver();
  try {
    await driver.executeScript(`
      if (navigator.webdriver !== true) {
        return { patched: false, reason: 'not-webdriver' };
      }
      const patchPermissions = (namespaceName) => {
        const permissions = globalThis[namespaceName]?.permissions;
        if (!permissions || permissions.__openpathSeleniumConsentPatched) {
          return false;
        }
        const grant = () => Promise.resolve(true);
        permissions.contains = grant;
        permissions.request = grant;
        Object.defineProperty(permissions, '__openpathSeleniumConsentPatched', {
          configurable: true,
          value: true
        });
        return true;
      };
      return {
        browser: patchPermissions('browser'),
        chrome: patchPermissions('chrome')
      };
    `);
  } catch {
    // Older unit fakes do not implement executeScript; real Selenium diagnostics
    // below still capture blocked-page state if consent is not patchable.
  }
}

export async function openAndExpectLoaded(
  state: StudentPolicyDriverState,
  options: OpenAndExpectLoadedOptions
): Promise<void> {
  const driver = state.getDriver();
  await driver.get(options.url);

  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  if (options.title !== undefined) {
    await driver.wait(until.titleContains(options.title), timeoutMs);
  }

  if (options.selector !== undefined) {
    await driver.wait(until.elementLocated(By.css(options.selector)), timeoutMs);
  }
}

export async function openAndExpectBlocked(
  state: StudentPolicyDriverState,
  options: OpenAndExpectBlockedOptions
): Promise<void> {
  const driver = state.getDriver();
  const timeoutMs = options.timeoutMs ?? DEFAULT_BLOCKED_TIMEOUT_MS;
  try {
    await driver.get(options.url);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (
      message.includes('about:neterror') ||
      message.includes('dnsNotFound') ||
      message.includes('NS_ERROR_UNKNOWN_HOST') ||
      message.includes('Reached error page') ||
      message.includes('Navigation timed out')
    ) {
      return;
    }
    throw error;
  }

  if (options.forbiddenSelector !== undefined) {
    const found = await driver.wait(
      async () => {
        const elements = await driver.findElements(By.css(options.forbiddenSelector ?? 'body'));
        return elements.length === 0;
      },
      timeoutMs,
      `Expected selector ${options.forbiddenSelector} to remain absent for blocked page`
    );
    assert.strictEqual(found, true);
    return;
  }

  if (options.forbiddenText !== undefined) {
    const body = await driver.findElement(By.css('body'));
    const bodyText = await body.getText();
    assert.ok(!bodyText.includes(options.forbiddenText));
    return;
  }

  const pageSource = await driver.getPageSource();
  assert.ok(
    !pageSource.includes('id="page-status">ok<') && !pageSource.includes('OpenPath Portal Fixture'),
    'Blocked navigation unexpectedly rendered the success markers'
  );
}

export async function waitForBlockedScreen(
  state: StudentPolicyDriverState,
  expectation: BlockedScreenExpectation = {}
): Promise<void> {
  const driver = state.getDriver();
  const timeoutMs = expectation.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  await driver.wait(async () => {
    const currentUrl = await driver.getCurrentUrl();
    const title = await driver.getTitle();
    return (
      currentUrl.includes('/blocked/blocked.html') ||
      currentUrl.includes('about:neterror?e=blockedByPolicy') ||
      title.includes('Blocked Page')
    );
  }, timeoutMs);

  const currentUrl = await driver.getCurrentUrl();
  if (currentUrl.includes('/blocked/blocked.html') && expectation.reasonPrefix !== undefined) {
    const url = new URL(currentUrl);
    const errorValue = url.searchParams.get('error') ?? '';
    assert.ok(
      errorValue.startsWith(expectation.reasonPrefix),
      `Expected blocked-screen error to start with ${expectation.reasonPrefix}, received ${errorValue}`
    );
  }
}

export async function submitBlockedScreenRequest(
  state: StudentPolicyDriverState,
  options: BlockedScreenRequestOptions
): Promise<string> {
  const driver = state.getDriver();
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const reasonInput = await driver.findElement(By.css('#request-reason'));
  const submitButton = await driver.findElement(By.css('#submit-unblock-request'));

  await reasonInput.clear();
  await reasonInput.sendKeys(options.reason);
  await grantBlockedPageDataCollectionConsentForSelenium(state);
  let submitDiagnostics = await installBlockedPageSubmitDiagnostics(state);
  await submitButton.click();

  let latestStatus = '';
  try {
    await driver.wait(async () => {
      try {
        const statusElement = await driver.findElement(By.css('#request-status'));
        latestStatus = await readElementText(state, statusElement);
        return /Solicitud enviada|Request submitted/i.test(latestStatus);
      } catch (error) {
        if (isStaleElementError(error)) {
          return false;
        }
        throw error;
      }
    }, timeoutMs);
  } catch (error) {
    const currentUrl = await driver.getCurrentUrl().catch(() => '<unavailable>');
    const title = await driver.getTitle().catch(() => '<unavailable>');
    const domDiagnostics = await readBlockedPageDomDiagnostics(state);
    submitDiagnostics = await readBlockedPageSubmitDiagnostics(state);
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(
      [
        message,
        `latest #request-status: ${latestStatus || '<empty>'}`,
        `currentUrl: ${currentUrl}`,
        `title: ${title}`,
        `blocked page DOM: ${domDiagnostics}`,
        `blocked page submit diagnostics: ${submitDiagnostics}`,
      ].join('; ')
    );
  }

  return latestStatus;
}

export async function waitForDomStatus(
  state: StudentPolicyDriverState,
  selector: string,
  expectedValue: string,
  options: ConvergenceOptions = {}
): Promise<void> {
  const driver = state.getDriver();
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  const element = await driver.wait(until.elementLocated(By.css(selector)), timeoutMs);
  await driver.wait(async () => {
    const text = (await element.getText()).trim();
    return text === expectedValue;
  }, timeoutMs);
}

export async function saveDiagnostics(
  state: StudentPolicyDriverState,
  name: string
): Promise<void> {
  const driver = state.getDriver();
  const screenshotPath = path.join(state.diagnosticsDir, `${name}.png`);
  const htmlPath = path.join(state.diagnosticsDir, `${name}.html`);
  const jsonPath = path.join(state.diagnosticsDir, `${name}.json`);
  const screenshot = await driver.takeScreenshot();
  await fs.writeFile(screenshotPath, screenshot, 'base64');
  await fs.writeFile(htmlPath, await driver.getPageSource(), 'utf8');
  await fs.writeFile(
    jsonPath,
    JSON.stringify(
      {
        currentUrl: await driver.getCurrentUrl(),
        title: await driver.getTitle(),
        mode: getPolicyMode(),
      },
      null,
      2
    ),
    'utf8'
  );
}
