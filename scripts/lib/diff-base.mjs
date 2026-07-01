/**
 * diff-base.mjs - Shared "what should we diff against?" resolution for coverage tooling.
 *
 * Used by scripts/check-new-file-coverage.js and scripts/run-changed-coverage.js so a local
 * `npm run verify:coverage` run checks the same file range as the pre-push gate (which diffs the
 * whole push range), instead of silently narrowing to the last commit.
 *
 * Resolution order:
 *   1. an explicit base (already merged from OPENPATH_VERIFY_BASE / --base by the caller)
 *   2. staged changes (`git diff --cached`), if any are present
 *   3. the merge-base of `head` and `origin/main`
 *   4. `origin/main` directly, if the merge-base lookup failed but the ref exists
 *   5. `HEAD~1`, only as a last resort when `origin/main` is unavailable (e.g. no remote)
 *
 * Pure with respect to the process: all git access goes through the injected `gitExec`, so this
 * is unit-testable without a live repo.
 */

/**
 * @typedef {(args: string[]) => string} GitExec
 *   Runs `git <args>` and returns stdout as a string. Must throw on a non-zero exit, mirroring
 *   `child_process.execFileSync`.
 */

/**
 * @typedef {{ mode: 'range' | 'staged' | 'none', base: string | null, source: string }} DiffBase
 */

/**
 * @param {object} options
 * @param {string} [options.explicitBase] - already-resolved explicit base (env/--base), if any
 * @param {string} [options.head] - head ref to diff against (default 'HEAD')
 * @param {GitExec} options.gitExec - injected git runner
 * @returns {DiffBase}
 */
export function resolveDiffBase({ explicitBase = '', head = 'HEAD', gitExec }) {
  if (typeof gitExec !== 'function') {
    throw new Error('resolveDiffBase requires a gitExec function');
  }

  if (explicitBase) {
    return { mode: 'range', base: explicitBase, source: 'explicit' };
  }

  if (hasStagedChanges(gitExec)) {
    return { mode: 'staged', base: null, source: 'staged' };
  }

  const mergeBase = tryMergeBase(gitExec, head);
  if (mergeBase) {
    return { mode: 'range', base: mergeBase, source: 'merge-base' };
  }

  if (refExists(gitExec, 'origin/main')) {
    return { mode: 'range', base: 'origin/main', source: 'origin-main' };
  }

  if (refExists(gitExec, 'HEAD~1')) {
    return { mode: 'range', base: 'HEAD~1', source: 'head-1-fallback' };
  }

  return { mode: 'none', base: null, source: 'none' };
}

function hasStagedChanges(gitExec) {
  try {
    const output = gitExec(['diff', '--cached', '--name-only', '--diff-filter=ACMR']);
    return Boolean(output && output.trim());
  } catch {
    return false;
  }
}

function tryMergeBase(gitExec, head) {
  try {
    const output = gitExec(['merge-base', head, 'origin/main']);
    const sha = output && output.trim();
    return sha || null;
  } catch {
    return null;
  }
}

function refExists(gitExec, ref) {
  try {
    gitExec(['rev-parse', '--verify', '--quiet', ref]);
    return true;
  } catch {
    return false;
  }
}
