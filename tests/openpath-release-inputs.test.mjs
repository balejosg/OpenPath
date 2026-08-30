import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { describe, test } from 'node:test';

import {
  RELEASE_INPUT_DEFINITIONS,
  computeReleaseInputFingerprint,
  listReleaseInputFiles,
} from '../scripts/openpath-release-inputs.mjs';

function createFixture(component) {
  const repoRoot = mkdtempSync(join(tmpdir(), `openpath-${component}-inputs-`));
  const definition = RELEASE_INPUT_DEFINITIONS[component];

  for (const relativePath of definition.files) {
    const absolutePath = join(repoRoot, relativePath);
    mkdirSync(join(absolutePath, '..'), { recursive: true });
    writeFileSync(absolutePath, `fixture:${relativePath}\n`);
  }

  for (const relativePath of definition.trees) {
    const absolutePath = join(repoRoot, relativePath, 'fixture-input.txt');
    mkdirSync(join(absolutePath, '..'), { recursive: true });
    writeFileSync(absolutePath, `fixture:${relativePath}\n`);
  }

  return repoRoot;
}

describe('canonical OpenPath release input fingerprints', () => {
  for (const component of Object.keys(RELEASE_INPUT_DEFINITIONS)) {
    test(`${component} inventory is sorted, stable, and excludes generated outputs`, () => {
      const repoRoot = createFixture(component);
      const first = listReleaseInputFiles({ repoRoot, component });
      const second = listReleaseInputFiles({ repoRoot, component });

      assert.deepEqual(first, second);
      assert.deepEqual(first, [...first].sort());
      assert.ok(first.every((path) => !path.includes('/node_modules/')));
      assert.ok(first.every((path) => !path.includes('/dist/')));
      assert.ok(
        first.every((path) => path !== 'windows/offline-installer/build/fixture-input.txt')
      );
    });
  }

  test('irrelevant files do not change a fingerprint, while a shipped input does', () => {
    const repoRoot = createFixture('linuxAgent');
    const initial = computeReleaseInputFingerprint({ repoRoot, component: 'linuxAgent' });

    mkdirSync(join(repoRoot, 'docs'), { recursive: true });
    writeFileSync(join(repoRoot, 'docs', 'unrelated.md'), 'documentation only\n');
    assert.equal(computeReleaseInputFingerprint({ repoRoot, component: 'linuxAgent' }), initial);

    writeFileSync(join(repoRoot, 'linux', 'lib', 'fixture-input.txt'), 'changed shipped input\n');
    assert.notEqual(computeReleaseInputFingerprint({ repoRoot, component: 'linuxAgent' }), initial);
  });

  test('fingerprints are independent of directory enumeration order and include the definition version', () => {
    const repoRoot = createFixture('windowsOfflineInstaller');
    const files = listReleaseInputFiles({ repoRoot, component: 'windowsOfflineInstaller' });
    assert.ok(files.length > 0);

    const fingerprint = computeReleaseInputFingerprint({
      repoRoot,
      component: 'windowsOfflineInstaller',
    });
    assert.match(fingerprint, /^[a-f0-9]{64}$/);
  });

  test('unknown components and missing canonical inputs fail closed', () => {
    assert.throws(
      () => listReleaseInputFiles({ repoRoot: tmpdir(), component: 'unknown' }),
      /unknown release component/i
    );

    const repoRoot = mkdtempSync(join(tmpdir(), 'openpath-missing-inputs-'));
    assert.throws(
      () => computeReleaseInputFingerprint({ repoRoot, component: 'browserPolicy' }),
      /missing canonical release input/i
    );
  });

  test('inventories include source, build, manifest, packaging, and orchestration inputs', () => {
    const expectations = {
      linuxAgent: {
        files: [
          'VERSION',
          'package-lock.json',
          'linux/scripts/build/build-deb.sh',
          '.github/workflows/reusable-deb-publish.yml',
          'firefox-extension/tsconfig.build.json',
        ],
        trees: ['linux/debian-package', 'linux/lib', 'linux/scripts/runtime'],
      },
      windowsOfflineInstaller: {
        files: [
          'VERSION',
          'package-lock.json',
          '.github/workflows/release-scripts.yml',
          'firefox-extension/tsconfig.build.json',
        ],
        trees: ['windows', 'runtime'],
      },
      browserPolicy: {
        files: [
          'runtime/browser-policy-spec.json',
          'linux/lib/firefox-policy.sh',
          'firefox-extension/manifest.json',
          'firefox-extension/tsconfig.build.json',
        ],
        trees: ['linux/lib', 'windows/lib', 'firefox-extension/src'],
      },
    };

    for (const [component, expected] of Object.entries(expectations)) {
      for (const relativePath of expected.files) {
        assert.ok(
          RELEASE_INPUT_DEFINITIONS[component].files.includes(relativePath),
          `${component} should fingerprint ${relativePath}`
        );
      }
      for (const relativePath of expected.trees) {
        assert.ok(
          RELEASE_INPUT_DEFINITIONS[component].trees.includes(relativePath),
          `${component} should fingerprint ${relativePath}/`
        );
      }
    }
  });
});
