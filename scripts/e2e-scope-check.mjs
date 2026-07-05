#!/usr/bin/env node
/**
 * e2e-scope-check.mjs - Thin CLI over scripts/lib/e2e-scope.mjs.
 *
 * Reads OPENPATH_PREPUSH_REMOTE_SHA / OPENPATH_PREPUSH_LOCAL_SHA / OPENPATH_VERIFY_E2E from the
 * environment, prints a human-readable report to stderr (this is the "why e2e ran/skipped" line
 * in pre-push output), and prints exactly one machine-readable word to stdout: `run` or `skip`.
 *
 * scripts/verify-full.sh treats anything other than a clean `skip` on stdout -- including a
 * non-zero exit -- as RUN, so failure modes here can only make verification MORE thorough.
 */

import { execFileSync } from 'node:child_process';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

import { decideE2eScope } from './lib/e2e-scope.mjs';

/** @param {string[]} args */
function defaultGitExec(args) {
  return execFileSync('git', args, { encoding: 'utf8' });
}

/**
 * @param {object} [options]
 * @param {Record<string, string | undefined>} [options.env]
 * @param {(args: string[]) => string} [options.gitExec]
 * @param {{ write: (chunk: string) => unknown }} [options.stdout]
 * @param {{ write: (chunk: string) => unknown }} [options.stderr]
 * @returns {'run' | 'skip'}
 */
export function runCli({
  env = process.env,
  gitExec = defaultGitExec,
  stdout = process.stdout,
  stderr = process.stderr,
} = {}) {
  const result = decideE2eScope({
    remoteSha: (env.OPENPATH_PREPUSH_REMOTE_SHA ?? '').trim(),
    localSha: (env.OPENPATH_PREPUSH_LOCAL_SHA ?? '').trim(),
    forceE2e: env.OPENPATH_VERIFY_E2E === '1',
    gitExec,
  });

  stderr.write(`e2e scope: ${result.decision.toUpperCase()} -- ${result.reason}\n`);
  for (const { file, matchedRule } of result.classified) {
    stderr.write(`  ${matchedRule ?? 'e2e-relevant'}  ${file}\n`);
  }

  stdout.write(`${result.decision}\n`);
  return result.decision;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runCli();
}
