import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';

const extensionRoot = path.resolve(import.meta.dirname, '..');

async function readContentEntrypoint(): Promise<string> {
  return readFile(path.join(extensionRoot, 'src', 'page-activity-content.ts'), 'utf8');
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

  void test('reports page activity without observing page resources', async () => {
    const source = await readContentEntrypoint();

    assert.match(source, /openpathPageActivity/);
    assert.doesNotMatch(source, /openpathPageResourceCandidate/);
    assert.doesNotMatch(source, /openpath-page-resource-candidate/);
    assert.doesNotMatch(source, /resourceUrl/);
    assert.doesNotMatch(source, /window\.addEventListener\('message'/);
  });

  void test('does not install page resource observers or inline script injection', async () => {
    const source = await readContentEntrypoint();

    assert.doesNotMatch(source, /MutationObserver/);
    assert.doesNotMatch(source, /script\.textContent/);
    assert.doesNotMatch(source, /appendChild\(script\)/);
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
      // @ts-expect-error page-activity-content is intentionally a classic script for manifest loading.
      await import('../src/page-activity-content.ts');

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
});
