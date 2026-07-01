#!/usr/bin/env node

import { execFileSync, execSync } from 'node:child_process';
import { resolve } from 'node:path';

import { resolveDiffBase } from './lib/diff-base.mjs';

const ROOT_DIR = resolve(import.meta.dirname, '..');

const WORKSPACE_ORDER = [
  { prefix: 'shared/src/', workspace: '@openpath/shared' },
  { prefix: 'api/src/', workspace: '@openpath/api' },
  { prefix: 'react-spa/src/', workspace: '@openpath/react-spa' },
  { prefix: 'dashboard/src/', workspace: '@openpath/dashboard' },
  { prefix: 'firefox-extension/src/', workspace: '@openpath/firefox-extension' },
];

function getChangedFiles() {
  const { base, head } = parseRangeArgs(process.argv.slice(2));

  try {
    const resolved = resolveDiffBase({ explicitBase: base, head, gitExec: silentGitOutput });

    if (resolved.mode === 'range') {
      const output = gitOutput(['diff', '--name-only', '--diff-filter=ACMR', resolved.base, head]);

      return output.split('\n').filter((file) => file.trim());
    }

    if (resolved.mode === 'staged') {
      const staged = execSync('git diff --cached --name-only --diff-filter=ACMR', {
        encoding: 'utf-8',
        cwd: ROOT_DIR,
      });

      return staged.split('\n').filter((file) => file.trim());
    }

    return [];
  } catch (error) {
    console.error('Failed to read changed files:', error.message);
    process.exit(1);
  }
}

function parseRangeArgs(argv) {
  const options = {
    base: process.env.OPENPATH_VERIFY_BASE || '',
    head: process.env.OPENPATH_VERIFY_HEAD || 'HEAD',
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];

    if (arg === '--base' && next) {
      options.base = next;
      index += 1;
      continue;
    }
    if (arg === '--head' && next) {
      options.head = next;
      index += 1;
      continue;
    }

    throw new Error(`Unknown or incomplete argument: ${arg}`);
  }

  return options;
}

function gitOutput(args) {
  return execFileSync('git', args, {
    encoding: 'utf-8',
    cwd: ROOT_DIR,
  });
}

// Used only for base-resolution probes (staged check, merge-base, ref-exists): these are
// expected to fail in some environments (e.g. no `origin` remote), so stderr is suppressed to
// avoid noisy "fatal: ..." output on the happy path.
function silentGitOutput(args) {
  return execFileSync('git', args, {
    encoding: 'utf-8',
    cwd: ROOT_DIR,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
}

function getCoverageWorkspaces(files) {
  const workspaces = new Set();

  for (const file of files) {
    if (!/\.(ts|tsx)$/.test(file)) {
      continue;
    }

    for (const { prefix, workspace } of WORKSPACE_ORDER) {
      if (file.startsWith(prefix)) {
        workspaces.add(workspace);
        break;
      }
    }
  }

  return WORKSPACE_ORDER.map(({ workspace }) => workspace).filter((workspace) =>
    workspaces.has(workspace)
  );
}

function main() {
  console.log('Preparing coverage reports for changed workspaces...');

  const files = getChangedFiles();
  const workspaces = getCoverageWorkspaces(files);

  if (workspaces.length === 0) {
    console.log('No changed source workspaces require coverage generation.');
    return;
  }

  console.log(`Generating coverage for: ${workspaces.join(', ')}`);

  for (const workspace of workspaces) {
    console.log(`\n--- Coverage for ${workspace} ---\n`);
    execSync(`npm run test:coverage --workspace=${workspace}`, {
      cwd: ROOT_DIR,
      stdio: 'inherit',
    });
  }
}

main();
