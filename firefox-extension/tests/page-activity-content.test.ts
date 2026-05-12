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
