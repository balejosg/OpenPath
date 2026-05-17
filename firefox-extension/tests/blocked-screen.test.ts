import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import { setImmediate } from 'node:timers/promises';
import { test, describe } from 'node:test';

import { main } from '../src/blocked-page.js';

type MockRuntimeResponse =
  | Record<string, unknown>
  | ((message: unknown) => Record<string, unknown>);

type MockDataCollectionConsent = 'granted' | 'denied' | 'missing';
type PermissionEvent =
  | { type: 'contains' | 'request'; payload?: unknown }
  | { type: 'sendMessage'; message: unknown }
  | { type: 'sendNativeMessage'; hostName: string; message: unknown };

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
  runtimeApi:
    | 'browser-promise'
    | 'browser-promise-with-native'
    | 'browser-native-only'
    | 'chrome-callback'
    | 'browser-and-chrome' = 'browser-promise',
  sessionStorageStore = new Map<string, string>(),
  dataCollectionConsent: MockDataCollectionConsent = 'granted'
): {
  elements: Map<string, MockElement>;
  messages: unknown[];
  permissionEvents: PermissionEvent[];
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
  const permissionEvents: PermissionEvent[] = [];
  const permissionRequests: unknown[] = [];
  const runtimeApis: string[] = [];
  const resolveResponse = (message: unknown): unknown =>
    typeof response === 'function' ? response(message) : response;
  const permissions =
    dataCollectionConsent === 'missing'
      ? undefined
      : {
          contains: (): Promise<boolean> => {
            permissionEvents.push({ type: 'contains' });
            return Promise.resolve(dataCollectionConsent === 'granted');
          },
          request: (payload: unknown): Promise<boolean> => {
            permissionEvents.push({ type: 'request', payload });
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
                  permissionEvents.push({ type: 'sendMessage', message });
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
                  permissionEvents.push({ type: 'sendMessage', message });
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
                    permissionEvents.push({ type: 'sendMessage', message });
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
                  ...(runtimeApi === 'browser-promise-with-native' ||
                  runtimeApi === 'browser-native-only'
                    ? {
                        getManifest: (): { version: string } => ({ version: '2.0.0-test' }),
                        sendNativeMessage: (
                          hostName: string,
                          message: unknown
                        ): Promise<unknown> => {
                          permissionEvents.push({ type: 'sendNativeMessage', hostName, message });
                          return Promise.resolve(resolveResponse(message));
                        },
                      }
                    : {}),
                  ...(runtimeApi !== 'browser-native-only'
                    ? {
                        sendMessage: (message: unknown): Promise<unknown> => {
                          runtimeApis.push('browser');
                          permissionEvents.push({ type: 'sendMessage', message });
                          messages.push(message);
                          return Promise.resolve(resolveResponse(message));
                        },
                      }
                    : {}),
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

  return { elements, messages, permissionEvents, permissionRequests, runtimeApis };
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
  await Promise.resolve();
  await Promise.resolve();
  await setImmediate();
}

void describe('blocked screen', () => {
  void test('renders student-oriented unblock request affordance', () => {
    const html = readFileSync(new URL('../blocked/blocked.html', import.meta.url), 'utf8');

    assert.match(html, /Este sitio esta bloqueado por ahora/);
    assert.match(html, /Solicitar desbloqueo/);
    assert.match(html, /Ver detalles tecnicos/);
  });

  void test('submits unblock request through the background script without exposing a token', async () => {
    const { elements, messages, permissionEvents } = runBlockedScript({
      success: true,
      status: 'pending',
    });

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    const clickPromise = elements.get('submit-unblock-request')?.trigger('click');
    assert.deepStrictEqual(permissionEvents, [{ type: 'contains' }]);
    await Promise.resolve();
    assert.equal(messages.length, 0);
    await clickPromise;
    await flushBlockedScreenAsyncHandlers();

    assert.equal(permissionEvents[0]?.type, 'contains');
    assert.equal(permissionEvents[1]?.type, 'sendMessage');
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

    assert.deepStrictEqual(permissionRequests, []);
    assert.deepStrictEqual(messages, []);
    assert.match(
      elements.get('request-status')?.textContent ?? '',
      /permiso de actividad de navegacion requerido/
    );
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
    assert.match(elements.get('request-status')?.textContent ?? '', /no permite comprobar/);
  });

  void test('restores a recent submitted status after the blocked page reloads', async () => {
    const sessionStorageStore = new Map<string, string>();
    const search = '?domain=learning.example&error=NS_ERROR_UNKNOWN_HOST&origin=portal.example';
    const firstLoad = runBlockedScript(
      {
        success: true,
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

  void test('prefers direct native submission when native messaging is also exposed', async () => {
    const fetchCalls: { body: unknown; url: string }[] = [];
    Object.defineProperty(globalThis, 'fetch', {
      configurable: true,
      value: (url: string, init: { body?: string }): Promise<Response> => {
        fetchCalls.push({
          url,
          body: init.body ? JSON.parse(init.body) : null,
        });
        return Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'pending' }), {
            status: 200,
          })
        );
      },
    });

    const { elements, messages, permissionEvents, runtimeApis } = runBlockedScript(
      (message: unknown) => {
        const action = (message as { action?: string }).action;
        if (action === 'get-config') {
          return {
            success: true,
            requestApiUrl: 'https://classroompath.example/cp',
          };
        }
        if (action === 'get-hostname') {
          return { success: true, hostname: 'student-01' };
        }
        if (action === 'get-machine-token') {
          return { success: true, token: 'machine-token' };
        }

        return { success: false, error: `unexpected native action ${String(action)}` };
      },
      '?domain=learning.example&error=NS_ERROR_UNKNOWN_HOST&origin=portal.example',
      'browser-promise-with-native'
    );

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.deepStrictEqual(runtimeApis, []);
    assert.deepStrictEqual(messages, []);
    assert.deepStrictEqual(
      permissionEvents
        .filter((event) => event.type === 'sendNativeMessage')
        .map((event) => (event.message as { action?: string }).action),
      ['get-config', 'get-hostname', 'get-machine-token']
    );
    assert.equal(fetchCalls[0]?.url, 'https://classroompath.example/cp/api/requests/submit');
    assert.deepStrictEqual(fetchCalls[0]?.body, {
      client_version: '2.0.0-test',
      domain: 'learning.example',
      error_type: 'NS_ERROR_UNKNOWN_HOST',
      hostname: 'student-01',
      origin_host: 'portal.example',
      reason: 'Lo necesito para una actividad de clase',
      token: 'machine-token',
    });
    assert.match(elements.get('request-status')?.textContent ?? '', /Solicitud enviada/);
  });

  void test('falls back to direct native request submission when runtime messaging is absent', async () => {
    const fetchCalls: { body: unknown; url: string }[] = [];
    Object.defineProperty(globalThis, 'fetch', {
      configurable: true,
      value: (url: string, init: { body?: string }): Promise<Response> => {
        fetchCalls.push({
          url,
          body: init.body ? JSON.parse(init.body) : null,
        });
        return Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'pending' }), {
            status: 200,
          })
        );
      },
    });

    const { elements, permissionEvents, runtimeApis } = runBlockedScript(
      (message: unknown) => {
        const action = (message as { action?: string }).action;
        if (action === 'get-config') {
          return {
            success: true,
            requestApiUrl: 'https://classroompath.example/cp',
          };
        }
        if (action === 'get-hostname') {
          return { success: true, hostname: 'student-01' };
        }
        if (action === 'get-machine-token') {
          return { success: true, token: 'machine-token' };
        }

        return { success: false, error: `unexpected native action ${String(action)}` };
      },
      '?domain=learning.example&error=OPENPATH_NATIVE_POLICY_BLOCKED&origin=portal.example',
      'browser-native-only'
    );

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.deepStrictEqual(runtimeApis, []);
    assert.deepStrictEqual(
      permissionEvents
        .filter((event) => event.type === 'sendNativeMessage')
        .map((event) => (event.message as { action?: string }).action),
      ['get-config', 'get-hostname', 'get-machine-token']
    );
    assert.equal(fetchCalls[0]?.url, 'https://classroompath.example/cp/api/requests/submit');
    assert.deepStrictEqual(fetchCalls[0]?.body, {
      client_version: '2.0.0-test',
      domain: 'learning.example',
      error_type: 'OPENPATH_NATIVE_POLICY_BLOCKED',
      hostname: 'student-01',
      origin_host: 'portal.example',
      reason: 'Lo necesito para una actividad de clase',
      token: 'machine-token',
    });
    assert.match(elements.get('request-status')?.textContent ?? '', /Solicitud enviada/);
  });

  void test('shows a fallback when direct native request submission throws', async () => {
    Object.defineProperty(globalThis, 'fetch', {
      configurable: true,
      value: (): Promise<Response> => Promise.reject(new Error('submit network down')),
    });

    const { elements } = runBlockedScript(
      (message: unknown) => {
        const action = (message as { action?: string }).action;
        if (action === 'get-config') {
          return {
            success: true,
            requestApiUrl: 'https://classroompath.example/cp',
          };
        }
        if (action === 'get-hostname') {
          return { success: true, hostname: 'student-01' };
        }
        if (action === 'get-machine-token') {
          return { success: true, token: 'machine-token' };
        }

        return { success: false, error: `unexpected native action ${String(action)}` };
      },
      '?domain=learning.example&error=OPENPATH_NATIVE_POLICY_BLOCKED&origin=portal.example',
      'browser-native-only'
    );

    const reason = elements.get('request-reason');
    assert.ok(reason);
    reason.value = 'Lo necesito para una actividad de clase';

    await elements.get('submit-unblock-request')?.trigger('click');
    await flushBlockedScreenAsyncHandlers();

    assert.match(elements.get('request-status')?.textContent ?? '', /submit network down/);
    assert.match(elements.get('request-status')?.textContent ?? '', /avisa a tu profesor/);
  });

  void test('does not send display-only fallback text as request context', async () => {
    const { elements, messages } = runBlockedScript(
      {
        success: true,
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
