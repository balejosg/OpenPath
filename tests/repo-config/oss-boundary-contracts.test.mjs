import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * OSS boundary guard -- enforces the workspace-level rule:
 *   "OpenPath must remain agnostic of ClassroomPath."
 *   (root AGENTS.md "Workspace Rules > OpenPath Independence")
 *
 * Source directories must not contain the forbidden downstream-wrapper term.
 * The term is constructed at runtime so that this file itself does not contain
 * the literal string, keeping OpenPath sources verifiably clean.
 */

const forbidden = ['class', 'room', 'path'].join('');

const currentFile = fileURLToPath(import.meta.url);
const repoRoot = resolve(currentFile, '../../..');

const SOURCE_DIRS = [
  'api/',
  'react-spa/src/',
  'linux/',
  'windows/lib/',
  'windows/libexec/',
  'firefox-extension/src/',
  'scripts/',
];

const TEST_PATH_FRAGMENTS = ['test', 'tests', '__tests__'];

function isTestPath(filePath) {
  return TEST_PATH_FRAGMENTS.some((fragment) => filePath.includes(fragment));
}

describe('OSS boundary: source dirs must not reference the SaaS wrapper', () => {
  test('no tracked source file contains the forbidden wrapper term', () => {
    const listResult = spawnSync('git', ['ls-files', '--', ...SOURCE_DIRS], {
      cwd: repoRoot,
      encoding: 'utf8',
    });

    assert.equal(listResult.status, 0, `git ls-files failed: ${listResult.stderr}`);

    const trackedFiles = listResult.stdout
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .filter((line) => !isTestPath(line));

    const offenders = [];

    for (const relativePath of trackedFiles) {
      let content;
      try {
        content = readFileSync(resolve(repoRoot, relativePath), 'utf8');
      } catch {
        continue;
      }
      if (content.toLowerCase().includes(forbidden.toLowerCase())) {
        offenders.push(relativePath);
      }
    }

    assert.deepEqual(
      offenders,
      [],
      [
        `${offenders.length} source file(s) reference the forbidden wrapper term ("${forbidden}"):`,
        ...offenders.map((f) => `  ${f}`),
        '',
        'Recovery: OSS core must stay agnostic of the SaaS wrapper.',
        `References to "${forbidden}" belong in the wrapper repo, not in OpenPath source dirs.`,
        'See root AGENTS.md "OpenPath Independence" for the canonical boundary rule.',
      ].join('\n')
    );
  });
});
