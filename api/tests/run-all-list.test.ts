import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const apiDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

interface ListedCommand {
  readonly label: string;
  readonly argv: readonly string[];
}

interface ListedPlan {
  readonly commands: readonly ListedCommand[];
  readonly excluded: readonly { readonly name: string; readonly reason: string }[];
  readonly problems: readonly string[];
}

const EXPECTED_EXCLUSIONS = [
  'test:all',
  'test:coverage',
  'test:load',
  'test:mutation',
  'test:public-requests',
  'test:token-delivery:core',
  'test:token-delivery:extensions',
  'test:token-delivery:linux',
  'test:token-delivery:windows',
  'test:unit',
  'test:watch',
];

const PREVIOUSLY_SILENT_SCRIPTS = [
  'test:health-status',
  'test:groups',
  'test:service-coverage',
  'test:coverage-regressions',
  'test:integration:api',
  'test:machines',
  'test:token-delivery',
  'test:classroom-status',
  'test:sse',
];

function readPlan(): ListedPlan {
  const result = spawnSync(process.execPath, ['--import', 'tsx', 'tests/run-all.ts', '--list'], {
    cwd: apiDir,
    encoding: 'utf8',
    timeout: 60_000,
  });

  assert.equal(
    result.status,
    0,
    `run-all --list should exit 0.\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
  );

  return JSON.parse(result.stdout) as ListedPlan;
}

void test('run-all --list derives a complete, ordered, isolated plan', () => {
  const plan = readPlan();
  const labels = plan.commands.map((command) => command.label);

  assert.deepEqual(plan.problems, []);
  assert.equal(labels[0], 'npm run test', 'curated smoke set must run first');

  for (const script of PREVIOUSLY_SILENT_SCRIPTS) {
    assert.ok(labels.includes(`npm run ${script}`), `plan must include npm run ${script}`);
  }

  assert.deepEqual(
    plan.excluded.map((entry) => entry.name).sort((a, b) => a.localeCompare(b, 'en')),
    EXPECTED_EXCLUSIONS,
    'exclusion list changed; update this pin only together with a reasoned entry in EXCLUDED_TEST_SCRIPTS'
  );

  for (const entry of plan.excluded) {
    assert.ok(
      !labels.includes(`npm run ${entry.name}`),
      `excluded script ${entry.name} must not be in the plan`
    );
    assert.ok(entry.reason.length > 0, `excluded script ${entry.name} needs a reason`);
  }

  const remainderCommands = plan.commands.filter((command) =>
    command.label.startsWith('remainder ')
  );
  assert.ok(remainderCommands.length > 0, 'plan must include a remainder lane');

  for (const command of remainderCommands) {
    assert.ok(
      command.argv.includes('scripts/run-node-test-suite.ts'),
      'remainder chunks must run through run-node-test-suite.ts for port isolation'
    );
    const files = command.argv.filter((arg) => arg.startsWith('tests/'));
    assert.ok(files.length > 0 && files.length <= 10, 'remainder chunks hold 1-10 files');
    for (const file of files) {
      assert.ok(existsSync(path.join(apiDir, file)), `remainder file missing on disk: ${file}`);
    }
  }
});
