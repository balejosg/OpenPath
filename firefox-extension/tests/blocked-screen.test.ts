import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import { test, describe } from 'node:test';

import { main } from '../src/blocked-page.js';

type MockRuntimeResponse =
  | Record<string, unknown>
  | ((message: unknown) => Record<string, unknown>);

type MockDataCollectionConsent = 'granted' | 'denied' | 'missing';

class MockElement {
  className = '';
  disabled = false;
  textContent = '';
  value = '';

  private readonly listeners = new Map<string, (() => unknown)[]>();

  readonly classList = {
    add: (...classes: string[]): void => {
      const current = new Set(this.className.split(/\s+/).filter(Boolean));
      classes.forEach((className) => current.add(className));
      this.className = Array.from(current).join(' ');
    },
    remove: (...classes: string[]): void => {
      const current = new Set(this.className.split(/\s+/).filter(Boolean));
      classes.forEach((className) => current.delete(className));
      this.className = Array.from(current).join(' ');
    },
  };

  addEventListener(type: string, listener: () => unknown): void {
    const listeners = this.listeners.get(type) ?? [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  async trigger(type: string): Promise<void> {
    const listeners = this.listeners.get(type) ?? [];
    for (const listener of listeners) {
      await Promise.resolve(listener());
    }
  }
}

function normalizeMessages(messages: unknown[]): Record<string, unknown>[] {
  return messages.map((message) => {
    const record = message as Record<string, unknown>;
    return {
      action: record.action,
      domain: record.domain,
      reason: record.reason,
      origin: record.origin,
      error: record.error,
    };
  });
}

function runBlockedScript(
  response: MockRuntimeResponse,
  search = '?domain=learning.example&error=NS_ERROR_UNKNOWN_HOST&origin=portal.example',
  runtimeApi: 'browser-promise' | 'chrome-callback' | 'browser-and-chrome' = 'browser-promise',
  sessionStorageStore = new Map<string, string>(),
  dataCollectionConsent: MockDataCollectionConsent = 'granted'
): {
  elements: Map<string, MockElement>;
  messages: unknown[];
  permissionRequests: unknown[];
  runtimeApis: string[];
} {
  clearBlockedScreenGlobals();

  const ids = [
    'blocked-domain',
    'blocked-error',
    'blocked-origin',
    'copy-feedback',
    'go-back',
    'copy-domain',
    'request-reason',
    'submit-unblock-request',
    'request-status',
  ];
  const elements = new Map(ids.map((id) => [id, new MockElement()]));
  const messages: unknown[] = [];
  const permissionRequests: unknown[] = [];
  const runtimeApis: string[] = [];
  const resolveResponse = (message: unknown): unknown =>
    typeof response === 'function' ? response(message) : response;
  const permissions =
    dataCollectionConsent === 'missing'
      ? undefined
      : {
          contains: (): Promise<boolean> => Promise.resolve(dataCollectionConsent === 'granted'),
          request: (payload: unknown): Promise<boolean> => {
            permissionRequests.push(payload);
            return Promise.resolve(dataCollectionConsent === 'granted');
          },
        };

  const runtimeGlobals =
    runtimeApi === 'browser-and-chrome'
      ? {
          browser: {
            configurable: true,
            value: {
              runtime: {
                sendMessage: (message: unknown): Promise<unknown> => {
                  runtimeApis.push('browser');
                  messages.push(message);
                  return Promise.resolve(resolveResponse(message));
                },
              },
              ...(permissions ? { permissions } : {}),
            },
          },
          chrome: {
            configurable: true,
            value: {
              runtime: {
                lastError: null,
                sendMessage: (message: unknown): void => {
                  runtimeApis.push('chrome');
                  messages.push(message);
                },
              },
            },
          },
        }
      : runtimeApi === 'chrome-callback'
        ? {
            ...(permissions
              ? {
                  browser: {
                    configurable: true,
                    value: {
                      permissions,
                    },
                  },
                }
              : {}),
            chrome: {
              configurable: true,
              value: {
                runtime: {
                  lastError: null,
                  sendMessage: (
                    message: unknown,
                    callback: ((response: unknown) => void) | undefined
                  ): void => {
                    runtimeApis.push('chrome');
                    messages.push(message);
                    callback?.(resolveResponse(message));
                  },
                },
              },
            },
          }
        : {
            browser: {
              configurable: true,
              value: {
                runtime: {
                  sendMessage: (message: unknown): Promise<unknown> => {
                    runtimeApis.push('browser');
                    messages.push(message);
                    return Promise.resolve(resolveResponse(message));
                  },
                },
                ...(permissions ? { permissions } : {}),
              },
            },
          };

  Object.defineProperties(globalThis, {
    ...runtimeGlobals,
    document: {
      configurable: true,
      value: {
        getElementById: (id: string): MockElement | null => elements.get(id) ?? null,
      },
    },
    navigator: {
      configurable: true,
      value: {
        clipboard: {
          writeText: (): Promise<void> => Promise.resolve(),
        },
      },
    },
    window: {
      configurable: true,
      value: {
        history: { length: 1, back: (): void => undefined },
        location: {
          replace: (): void => undefined,
          search,
        },
        sessionStorage: {
          getItem: (key: string): string | null => sessionStorageStore.get(key) ?? null,
          removeItem: (key: string): void => {
            sessionStorageStore.delete(key);
          },
          setItem: (key: string, value: string): void => {
            sessionStorageStore.set(key, value);
          },
        },
      },
    },
  });

  main();

  return { elements, messages, permissionRequests, runtimeApis };
}

function clearBlockedScreenGlobals(): void {
  const globalRecord = globalThis as {
    browser?: unknown;
    chrome?: unknown;
    document?: unknown;
    navigator?: unknown;
    window?: unknown;
  };

  delete globalRecord.browser;
  delete globalRecord.chrome;
  delete globalRecord.document;
  delete globalRecord.navigator;
  delete globalRecord.window;
}

async function flushBlockedScreenAsyncHandlers(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

void describe('blocked screen', () => {
  void test('renders student-oriented unblock request affordance', () => {
    const html = readFileSync(new URL('../blocked/blocked.html', import.meta.url), 'utf8');

    assert.match(html, /Este sitio esta bloqueado por ahora/);
    assert.match(html, /Solicitar desbloqueo/);
    assert.match(html, /Ver detalles tecnicos/);
  });

  void test('submits unblock request through the background script without exposing a token', async () => {
    const { elements, messages } = runBlockedScript({
      success: true,
      id: 'req_123',
      status: 'pending',
    });

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.deepStrictEqual(normalizeMessages(messages), [
      {
        action: 'submitBlockedDomainRequest',
        domain: 'learning.example',
        reason: 'Lo necesito para una actividad de clase',
        origin: 'portal.example',
        error: 'NS_ERROR_UNKNOWN_HOST',
      },
    ]);
    assert.match(elements.get('request-status')?.textContent ?? '', /Solicitud enviada/);
  });

  void test('does not submit unblock requests when browsing activity consent is denied', async () => {
    const { elements, messages, permissionRequests } = runBlockedScript(
      {
        success: true,
        id: 'req_129',
        status: 'pending',
      },
      '?domain=learning.example&error=NS_ERROR_UNKNOWN_HOST&origin=portal.example',
      'browser-promise',
      new Map<string, string>(),
      'denied'
    );

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.deepStrictEqual(permissionRequests, [{ data_collection: ['browsingActivity'] }]);
    assert.deepStrictEqual(messages, []);
    assert.match(elements.get('request-status')?.textContent ?? '', /actividad de navegacion/);
  });

  void test('does not submit unblock requests when Firefox lacks data collection consent support', async () => {
    const { elements, messages } = runBlockedScript(
      {
        success: true,
        id: 'req_130',
        status: 'pending',
      },
      '?domain=learning.example&error=NS_ERROR_UNKNOWN_HOST&origin=portal.example',
      'browser-promise',
      new Map<string, string>(),
      'missing'
    );

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.deepStrictEqual(messages, []);
    assert.match(elements.get('request-status')?.textContent ?? '', /no es compatible/);
  });

  void test('restores a recent submitted status after the blocked page reloads', async () => {
    const sessionStorageStore = new Map<string, string>();
    const search = '?domain=learning.example&error=NS_ERROR_UNKNOWN_HOST&origin=portal.example';
    const firstLoad = runBlockedScript(
      {
        success: true,
        id: 'req_126',
        status: 'pending',
      },
      search,
      'browser-promise',
      sessionStorageStore
    );

    const reason = firstLoad.elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await firstLoad.elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();
    assert.match(firstLoad.elements.get('request-status')?.textContent ?? '', /Solicitud enviada/);

    const secondLoad = runBlockedScript(
      {
        success: false,
        error: 'should not submit again',
      },
      search,
      'browser-promise',
      sessionStorageStore
    );

    assert.deepStrictEqual(secondLoad.messages, []);
    assert.match(secondLoad.elements.get('request-status')?.textContent ?? '', /Solicitud enviada/);
  });

  void test('restores a recent submitted status from the background after document replacement', async () => {
    const { elements, messages } = runBlockedScript((message: unknown) => {
      const action = (message as { action?: string }).action;
      if (action === 'getRecentBlockedDomainRequestStatus') {
        return {
          success: true,
          request: {
            success: true,
            id: 'req_128',
            status: 'pending',
            domain: 'learning.example',
          },
        };
      }

      return { success: false, error: 'should not submit again' };
    }, '?domain=learning.example&error=OPENPATH_NATIVE_POLICY_BLOCKED&origin=portal.example');

    await flushBlockedScreenAsyncHandlers();

    assert.deepStrictEqual(normalizeMessages(messages), [
      {
        action: 'getRecentBlockedDomainRequestStatus',
        domain: 'learning.example',
        reason: undefined,
        origin: undefined,
        error: undefined,
      },
    ]);
    assert.match(elements.get('request-status')?.textContent ?? '', /Solicitud enviada/);
  });

  void test('uses callback runtime messaging when the blocked page runs on the chrome namespace', async () => {
    const { elements, messages, runtimeApis } = runBlockedScript(
      {
        success: true,
        id: 'req_125',
        status: 'pending',
      },
      '?domain=learning.example&error=NS_ERROR_UNKNOWN_HOST&origin=portal.example',
      'chrome-callback'
    );

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.deepStrictEqual(runtimeApis, ['chrome']);
    assert.deepStrictEqual(normalizeMessages(messages), [
      {
        action: 'submitBlockedDomainRequest',
        domain: 'learning.example',
        reason: 'Lo necesito para una actividad de clase',
        origin: 'portal.example',
        error: 'NS_ERROR_UNKNOWN_HOST',
      },
    ]);
    assert.match(elements.get('request-status')?.textContent ?? '', /Solicitud enviada/);
  });

  void test('prefers browser promise messaging when both Firefox runtime aliases exist', async () => {
    const { elements, runtimeApis } = runBlockedScript(
      {
        success: true,
        id: 'req_127',
        status: 'pending',
      },
      '?domain=learning.example&error=NS_ERROR_UNKNOWN_HOST&origin=portal.example',
      'browser-and-chrome'
    );

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.deepStrictEqual(runtimeApis, ['browser']);
    assert.match(elements.get('request-status')?.textContent ?? '', /Solicitud enviada/);
  });

  void test('does not send display-only fallback text as request context', async () => {
    const { elements, messages } = runBlockedScript(
      {
        success: true,
        id: 'req_124',
        status: 'pending',
      },
      '?blockedUrl=https%3A%2F%2Flearning.example%2Flesson&error=NS_ERROR_UNKNOWN_HOST'
    );

    assert.equal(elements.get('blocked-origin')?.textContent, 'sin informacion');

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.deepStrictEqual(normalizeMessages(messages), [
      {
        action: 'submitBlockedDomainRequest',
        domain: 'learning.example',
        reason: 'Lo necesito para una actividad de clase',
        origin: undefined,
        error: 'NS_ERROR_UNKNOWN_HOST',
      },
    ]);
  });

  void test('shows a teacher fallback when request submission is unavailable', async () => {
    const { elements } = runBlockedScript({
      success: false,
      error: 'Configuracion incompleta para solicitar dominios',
    });

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.match(elements.get('request-status')?.textContent ?? '', /avisa a tu profesor/);
  });
});
