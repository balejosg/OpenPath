import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  buildTestScriptInventory,
  chunkFiles,
  parseTestFileArgs,
} from '../scripts/test-script-inventory.js';

function createFixture(): string {
  const root = mkdtempSync(path.join(tmpdir(), 'test-script-inventory-'));
  mkdirSync(path.join(root, 'tests', 'lib'), { recursive: true });
  mkdirSync(path.join(root, 'tests', 'sub'), { recursive: true });

  const scripts = {
    test: 'tsx scripts/run-node-test-suite.ts tests/a.test.ts tests/lib/b.test.ts',
    'test:glob':
      "NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit 'tests/glob-*.test.ts'",
    'test:stale': 'NODE_ENV=test node --import tsx --test --test-force-exit tests/missing.test.ts',
    'test:all': 'NODE_ENV=test node --import tsx tests/run-all.ts',
    'test:load': 'NODE_ENV=test k6 run tests/load/load-test.js',
    'test:tool': 'somebinary run whatever',
    build: 'tsc',
  };
  writeFileSync(path.join(root, 'package.json'), JSON.stringify({ scripts }, null, 2));

  const testFiles = [
    'tests/a.test.ts',
    'tests/lib/b.test.ts',
    'tests/glob-one.test.ts',
    'tests/glob-two.test.ts',
    'tests/orphan-top.test.ts',
    'tests/sub/orphan.test.ts',
  ];
  for (const file of testFiles) {
    writeFileSync(path.join(root, file), 'export {};\n');
  }

  return root;
}

void test('parseTestFileArgs recognizes both runner shapes and strips quotes', () => {
  assert.deepEqual(parseTestFileArgs("tsx scripts/run-node-test-suite.ts 'tests/auth-*.test.ts'"), [
    'tests/auth-*.test.ts',
  ]);
  assert.deepEqual(
    parseTestFileArgs(
      'NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/a.test.ts tests/b.test.ts'
    ),
    ['tests/a.test.ts', 'tests/b.test.ts']
  );
  assert.equal(parseTestFileArgs('NODE_ENV=test node --import tsx tests/run-all.ts'), null);
  assert.equal(parseTestFileArgs('NODE_ENV=test k6 run tests/load/load-test.js'), null);
  assert.equal(parseTestFileArgs('stryker run'), null);
  assert.equal(parseTestFileArgs('npm run test:schedules'), null);
});

void test('chunkFiles splits into fixed-size chunks preserving order', () => {
  assert.deepEqual(chunkFiles(['a', 'b', 'c'], 2), [['a', 'b'], ['c']]);
  assert.deepEqual(chunkFiles([], 10), []);
  assert.throws(() => chunkFiles(['a'], 0), RangeError);
});

void test('buildTestScriptInventory classifies, expands, and reports gaps', () => {
  const root = createFixture();
  try {
    const inventory = buildTestScriptInventory({ apiDir: root });

    assert.deepEqual(
      inventory.derived.map((entry) => entry.name),
      ['test', 'test:glob', 'test:stale'],
      'test first, then package.json definition order; excluded and unclassified skipped'
    );
    assert.deepEqual(inventory.derived[0]?.files, ['tests/a.test.ts', 'tests/lib/b.test.ts']);
    assert.deepEqual(inventory.derived[1]?.files, [
      'tests/glob-one.test.ts',
      'tests/glob-two.test.ts',
    ]);
    assert.deepEqual(inventory.derived[2]?.files, []);

    assert.ok(inventory.excluded.some((entry) => entry.name === 'test:all'));
    assert.ok(inventory.excluded.some((entry) => entry.name === 'test:load'));
    assert.deepEqual(inventory.unclassified, ['test:tool']);
    assert.deepEqual(inventory.staleArgs, [{ script: 'test:stale', arg: 'tests/missing.test.ts' }]);

    assert.deepEqual(inventory.allTestFiles, [
      'tests/a.test.ts',
      'tests/glob-one.test.ts',
      'tests/glob-two.test.ts',
      'tests/lib/b.test.ts',
      'tests/orphan-top.test.ts',
      'tests/sub/orphan.test.ts',
    ]);
    assert.deepEqual(inventory.remainder, ['tests/orphan-top.test.ts']);
    assert.deepEqual(inventory.subdirectoryOrphans, ['tests/sub/orphan.test.ts']);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
