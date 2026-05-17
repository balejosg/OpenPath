import assert from 'node:assert';
import { describe, test } from 'node:test';

import { main } from '../src/blocked-page.js';

class MockElement {
  textContent = '';
  value = '';
  disabled = false;
  readonly classes = new Set<string>();
  private readonly listeners = new Map<string, (() => void)[]>();

  readonly classList = {
    add: (className: string): void => {
      this.classes.add(className);
    },
    remove: (...classNames: string[]): void => {
      for (const className of classNames) {
        this.classes.delete(className);
      }
    },
  };

  addEventListener(event: string, listener: () => void): void {
    const listeners = this.listeners.get(event) ?? [];
    listeners.push(listener);
    this.listeners.set(event, listeners);
  }

  click(): void {
    for (const listener of this.listeners.get('click') ?? []) {
      listener();
    }
  }
}

function waitForAsyncHandlers(): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
}

async function waitUntil(predicate: () => boolean, timeoutMs = 200): Promise<void> {
  const expiresAt = Date.now() + timeoutMs;
  do {
    if (predicate()) {
      return;
    }
    await waitForAsyncHandlers();
  } while (Date.now() < expiresAt);

  throw new Error('Timed out waiting for blocked page async handlers');
}

function clearBlockedPageGlobals(): void {
  const globalRecord = globalThis as {
    document?: unknown;
    navigator?: unknown;
    window?: unknown;
  };

  delete globalRecord.document;
  delete globalRecord.navigator;
  delete globalRecord.window;
}

void describe('blocked page entrypoint', () => {
  void test('renders display context from the blocked page query string', () => {
    clearBlockedPageGlobals();

    const elements = new Map(
      [
        'blocked-domain',
        'blocked-error',
        'blocked-origin',
        'go-back',
        'copy-domain',
        'request-reason',
        'submit-unblock-request',
      ].map((id) => [id, new MockElement()])
    );

    Object.defineProperties(globalThis, {
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
            search:
              '?blockedUrl=https%3A%2F%2Flearning.example%2Flesson&error=NS_ERROR_UNKNOWN_HOST',
          },
        },
      },
    });

    main();

    assert.equal(elements.get('blocked-domain')?.textContent, 'learning.example');
    assert.equal(elements.get('blocked-error')?.textContent, 'NS_ERROR_UNKNOWN_HOST');
    assert.equal(elements.get('blocked-origin')?.textContent, 'sin informacion');
  });

  void test('submits unblock requests directly through native messaging when available', async () => {
    clearBlockedPageGlobals();

    const elements = new Map(
      [
        'blocked-domain',
        'blocked-error',
        'blocked-origin',
        'copy-feedback',
        'go-back',
        'copy-domain',
        'request-reason',
        'request-status',
        'submit-unblock-request',
      ].map((id) => [id, new MockElement()])
    );
    const reasonInput = elements.get('request-reason');
    if (!reasonInput) {
      throw new Error('request-reason fixture missing');
    }
    reasonInput.value = 'needed for class';

    const nativeMessages: unknown[] = [];
    const runtimeMessages: unknown[] = [];
    const fetchBodies: unknown[] = [];
    const navigations: string[] = [];
    const originalFetch = globalThis.fetch;

    Object.defineProperties(globalThis, {
      browser: {
        configurable: true,
        value: {
          permissions: {
            contains: () => Promise.resolve(true),
          },
          runtime: {
            getManifest: () => ({ version: '2.0.0-test' }),
            sendMessage: (message: unknown) => {
              runtimeMessages.push(message);
              const action = (message as { action?: string }).action;
              if (action === 'getBlockedPageContext') {
                return Promise.resolve({
                  success: true,
                  context: {
                    originalUrl: 'https://blocked.example/lesson?x=1',
                  },
                });
              }
              if (action === 'verifyDomains') {
                return Promise.resolve({
                  success: true,
                  results: [{ domain: 'blocked.example', inWhitelist: true }],
                });
              }
              return Promise.resolve({ success: true });
            },
            sendNativeMessage: (_hostName: string, message: unknown) => {
              nativeMessages.push(message);
              const action = (message as { action?: string }).action;
              if (action === 'get-config') {
                return Promise.resolve({
                  success: true,
                  requestApiUrl: 'https://api.example',
                  fallbackApiUrls: [],
                  enableRequests: true,
                });
              }
              if (action === 'get-hostname') {
                return Promise.resolve({ success: true, hostname: 'lab-pc-01' });
              }
              if (action === 'get-machine-token') {
                return Promise.resolve({ success: true, token: 'machine-token' });
              }
              return Promise.resolve({ success: true });
            },
          },
        },
      },
      document: {
        configurable: true,
        value: {
          getElementById: (id: string): MockElement | null => elements.get(id) ?? null,
        },
      },
      fetch: {
        configurable: true,
        value: (url: string, init?: RequestInit) => {
          if (url.endsWith('/api/requests/status/request-1')) {
            return Promise.resolve(
              new Response(
                JSON.stringify({ success: true, status: 'approved', domain: 'blocked.example' }),
                {
                  status: 200,
                  headers: { 'Content-Type': 'application/json' },
                }
              )
            );
          }

          fetchBodies.push(typeof init?.body === 'string' ? JSON.parse(init.body) : {});
          return Promise.resolve(
            new Response(JSON.stringify({ success: true, id: 'request-1', status: 'pending' }), {
              status: 200,
              headers: { 'Content-Type': 'application/json' },
            })
          );
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
            replace: (url: string): void => {
              navigations.push(url);
            },
            search:
              '?domain=blocked.example&origin=https%3A%2F%2Flesson.example%2F&error=WINDOWS_CANARY',
          },
          sessionStorage: {
            getItem: () => null,
            removeItem: () => undefined,
            setItem: () => undefined,
          },
          setTimeout,
        },
      },
    });

    try {
      main();
      elements.get('submit-unblock-request')?.click();
      await waitUntil(() => navigations.length > 0);

      assert.deepEqual(
        runtimeMessages.map((message) => (message as { action?: string }).action),
        ['getBlockedPageContext', 'triggerWhitelistUpdate', 'verifyDomains']
      );
      assert.deepEqual(
        runtimeMessages.find(
          (message) => (message as { action?: string }).action === 'triggerWhitelistUpdate'
        ),
        { action: 'triggerWhitelistUpdate', domains: ['blocked.example'] }
      );
      assert.ok(
        nativeMessages.some((message) => (message as { action?: string }).action === 'get-config')
      );
      assert.deepEqual(fetchBodies, [
        {
          client_version: '2.0.0-test',
          domain: 'blocked.example',
          error_type: 'WINDOWS_CANARY',
          hostname: 'lab-pc-01',
          origin_host: 'https://lesson.example/',
          reason: 'needed for class',
          token: 'machine-token',
        },
      ]);
      assert.match(elements.get('request-status')?.textContent ?? '', /Solicitud enviada/);
      assert.deepEqual(navigations, ['https://blocked.example/lesson?x=1']);
    } finally {
      Object.defineProperty(globalThis, 'fetch', {
        configurable: true,
        value: originalFetch,
      });
    }
  });

  void test('keeps visible rejection state without navigation', async () => {
    clearBlockedPageGlobals();

    const { elements, navigations } = installSubmitFixture({
      statusPayloads: [{ success: true, status: 'rejected', domain: 'blocked.example' }],
    });

    main();
    elements.get('submit-unblock-request')?.click();
    await waitUntil(() =>
      (elements.get('request-status')?.textContent ?? '').includes('rechazada')
    );

    assert.deepEqual(navigations, []);
    assert.ok(elements.get('request-status')?.classes.has('error'));
  });

  void test('preserves pending submissions without an id as sent state', async () => {
    clearBlockedPageGlobals();

    const { elements, fetchUrls, navigations } = installSubmitFixture({
      submitPayload: { success: true, status: 'pending' },
    });

    main();
    elements.get('submit-unblock-request')?.click();
    await waitUntil(() =>
      (elements.get('request-status')?.textContent ?? '').includes('Quedara pendiente')
    );

    assert.deepEqual(fetchUrls, []);
    assert.deepEqual(navigations, []);
    assert.ok(elements.get('request-status')?.classes.has('success'));
  });

  void test('keeps visible pending timeout state without navigation', async () => {
    clearBlockedPageGlobals();

    const originalDateNow = Date.now;
    let now = 1_000;
    Date.now = (): number => {
      now += 31_000;
      return now;
    };

    try {
      const { elements, navigations } = installSubmitFixture({
        statusPayloads: [{ success: true, status: 'pending', domain: 'blocked.example' }],
      });

      main();
      elements.get('submit-unblock-request')?.click();
      for (let i = 0; i < 5; i += 1) {
        await waitForAsyncHandlers();
      }

      assert.deepEqual(navigations, []);
      assert.match(elements.get('request-status')?.textContent ?? '', /sigue pendiente/);
      assert.ok(elements.get('request-status')?.classes.has('pending'));
    } finally {
      Date.now = originalDateNow;
    }
  });

  void test('keeps visible local verify failure without navigation', async () => {
    clearBlockedPageGlobals();

    const { elements, navigations } = installSubmitFixture({
      verifyResponse: {
        success: true,
        results: [{ domain: 'blocked.example', inWhitelist: false }],
      },
      statusPayloads: [{ success: true, status: 'approved', domain: 'blocked.example' }],
    });

    main();
    elements.get('submit-unblock-request')?.click();
    await waitUntil(() =>
      (elements.get('request-status')?.textContent ?? '').includes('aun no permite')
    );

    assert.deepEqual(navigations, []);
    assert.ok(elements.get('request-status')?.classes.has('error'));
  });

  void test('updates the local whitelist for the approved root domain before reloading', async () => {
    clearBlockedPageGlobals();

    const { elements, navigations, runtimeMessages } = installSubmitFixture({
      blockedDomain: 'es.wikipedia.org',
      originalUrl: 'https://es.wikipedia.org/wiki/Aula',
      statusPayloads: [{ success: true, status: 'approved', domain: 'wikipedia.org' }],
      verifyResponse: {
        success: true,
        results: [
          { domain: 'es.wikipedia.org', inWhitelist: false },
          { domain: 'wikipedia.org', inWhitelist: true },
        ],
      },
    });

    main();
    elements.get('submit-unblock-request')?.click();
    await waitUntil(() => navigations.length > 0);

    assert.deepEqual(
      runtimeMessages.find(
        (message) => (message as { action?: string }).action === 'triggerWhitelistUpdate'
      ),
      { action: 'triggerWhitelistUpdate', domains: ['wikipedia.org'] }
    );
    assert.deepEqual(
      runtimeMessages.find(
        (message) => (message as { action?: string }).action === 'verifyDomains'
      ),
      { action: 'verifyDomains', domains: ['es.wikipedia.org', 'wikipedia.org'] }
    );
    assert.deepEqual(navigations, ['https://es.wikipedia.org/wiki/Aula']);
  });
});

function installSubmitFixture(options: {
  blockedDomain?: string;
  originalUrl?: string;
  submitPayload?: unknown;
  statusPayloads?: unknown[];
  verifyResponse?: unknown;
}): {
  elements: Map<string, MockElement>;
  fetchUrls: string[];
  navigations: string[];
  runtimeMessages: unknown[];
} {
  const blockedDomain = options.blockedDomain ?? 'blocked.example';
  const originalUrl = options.originalUrl ?? `https://${blockedDomain}/lesson`;
  const elements = new Map(
    [
      'blocked-domain',
      'blocked-error',
      'blocked-origin',
      'copy-feedback',
      'go-back',
      'copy-domain',
      'request-reason',
      'request-status',
      'submit-unblock-request',
    ].map((id) => [id, new MockElement()])
  );
  const reasonInput = elements.get('request-reason');
  if (!reasonInput) {
    throw new Error('request-reason fixture missing');
  }
  reasonInput.value = 'needed for class';

  const fetchUrls: string[] = [];
  const navigations: string[] = [];
  const runtimeMessages: unknown[] = [];
  const statusPayloads = [...(options.statusPayloads ?? [])];

  Object.defineProperties(globalThis, {
    browser: {
      configurable: true,
      value: {
        permissions: {
          contains: () => Promise.resolve(true),
        },
        runtime: {
          sendMessage: (message: unknown) => {
            runtimeMessages.push(message);
            const action = (message as { action?: string }).action;
            if (action === 'submitBlockedDomainRequest') {
              return Promise.resolve(
                options.submitPayload ?? {
                  success: true,
                  id: 'request-1',
                  status: 'pending',
                  domain: blockedDomain,
                }
              );
            }
            if (action === 'getBlockedPageContext') {
              return Promise.resolve({
                success: true,
                context: { originalUrl },
              });
            }
            if (action === 'verifyDomains') {
              return Promise.resolve(
                options.verifyResponse ?? {
                  success: true,
                  results: [{ domain: blockedDomain, inWhitelist: true }],
                }
              );
            }
            return Promise.resolve({ success: true });
          },
        },
        storage: {
          local: {
            get: () =>
              Promise.resolve({
                config: {
                  requestApiUrl: 'https://api.example',
                  fallbackApiUrls: [],
                  enableRequests: true,
                },
              }),
          },
          sync: {
            get: () => Promise.resolve({}),
          },
        },
      },
    },
    document: {
      configurable: true,
      value: {
        getElementById: (id: string): MockElement | null => elements.get(id) ?? null,
      },
    },
    fetch: {
      configurable: true,
      value: (url: string) => {
        fetchUrls.push(url);
        const payload = statusPayloads.shift() ?? {
          success: true,
          status: 'approved',
          domain: blockedDomain,
        };
        return Promise.resolve(
          new Response(JSON.stringify(payload), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        );
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
          replace: (url: string): void => {
            navigations.push(url);
          },
          search: `?domain=${encodeURIComponent(blockedDomain)}&error=WINDOWS_CANARY`,
        },
        sessionStorage: {
          getItem: () => null,
          removeItem: () => undefined,
          setItem: () => undefined,
        },
        setTimeout: (listener: () => void): ReturnType<typeof setTimeout> =>
          setTimeout(listener, 0),
      },
    },
  });

  return { elements, fetchUrls, navigations, runtimeMessages };
}
