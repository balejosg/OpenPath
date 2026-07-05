import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  buildTestScriptInventory,
  EXCLUDED_TEST_SCRIPTS,
} from '../scripts/test-script-inventory.js';

const apiDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const inventory = buildTestScriptInventory({ apiDir });

void test('every test-prefixed script is derived or explicitly excluded', () => {
  assert.deepEqual(
    inventory.unclassified,
    [],
    'Unclassified test scripts. Either make them runnable node:test suites or add them to ' +
      'EXCLUDED_TEST_SCRIPTS in scripts/test-script-inventory.ts with a reason: ' +
      inventory.unclassified.join(', ')
  );
});

void test('no test script references a missing file or unmatched glob', () => {
  const stale = inventory.staleArgs.map((entry) => `${entry.script} -> ${entry.arg}`);
  assert.deepEqual(stale, [], `Stale test script arguments:\n${stale.join('\n')}`);
});

void test('exclusion map only names scripts that still exist', () => {
  const packageJson = JSON.parse(readFileSync(path.join(apiDir, 'package.json'), 'utf8')) as {
    scripts?: Record<string, string>;
  };
  const scripts = packageJson.scripts ?? {};
  const staleExclusions = Object.keys(EXCLUDED_TEST_SCRIPTS).filter(
    (name) => scripts[name] === undefined
  );
  assert.deepEqual(
    staleExclusions,
    [],
    `EXCLUDED_TEST_SCRIPTS names scripts that no longer exist: ${staleExclusions.join(', ')}`
  );
});

void test('every test file under tests/ is reachable by test:all', () => {
  assert.deepEqual(
    inventory.subdirectoryOrphans,
    [],
    'Subdirectory test files that NO runnable script covers (add them to an existing test:* ' +
      'script or create a new one; only top-level test files are auto-covered by the ' +
      'run-all remainder lane):\n' +
      inventory.subdirectoryOrphans.join('\n')
  );

  const reachable = new Set([...inventory.coveredFiles, ...inventory.remainder]);
  const unreachable = inventory.allTestFiles.filter((file) => !reachable.has(file));
  assert.deepEqual(
    unreachable,
    [],
    `Test files not reachable by any runnable script or the remainder lane:\n${unreachable.join('\n')}`
  );
});
