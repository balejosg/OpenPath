import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';

const extensionRoot = path.resolve(import.meta.dirname, '..');

async function readObserverEntrypoint(): Promise<string> {
  return readFile(path.join(extensionRoot, 'src', 'page-resource-observer-main.ts'), 'utf8');
}

void describe('page resource observer main-world content script', () => {
  void test('uses a classic-script entrypoint loadable in the page main world', async () => {
    const source = await readObserverEntrypoint();

    assert.doesNotMatch(source, /^\s*import\s/m);
    assert.doesNotMatch(source, /^\s*export\s/m);
    assert.match(source, /\(\(\): void => \{/);
    assert.match(source, /__openpathPageResourceObserverInstalled/);
  });

  void test('observes resource candidates without remote request creation', async () => {
    const source = await readObserverEntrypoint();

    assert.match(source, /openpath-page-resource-candidate/);
    assert.match(source, /MutationObserver/);
    assert.match(source, /window\.fetch/);
    assert.match(source, /XMLHttpRequest\.prototype\.open/);
    assert.doesNotMatch(source, /\/api\/requests\/auto/);
  });
});
