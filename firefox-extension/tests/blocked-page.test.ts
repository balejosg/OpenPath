import assert from 'node:assert';
import { describe, test } from 'node:test';

import { main } from '../src/blocked-page.js';

class MockElement {
  textContent = '';
  value = '';
  disabled = false;
  private readonly listeners = new Map<string, (() => void)[]>();

  readonly classList = {
    add: (): void => undefined,
    remove: (): void => undefined,
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
        value: (_url: string, init?: RequestInit) => {
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
            replace: (): void => undefined,
            search:
              '?domain=blocked.example&blockedUrl=https%3A%2F%2Fblocked.example%2F&origin=https%3A%2F%2Flesson.example%2F&error=WINDOWS_CANARY',
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
      await waitForAsyncHandlers();
      await waitForAsyncHandlers();

      assert.deepEqual(runtimeMessages, []);
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
    } finally {
      Object.defineProperty(globalThis, 'fetch', {
        configurable: true,
        value: originalFetch,
      });
    }
  });
});
