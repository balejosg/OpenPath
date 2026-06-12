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
 */

import { execSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

// Patterns
const CODE_EXTENSIONS = /\.(ts|tsx|js|jsx|mjs|cjs)$/;
const TEST_PATTERN = /\.test\.(ts|tsx|js|jsx)$/;
const DOCS_EXTENSIONS = /\.(md|txt|json|yml|yaml)$/;
const SHARED_PATH = /^shared\//;

function getChangedFiles(staged = false) {
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

function categorizeFiles(files) {
  const result = {
    code: false,
    tests: false,
    shared: false,
    docsOnly: true,
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

// Main
const args = process.argv.slice(2);
const staged = args.includes('--staged');

console.log('Agent Verification Loop');
console.log('=======================\n');

const files = getChangedFiles(staged);

if (files.length === 0) {
  console.log('No changes detected.');
  process.exit(0);
}

console.log(`Changed files (${files.length}):`);
files.slice(0, 10).forEach((f) => console.log(`  ${f}`));
if (files.length > 10) {
  console.log(`  ... and ${files.length - 10} more`);
}

const category = categorizeFiles(files);
const rule = VERIFICATION_RULES.find((candidate) => candidate.when(category));

let success = true;
let level = 'NONE';

let failedCommand = '';
let failedLevel = '';

if (rule) {
  level = rule.level;
  console.log(`\nLevel: ${rule.level} (${rule.description})`);
  success = run(rule.command, rule.runDescription);
  if (!success) {
    failedCommand = rule.command;
    failedLevel = rule.level;
  }
}

console.log('\n=======================');
if (success) {
  console.log(`Agent verification (${level}) PASSED`);
  process.exit(0);
} else {
  console.log(`Agent verification (${level}) FAILED`);
  console.log(`  Failing step : ${failedLevel} -- ${failedCommand}`);
  console.log(`  Rerun just this step : ${failedCommand}`);
  process.exit(1);
}
