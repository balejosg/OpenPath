/**
 * e2e-scope.mjs - Decides whether the e2e stage of verify:full may be skipped for a pushed range.
 *
 * Consulted by scripts/e2e-scope-check.mjs, which scripts/verify-full.sh invokes ONLY when the
 * pre-push hook exported the pushed range (OPENPATH_PREPUSH_REMOTE_SHA / OPENPATH_PREPUSH_LOCAL_SHA).
 * Manual `npm run verify:full` never sets those variables, so it always runs e2e.
 *
 * Decision policy (conservative -- the default is always RUN):
 *   - e2e is skipped ONLY when every changed file in the range matches E2E_IRRELEVANT_RULES.
 *   - Anything unresolvable (zero SHA, malformed SHA, remote SHA unknown locally, git failure,
 *     empty diff) -> RUN.
 *   - forceE2e (OPENPATH_VERIFY_E2E=1) -> RUN, regardless of the diff.
 *
 * The allowlist is evidence-derived; read docs/pre-push-e2e-scoping.md before extending it.
 * There is NO CI Playwright backstop -- this hook is the only gate running the react-spa
 * Playwright suite, so every rule must be provably outside the e2e:full dependency chain.
 *
 * Pure with respect to the process: all git access goes through the injected `gitExec`
 * (same pattern as scripts/lib/diff-base.mjs), so this is unit-testable without a live repo.
 */

/**
 * @typedef {(args: string[]) => string} GitExec
 *   Runs `git <args>` and returns stdout as a string. Must throw on a non-zero exit, mirroring
 *   `child_process.execFileSync`.
 */

/**
 * @typedef {{ file: string, matchedRule: string | null }} ClassifiedFile
 */

/**
 * @typedef {{ decision: 'run' | 'skip', reason: string, classified: ClassifiedFile[] }} ScopeDecision
 */

/**
 * First match wins. Every rule must be provably outside the e2e:full dependency chain
 * (docker-compose postgres-test + drizzle migrate/seed + shared/api/react-spa builds +
 * the react-spa Playwright suite). Evidence table: docs/pre-push-e2e-scoping.md.
 */
export const E2E_IRRELEVANT_RULES = [
  { rule: 'docs/**', matches: (file) => file.startsWith('docs/') },
  { rule: '**/*.md', matches: (file) => file.endsWith('.md') },
  { rule: 'linux/**', matches: (file) => file.startsWith('linux/') },
  { rule: 'windows/**', matches: (file) => file.startsWith('windows/') },
  { rule: '.github/**', matches: (file) => file.startsWith('.github/') },
];

const FULL_SHA_PATTERN = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;

/**
 * @param {string} file
 * @returns {ClassifiedFile}
 */
export function classifyFile(file) {
  for (const { rule, matches } of E2E_IRRELEVANT_RULES) {
    if (matches(file)) {
      return { file, matchedRule: rule };
    }
  }
  return { file, matchedRule: null };
}

/**
 * @param {object} options
 * @param {string} [options.remoteSha] - remote SHA from the pre-push stdin line
 * @param {string} [options.localSha] - local SHA from the pre-push stdin line
 * @param {boolean} [options.forceE2e] - OPENPATH_VERIFY_E2E=1
 * @param {GitExec} options.gitExec - injected git runner
 * @returns {ScopeDecision}
 */
export function decideE2eScope({ remoteSha = '', localSha = '', forceE2e = false, gitExec }) {
  if (typeof gitExec !== 'function') {
    throw new Error('decideE2eScope requires a gitExec function');
  }

  if (forceE2e) {
    return runDecision('forced by OPENPATH_VERIFY_E2E=1');
  }
  if (!remoteSha || !localSha) {
    return runDecision('no pushed range provided');
  }
  if (!FULL_SHA_PATTERN.test(remoteSha) || !FULL_SHA_PATTERN.test(localSha)) {
    return runDecision(`pushed range is not a pair of full SHAs (${remoteSha}..${localSha})`);
  }
  if (/^0+$/.test(localSha)) {
    return runDecision('ref deletion push (zero local SHA)');
  }
  if (/^0+$/.test(remoteSha)) {
    return runDecision('new remote ref (zero remote SHA, no known base)');
  }

  try {
    gitExec(['cat-file', '-e', `${remoteSha}^{commit}`]);
  } catch {
    return runDecision(`remote SHA ${remoteSha} is not present locally`);
  }

  let diffOutput;
  try {
    diffOutput = gitExec([
      'diff',
      '--name-only',
      '--no-renames',
      '-z',
      `${remoteSha}..${localSha}`,
    ]);
  } catch {
    return runDecision('git diff failed for the pushed range');
  }

  const files = (diffOutput ?? '').split('\0').filter((file) => file.length > 0);
  if (files.length === 0) {
    return runDecision('empty diff for the pushed range');
  }

  const classified = files.map(classifyFile);
  const firstRelevant = classified.find((entry) => entry.matchedRule === null);
  if (firstRelevant) {
    return {
      decision: 'run',
      reason: `changed file is e2e-relevant: ${firstRelevant.file}`,
      classified,
    };
  }

  return {
    decision: 'skip',
    reason: `all ${classified.length} changed file(s) matched the e2e-irrelevant allowlist`,
    classified,
  };
}

/**
 * @param {string} reason
 * @returns {ScopeDecision}
 */
function runDecision(reason) {
  return { decision: 'run', reason, classified: [] };
}
