#!/usr/bin/env node
/**
 * agent-verify.js
 *
 * Optimized verification for AI agents. Chooses the fastest verification
 * level based on what changed.
 *
 * Usage:
 *   node scripts/agent-verify.js          # Auto-detect and verify
 *   node scripts/agent-verify.js --staged # Check staged files only
 *
 * Verification levels:
 *   1. staged-only:       verify:staged (~2-5s)
 *   2. staged + affected: verify:staged:affected (~15-45s)
 *
 * Whenever the change set includes any .ts/.tsx file, a TYPECHECK step
 * (npm run verify:static -- turbo typecheck+lint across all workspaces) is
 * appended. `npm test` runs via tsx and does NOT typecheck, so strict/
 * noUncheckedIndexedAccess-class errors can pass tests and lint-staged
 * while still breaking `tsc`. This step exists so the cheap agent gate
 * (and the pre-commit hook that calls it) catches those errors instead of
 * pushing that discovery out to the pre-push cross-workspace typecheck.
 */

import { execSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

// Patterns
const CODE_EXTENSIONS = /\.(ts|tsx|js|jsx|mjs|cjs)$/;
const TS_EXTENSIONS = /\.(ts|tsx)$/;
const TEST_PATTERN = /\.test\.(ts|tsx|js|jsx)$/;
const DOCS_EXTENSIONS = /\.(md|txt|json|yml|yaml)$/;
const SHARED_PATH = /^shared\//;

export function getChangedFiles(staged = false) {
  try {
    const cmd = staged
      ? 'git diff --cached --name-only --diff-filter=ACM'
      : 'git diff --name-only HEAD';
    const output = execSync(cmd, { cwd: ROOT, encoding: 'utf-8' });
    return output.trim().split('\n').filter(Boolean);
  } catch {
    try {
      const output = execSync('git diff --name-only', {
        cwd: ROOT,
        encoding: 'utf-8',
      });
      return output.trim().split('\n').filter(Boolean);
    } catch {
      return [];
    }
  }
}

export function categorizeFiles(files) {
  const result = {
    code: false,
    tests: false,
    shared: false,
    docsOnly: true,
    typescript: false,
  };

  for (const file of files) {
    if (CODE_EXTENSIONS.test(file)) {
      result.code = true;
      result.docsOnly = false;

      if (TEST_PATTERN.test(file)) {
        result.tests = true;
      }
      if (SHARED_PATH.test(file)) {
        result.shared = true;
      }
      if (TS_EXTENSIONS.test(file)) {
        result.typescript = true;
      }
    } else if (!DOCS_EXTENSIONS.test(file)) {
      // Unknown file type, treat as code
      result.code = true;
      result.docsOnly = false;
    }
  }

  return result;
}

const VERIFICATION_RULES = [
  {
    level: 'STAGED+AFFECTED',
    description: 'staged checks + affected tests',
    command: 'npm run verify:staged:affected',
    runDescription: 'Running affected verification...',
    when(category) {
      return category.tests || category.shared;
    },
  },
  {
    level: 'STAGED',
    description: 'staged file checks only',
    command: 'npm run verify:staged',
    runDescription: 'Running staged verification...',
    when(category) {
      return category.docsOnly || category.code;
    },
  },
];

export const TYPECHECK_STEP = {
  level: 'TYPECHECK',
  description: 'typecheck + type-aware lint for TypeScript changes',
  command: 'npm run verify:static',
  runDescription: 'Running typecheck + lint (verify:static) for TypeScript changes...',
  when(category) {
    return category.typescript;
  },
};

/**
 * Pure planning function: given a list of changed files, returns the
 * ordered list of verification steps to run. No side effects (does not
 * touch git or execute any command), so this is safe to unit test directly.
 */
export function planVerificationSteps(files) {
  const category = categorizeFiles(files);
  const steps = [];

  const rule = VERIFICATION_RULES.find((candidate) => candidate.when(category));
  if (rule) {
    steps.push({
      level: rule.level,
      description: rule.description,
      command: rule.command,
      runDescription: rule.runDescription,
    });
  }

  if (TYPECHECK_STEP.when(category)) {
    steps.push({
      level: TYPECHECK_STEP.level,
      description: TYPECHECK_STEP.description,
      command: TYPECHECK_STEP.command,
      runDescription: TYPECHECK_STEP.runDescription,
    });
  }

  return steps;
}

function run(cmd, description) {
  console.log(`\n${description}`);
  console.log(`$ ${cmd}\n`);
  try {
    execSync(cmd, { cwd: ROOT, stdio: 'inherit' });
    return true;
  } catch {
    return false;
  }
}

export function main(args = process.argv.slice(2)) {
  const staged = args.includes('--staged');

  console.log('Agent Verification Loop');
  console.log('=======================\n');

  const files = getChangedFiles(staged);

  if (files.length === 0) {
    console.log('No changes detected.');
    return 0;
  }

  console.log(`Changed files (${files.length}):`);
  files.slice(0, 10).forEach((f) => console.log(`  ${f}`));
  if (files.length > 10) {
    console.log(`  ... and ${files.length - 10} more`);
  }

  const steps = planVerificationSteps(files);

  if (steps.length === 0) {
    console.log('\n=======================');
    console.log('Agent verification (NONE) PASSED');
    return 0;
  }

  let success = true;
  let failedStep = null;

  for (const step of steps) {
    console.log(`\nLevel: ${step.level} (${step.description})`);
    const ok = run(step.command, step.runDescription);
    if (!ok) {
      success = false;
      failedStep = step;
      break;
    }
  }

  console.log('\n=======================');
  if (success) {
    const levels = steps.map((step) => step.level).join(' + ');
    console.log(`Agent verification (${levels}) PASSED`);
    return 0;
  }

  console.log(`Agent verification (${failedStep.level}) FAILED`);
  console.log(`  Failing step : ${failedStep.level} -- ${failedStep.command}`);
  console.log(`  Rerun just this step : ${failedStep.command}`);
  return 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
