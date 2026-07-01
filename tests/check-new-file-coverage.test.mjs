import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { resolveDiffBase } from '../scripts/lib/diff-base.mjs';

/**
 * Builds a fake `gitExec` for resolveDiffBase() tests: no live repo dependency.
 *
 * `responses` is an ordered list of [matcher, outcome] pairs matched against the
 * space-joined git args. `outcome` is either a string (stdout) or an Error to throw.
 */
function makeGitExec(responses) {
  const calls = [];
  const gitExec = (args) => {
    const key = args.join(' ');
    calls.push(key);

    for (const [matcher, outcome] of responses) {
      if (matcher.test(key)) {
        if (outcome instanceof Error) {
          throw outcome;
        }
        return outcome;
      }
    }

    throw new Error(`Unexpected git invocation in test: ${key}`);
  };
  gitExec.calls = calls;
  return gitExec;
}

describe('resolveDiffBase (scripts/lib/diff-base.mjs)', () => {
  test('env unset + merge-base ref available -> picks merge-base, not HEAD~1', () => {
    const gitExec = makeGitExec([
      [/^diff --cached/, ''],
      [/^merge-base HEAD origin\/main/, 'abc123\n'],
    ]);

    const result = resolveDiffBase({ explicitBase: '', head: 'HEAD', gitExec });

    assert.deepEqual(result, { mode: 'range', base: 'abc123', source: 'merge-base' });
    assert.ok(
      !gitExec.calls.some((call) => call.includes('HEAD~1')),
      'should not probe HEAD~1 when merge-base succeeds'
    );
  });

  test('explicit base (OPENPATH_VERIFY_BASE / --base) is honored without consulting git', () => {
    const gitExec = () => {
      throw new Error('gitExec should not be called when an explicit base is provided');
    };

    const result = resolveDiffBase({ explicitBase: 'origin/main', head: 'HEAD', gitExec });

    assert.deepEqual(result, { mode: 'range', base: 'origin/main', source: 'explicit' });
  });

  test('staged changes present -> uses --cached and skips the merge-base lookup', () => {
    const gitExec = makeGitExec([
      [/^diff --cached/, 'api/src/foo.ts\n'],
      [/^merge-base/, new Error('should not be called: staged changes take priority')],
    ]);

    const result = resolveDiffBase({ explicitBase: '', head: 'HEAD', gitExec });

    assert.deepEqual(result, { mode: 'staged', base: null, source: 'staged' });
  });

  test('origin ref absent -> falls back to HEAD~1', () => {
    const gitExec = makeGitExec([
      [/^diff --cached/, ''],
      [/^merge-base/, new Error("fatal: ambiguous argument 'origin/main': unknown revision")],
      [/^rev-parse --verify --quiet origin\/main/, new Error('fatal: needed a single revision')],
      [/^rev-parse --verify --quiet HEAD~1/, ''],
    ]);

    const result = resolveDiffBase({ explicitBase: '', head: 'HEAD', gitExec });

    assert.deepEqual(result, { mode: 'range', base: 'HEAD~1', source: 'head-1-fallback' });
  });

  test('origin/main ref exists but merge-base lookup fails -> uses origin/main directly', () => {
    const gitExec = makeGitExec([
      [/^diff --cached/, ''],
      [/^merge-base/, new Error('fatal: unrelated histories')],
      [/^rev-parse --verify --quiet origin\/main/, ''],
    ]);

    const result = resolveDiffBase({ explicitBase: '', head: 'HEAD', gitExec });

    assert.deepEqual(result, { mode: 'range', base: 'origin/main', source: 'origin-main' });
  });

  test('nothing available (no staged, no merge-base, no origin/main, no HEAD~1) -> mode none', () => {
    const gitExec = makeGitExec([
      [/^diff --cached/, ''],
      [/^merge-base/, new Error('no merge-base')],
      [/^rev-parse --verify --quiet origin\/main/, new Error('no origin/main')],
      [/^rev-parse --verify --quiet HEAD~1/, new Error('no HEAD~1 (root commit)')],
    ]);

    const result = resolveDiffBase({ explicitBase: '', head: 'HEAD', gitExec });

    assert.deepEqual(result, { mode: 'none', base: null, source: 'none' });
  });

  test('missing gitExec throws a clear error instead of crashing on undefined', () => {
    assert.throws(() => resolveDiffBase({ explicitBase: '' }), /gitExec/);
  });
});
