import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';

const extensionRoot = path.resolve(import.meta.dirname, '..');

async function readContentEntrypoint(): Promise<string> {
  return readFile(path.join(extensionRoot, 'src', 'page-activity-content.ts'), 'utf8');
}

async function importContentScript(caseId: string): Promise<void> {
  // Query suffix forces the classic-script side effect to run for each isolated case.
  await import(`../src/page-activity-content.ts?${caseId}`);
}

void describe('page activity content script', () => {
  void test('uses a classic-script entrypoint loadable from manifest content_scripts', async () => {
    const source = await readContentEntrypoint();

    assert.doesNotMatch(source, /^\s*import\s/m);
    assert.doesNotMatch(source, /^\s*export\s/m);
    assert.match(source, /\(\(\): void => \{/);
    assert.match(source, /browser\?\.runtime/);
    assert.match(source, /chrome\?\.runtime/);
  });

  void test('reports page activity and relays page resource candidates without remote auto-allow', async () => {
    const source = await readContentEntrypoint();

    assert.match(source, /openpathPageActivity/);
    assert.match(source, /openpathPageResourceCandidate/);
    assert.match(source, /openpath-page-resource-candidate/);
    assert.match(source, /resourceUrl/);
    assert.match(source, /window\.addEventListener\('message'/);
    assert.doesNotMatch(source, /\/api\/requests\/auto/);
  });

  void test('does not use inline script injection for the page resource observer', async () => {
    const source = await readContentEntrypoint();

    assert.doesNotMatch(source, /script\.textContent/);
    assert.doesNotMatch(source, /appendChild\(script\)/);
    assert.doesNotMatch(source, /fetch\(['"]\/api\/requests\/auto/);
  });

  void test('executes the manifest entrypoint and sends only page activity wake-up', async () => {
    const testGlobal = globalThis as unknown as Record<string, unknown>;
    const originalBrowser = testGlobal.browser;
    const originalChrome = testGlobal.chrome;

    const sentMessages: unknown[] = [];

    Object.assign(testGlobal, {
      browser: {
        runtime: {
          sendMessage(message: unknown): Promise<void> {
            sentMessages.push(message);
            return Promise.resolve();
          },
        },
      },
    });

    try {
      await importContentScript('wake-up');

      assert.deepEqual(sentMessages, [
        {
          action: 'openpathPageActivity',
        },
      ]);
    } finally {
      Object.assign(testGlobal, {
        browser: originalBrowser,
        chrome: originalChrome,
      });
    }
  });

  void test('relays self-origin page resource candidates to the runtime bridge', async () => {
    const testGlobal = globalThis as unknown as Record<string, unknown>;
    const originalBrowser = testGlobal.browser;
    const originalChrome = testGlobal.chrome;
    const originalWindow = testGlobal.window;
    const listeners: ((event: unknown) => void)[] = [];
    const sentMessages: unknown[] = [];
    const fakeWindow = {
      addEventListener(type: string, listener: (event: unknown) => void): void {
        if (type === 'message') {
          listeners.push(listener);
        }
      },
    };

    Object.assign(testGlobal, {
      window: fakeWindow,
      browser: {
        runtime: {
          sendMessage(message: unknown): Promise<void> {
            sentMessages.push(message);
            return Promise.resolve();
          },
        },
      },
      chrome: undefined,
    });

    try {
      await importContentScript('bridge-browser');

      assert.equal(listeners.length, 1);
      listeners[0]?.({
        source: {},
        data: {
          source: 'openpath-page-resource-candidate',
          kind: 'script',
          pageUrl: 'https://allowed.example/',
          url: 'https://ignored.example/app.js',
        },
      });
      listeners[0]?.({
        source: fakeWindow,
        data: { source: 'other', url: 'https://ignored.example/app.js' },
      });
      listeners[0]?.({
        source: fakeWindow,
        data: {
          source: 'openpath-page-resource-candidate',
          kind: 'script',
          pageUrl: 'https://allowed.example/',
          url: 'https://dependency.example/app.js',
        },
      });

      assert.deepEqual(sentMessages, [
        { action: 'openpathPageActivity' },
        {
          action: 'openpathPageResourceCandidate',
          kind: 'script',
          pageUrl: 'https://allowed.example/',
          resourceUrl: 'https://dependency.example/app.js',
        },
      ]);
    } finally {
      Object.assign(testGlobal, {
        browser: originalBrowser,
        chrome: originalChrome,
        window: originalWindow,
      });
    }
  });

  void test('uses chrome runtime fallback and keeps candidate relay best effort', async () => {
    const testGlobal = globalThis as unknown as Record<string, unknown>;
    const originalBrowser = testGlobal.browser;
    const originalChrome = testGlobal.chrome;
    const originalWindow = testGlobal.window;
    const listeners: ((event: unknown) => void)[] = [];
    const sentMessages: unknown[] = [];
    const fakeWindow = {
      addEventListener(type: string, listener: (event: unknown) => void): void {
        if (type === 'message') {
          listeners.push(listener);
        }
      },
    };

    Object.assign(testGlobal, {
      window: fakeWindow,
      browser: undefined,
      chrome: {
        runtime: {
          sendMessage(message: unknown): Promise<void> {
            sentMessages.push(message);
            return Promise.reject(new Error('native channel unavailable'));
          },
        },
      },
    });

    try {
      await importContentScript('bridge-chrome-reject');

      assert.equal(listeners.length, 1);
      assert.doesNotThrow(() => {
        listeners[0]?.({
          source: fakeWindow,
          data: {
            source: 'openpath-page-resource-candidate',
            kind: 42,
            pageUrl: 42,
            url: 'https://dependency.example/style.css',
          },
        });
      });
      await Promise.resolve();

      assert.deepEqual(sentMessages, [
        { action: 'openpathPageActivity' },
        {
          action: 'openpathPageResourceCandidate',
          kind: 'other',
          pageUrl: undefined,
          resourceUrl: 'https://dependency.example/style.css',
        },
      ]);
    } finally {
      Object.assign(testGlobal, {
        browser: originalBrowser,
        chrome: originalChrome,
        window: originalWindow,
      });
    }
  });

  void test('ignores pages without a usable runtime and catches synchronous send failures', async () => {
    const testGlobal = globalThis as unknown as Record<string, unknown>;
    const originalBrowser = testGlobal.browser;
    const originalChrome = testGlobal.chrome;
    const originalWindow = testGlobal.window;
    const listeners: ((event: unknown) => void)[] = [];
    const fakeWindow = {
      addEventListener(type: string, listener: (event: unknown) => void): void {
        if (type === 'message') {
          listeners.push(listener);
        }
      },
    };

    Object.assign(testGlobal, {
      window: fakeWindow,
      browser: { runtime: {} },
      chrome: undefined,
    });

    try {
      await importContentScript('no-runtime');
      assert.equal(listeners.length, 0);

      Object.assign(testGlobal, {
        browser: {
          runtime: {
            sendMessage(): never {
              throw new Error('sync failure');
            },
          },
        },
      });

      await importContentScript('sync-failure');
      assert.equal(listeners.length, 1);
      assert.doesNotThrow(() => {
        listeners[0]?.({
          source: fakeWindow,
          data: {
            source: 'openpath-page-resource-candidate',
            kind: 'fetch',
            url: 'https://dependency.example/data.json',
          },
        });
      });
    } finally {
      Object.assign(testGlobal, {
        browser: originalBrowser,
        chrome: originalChrome,
        window: originalWindow,
      });
    }
  });
});
