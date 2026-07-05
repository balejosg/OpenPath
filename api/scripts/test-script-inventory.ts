/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * Test-script inventory: single source of truth for which test-prefixed
 * scripts in api/package.json are runnable node:test suites, which test
 * files each one covers, and which test files nothing covers.
 *
 * Consumed by tests/run-all.ts (derives its command list) and by
 * tests/test-script-coverage-contract.test.ts (fails on silent gaps).
 */

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { resolveTestInputs } from './test-suite-discovery.js';

export interface TestScriptEntry {
  readonly name: string;
  readonly command: string;
  /** Expanded existing test files, posix paths relative to api/. */
  readonly files: readonly string[];
}

export interface ExcludedScriptEntry {
  readonly name: string;
  readonly command: string;
  readonly reason: string;
}

export interface StaleTestArg {
  readonly script: string;
  readonly arg: string;
}

export interface TestScriptInventory {
  /** Runnable node:test suites: `test` first, then package.json order. */
  readonly derived: readonly TestScriptEntry[];
  readonly excluded: readonly ExcludedScriptEntry[];
  /** Test-prefixed scripts neither excluded nor parseable as node:test commands. */
  readonly unclassified: readonly string[];
  /** Script args that expand to no existing test file. */
  readonly staleArgs: readonly StaleTestArg[];
  /** Every .test.ts under tests/ (recursive, posix, sorted). */
  readonly allTestFiles: readonly string[];
  /** Union of derived files (sorted). */
  readonly coveredFiles: readonly string[];
  /** Top-level test files no derived script covers; run-all's remainder lane runs these. */
  readonly remainder: readonly string[];
  /** Subdirectory test files no derived script covers - always a silent gap. */
  readonly subdirectoryOrphans: readonly string[];
}

/**
 * Scripts test:all must never run, with the reason stated next to each.
 * Removing an entry makes run-all derive the script automatically; adding a
 * test-prefixed script that is not a node:test suite REQUIRES an entry here,
 * otherwise run-all and the coverage contract test fail loudly.
 */
export const EXCLUDED_TEST_SCRIPTS: Readonly<Record<string, string>> = {
  'test:watch': 'interactive watch mode over the curated test list; never terminates',
  'test:all': 'the run-all entrypoint itself; deriving it would recurse',
  'test:coverage':
    'c8 CI lane; boots its own Docker DB via scripts/run-api-coverage.js and already discovers every top-level test file',
  'test:load': 'k6 load test; requires the k6 binary, not a node:test suite',
  'test:mutation': 'Stryker mutation run; separate long-running tool',
  'test:unit': 'alias for test:schedules, which is already derived',
  'test:public-requests':
    'strict subset of the curated test script; CI delivery-contract lane pinned by workflow-contracts.test.mjs',
  'test:token-delivery:core': 'focused subset of test:token-delivery, which is already derived',
  'test:token-delivery:windows': 'focused subset of test:token-delivery, which is already derived',
  'test:token-delivery:linux': 'focused subset of test:token-delivery, which is already derived',
  'test:token-delivery:extensions':
    'focused subset of test:token-delivery, which is already derived',
};

const moduleDir = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_API_DIR = path.join(moduleDir, '..');

const SUITE_RUNNER_PREFIX = 'tsx scripts/run-node-test-suite.ts';
const NODE_TEST_COMMAND = /^(?:NODE_ENV=test )?node --import tsx --test(?: |$)/u;

/**
 * Returns the tests/ file and glob args of a runnable node:test command,
 * or null when the command is not a recognizable node:test suite.
 */
export function parseTestFileArgs(command: string): string[] | null {
  if (!command.startsWith(SUITE_RUNNER_PREFIX) && !NODE_TEST_COMMAND.test(command)) {
    return null;
  }

  const args: string[] = [];
  for (const rawToken of command.split(/\s+/u)) {
    const token = rawToken.replace(/^['"]/u, '').replace(/['"]$/u, '');
    if (token.startsWith('tests/')) {
      args.push(token);
    }
  }

  return args;
}

export function chunkFiles(files: readonly string[], size: number): string[][] {
  if (!Number.isInteger(size) || size <= 0) {
    throw new RangeError(`chunk size must be a positive integer, got ${String(size)}`);
  }

  const chunks: string[][] = [];
  for (let index = 0; index < files.length; index += size) {
    chunks.push([...files.slice(index, index + size)]);
  }

  return chunks;
}

function collectTestFiles(relativeDir: string, apiDir: string): string[] {
  const absoluteDir = path.join(apiDir, relativeDir);
  if (!existsSync(absoluteDir)) {
    return [];
  }

  const files: string[] = [];
  for (const entry of readdirSync(absoluteDir, { withFileTypes: true })) {
    const relativePath = `${relativeDir}/${entry.name}`;
    if (entry.isDirectory()) {
      files.push(...collectTestFiles(relativePath, apiDir));
      continue;
    }

    if (entry.isFile() && entry.name.endsWith('.test.ts')) {
      files.push(relativePath);
    }
  }

  return files.sort();
}

function isTopLevel(testFile: string): boolean {
  return !testFile.slice('tests/'.length).includes('/');
}

export function buildTestScriptInventory(options?: {
  readonly apiDir?: string;
}): TestScriptInventory {
  const apiDir = options?.apiDir ?? DEFAULT_API_DIR;
  const packageJson = JSON.parse(readFileSync(path.join(apiDir, 'package.json'), 'utf8')) as {
    scripts?: Record<string, string>;
  };
  const scripts = packageJson.scripts ?? {};

  const testScriptNames = Object.keys(scripts).filter(
    (name) => name === 'test' || name.startsWith('test:')
  );
  const orderedNames = [
    ...testScriptNames.filter((name) => name === 'test'),
    ...testScriptNames.filter((name) => name !== 'test'),
  ];

  const derived: TestScriptEntry[] = [];
  const excluded: ExcludedScriptEntry[] = [];
  const unclassified: string[] = [];
  const staleArgs: StaleTestArg[] = [];

  for (const name of orderedNames) {
    const command = scripts[name] ?? '';
    const reason = EXCLUDED_TEST_SCRIPTS[name];
    if (reason !== undefined) {
      excluded.push({ name, command, reason });
      continue;
    }

    const args = parseTestFileArgs(command);
    if (args === null) {
      unclassified.push(name);
      continue;
    }

    const existing: string[] = [];
    for (const candidate of resolveTestInputs(args, { cwd: apiDir })) {
      if (existsSync(path.join(apiDir, candidate))) {
        existing.push(candidate);
      } else {
        staleArgs.push({ script: name, arg: candidate });
      }
    }

    derived.push({ name, command, files: existing });
  }

  const allTestFiles = collectTestFiles('tests', apiDir);
  const covered = new Set(derived.flatMap((entry) => [...entry.files]));

  return {
    derived,
    excluded,
    unclassified,
    staleArgs,
    allTestFiles,
    coveredFiles: [...covered].sort(),
    remainder: allTestFiles.filter((file) => isTopLevel(file) && !covered.has(file)),
    subdirectoryOrphans: allTestFiles.filter((file) => !isTopLevel(file) && !covered.has(file)),
  };
}
