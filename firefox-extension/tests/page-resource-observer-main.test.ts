import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';

const extensionRoot = path.resolve(import.meta.dirname, '..');

async function readMainObserver(): Promise<string> {
  return readFile(path.join(extensionRoot, 'src', 'page-resource-observer-main.ts'), 'utf8');
}

void describe('page resource MAIN-world observer', () => {
  void test('runs without WebExtension APIs and patches async resource APIs directly', async () => {
    const source = await readMainObserver();

    assert.doesNotMatch(source, /browser\?\.runtime/);
    assert.doesNotMatch(source, /chrome\?\.runtime/);
    assert.match(source, /__openpathPageResourceObserverInstalled/);
    assert.match(source, /window\.fetch = function/);
    assert.match(source, /XMLHttpRequest\.prototype\.open/);
    assert.match(source, /openpath-page-resource-candidate/);
  });

  void test('does not depend on inline script injection that page CSP can block', async () => {
    const source = await readMainObserver();

    assert.doesNotMatch(source, /document\.createElement\(['"]script['"]\)/);
    assert.doesNotMatch(source, /script\.textContent/);
    assert.doesNotMatch(source, /appendChild\(script\)/);
  });
});
