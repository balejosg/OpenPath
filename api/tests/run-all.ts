/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * Test Runner for running all test suites sequentially.
 *
 * The command list is DERIVED from api/package.json: every runnable
 * node:test script runs here in a separate child process (avoiding module
 * cache conflicts when test files start servers), followed by a remainder
 * lane that runs top-level test files no script references. Scripts that
 * must not run here are named in EXCLUDED_TEST_SCRIPTS
 * (scripts/test-script-inventory.ts) with a reason.
 *
 * Flags / env:
 *   --list              print the derived plan as JSON and exit (runs nothing)
 *   RUN_ALL_TIMEOUT_MS  per-command watchdog in ms, default 120000
 */

import { spawn, type ChildProcess } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  buildTestScriptInventory,
  chunkFiles,
  type ExcludedScriptEntry,
} from '../scripts/test-script-inventory.js';

const currentFilePath = fileURLToPath(import.meta.url);
const apiDir = path.join(path.dirname(currentFilePath), '..');

const REMAINDER_CHUNK_SIZE = 10;
const DEFAULT_TIMEOUT_MS = 120_000;

interface PlannedCommand {
  readonly label: string;
  readonly argv: readonly string[];
}

interface RunAllPlan {
  readonly commands: readonly PlannedCommand[];
  readonly excluded: readonly ExcludedScriptEntry[];
  readonly problems: readonly string[];
}

function resolveTimeoutMs(): number {
  const raw = process.env.RUN_ALL_TIMEOUT_MS;
  if (raw === undefined || raw === '') {
    return DEFAULT_TIMEOUT_MS;
  }

  const parsed = Number.parseInt(raw, 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : DEFAULT_TIMEOUT_MS;
}

function buildPlan(): RunAllPlan {
  const inventory = buildTestScriptInventory({ apiDir });

  const problems: string[] = [
    ...inventory.unclassified.map(
      (name) =>
        `unclassified script "${name}": not a recognizable node:test command; ` +
        'add it to EXCLUDED_TEST_SCRIPTS in scripts/test-script-inventory.ts with a reason'
    ),
    ...inventory.staleArgs.map(
      (stale) => `stale file argument in "${stale.script}": ${stale.arg} does not exist`
    ),
  ];

  const commands: PlannedCommand[] = inventory.derived.map((entry) => ({
    label: `npm run ${entry.name}`,
    argv: ['npm', 'run', entry.name],
  }));

  const remainderChunks = chunkFiles(inventory.remainder, REMAINDER_CHUNK_SIZE);
  remainderChunks.forEach((chunk, index) => {
    commands.push({
      label: `remainder ${String(index + 1)}/${String(remainderChunks.length)} (top-level files no script covers)`,
      argv: [process.execPath, '--import', 'tsx', 'scripts/run-node-test-suite.ts', ...chunk],
    });
  });

  return { commands, excluded: inventory.excluded, problems };
}

const plan = buildPlan();

if (process.argv.includes('--list')) {
  console.log(
    JSON.stringify(
      {
        commands: plan.commands,
        excluded: plan.excluded.map(({ name, reason }) => ({ name, reason })),
        problems: plan.problems,
      },
      null,
      2
    )
  );
  process.exit(plan.problems.length > 0 ? 1 : 0);
}

if (plan.problems.length > 0) {
  console.error('❌ test:all refuses to run with an inconsistent script inventory:');
  for (const problem of plan.problems) {
    console.error(`  - ${problem}`);
  }
  process.exit(1);
}

const timeoutMs = resolveTimeoutMs();
const failedLabels: string[] = [];
let currentIndex = 0;

function runNextCommand(): void {
  if (currentIndex >= plan.commands.length) {
    console.log('\n' + '='.repeat(60));
    if (failedLabels.length > 0) {
      console.log('❌ Failed commands:');
      for (const label of failedLabels) {
        console.log(`  - ${label}`);
      }
      process.exit(1);
    }

    console.log('✅ All test suites completed successfully');
    process.exit(0);
    return;
  }

  const command = plan.commands[currentIndex];
  if (command === undefined) {
    console.error('Unexpected undefined test command');
    process.exit(1);
    return;
  }

  const [cmd, ...args] = command.argv;
  if (cmd === undefined || cmd === '') {
    console.error('Unexpected empty test command');
    process.exit(1);
    return;
  }

  console.log('\n' + '='.repeat(60));
  console.log(`Running: ${command.label}`);
  console.log('='.repeat(60) + '\n');

  const child: ChildProcess = spawn(cmd, args, {
    cwd: apiDir,
    stdio: 'inherit',
    env: process.env,
  });

  // Watchdog to kill hanging commands (tunable via RUN_ALL_TIMEOUT_MS)
  const timeout = setTimeout((): void => {
    console.log(`\n⚠️  ${command.label} timed out after ${String(timeoutMs)}ms, killing...`);
    child.kill('SIGKILL');
  }, timeoutMs);

  child.on('close', (code: number | null): void => {
    clearTimeout(timeout);
    if (code !== 0) {
      failedLabels.push(command.label);
    }
    currentIndex++;
    // Small delay between commands to ensure port cleanup
    setTimeout(runNextCommand, 500);
  });

  child.on('error', (err: Error): void => {
    clearTimeout(timeout);
    console.error(`Failed to run ${command.label}:`, err);
    failedLabels.push(command.label);
    currentIndex++;
    setTimeout(runNextCommand, 500);
  });
}

console.log(`🧪 Running all test suites (${String(plan.commands.length)} commands)...\n`);
runNextCommand();
