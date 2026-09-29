import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import process from 'node:process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

test('release quality gate falls back when gh commit-filtered run lookup is empty', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'openpath-gh-fallback-'));
  const fakeGh = path.join(tempDir, 'gh');
  const matchingSha = '93f8d1d585c87342b62d003c4377b65dd0d3ad8e';

  writeFileSync(
    fakeGh,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'run' && args[1] === 'list') {
  if (args.includes('--commit')) {
    console.log('[]');
  } else {
    console.log(JSON.stringify([{
      databaseId: 25008754860,
      status: 'completed',
      conclusion: 'success',
      headSha: '${matchingSha}',
      createdAt: '2026-04-27T17:05:33Z',
      url: 'https://example.invalid/run',
      workflowName: 'E2E Tests'
    }]));
  }
  process.exit(0);
}
if (args[0] === 'run' && args[1] === 'view') {
  console.log(JSON.stringify({
    status: 'completed',
    conclusion: 'success',
    headSha: '${matchingSha}',
    url: 'https://example.invalid/run',
    workflowName: 'E2E Tests',
    jobs: [{ name: 'E2E Summary', conclusion: 'success' }]
  }));
  process.exit(0);
}
console.error('unexpected gh call: ' + args.join(' '));
process.exit(2);
`,
    'utf8'
  );
  chmodSync(fakeGh, 0o755);

  const output = execFileSync(
    process.execPath,
    [
      'scripts/require-release-quality-gate.mjs',
      '--repo',
      'balejosg/Openpath',
      '--sha',
      matchingSha,
      '--require',
      'E2E Tests::E2E Summary',
      '--timeout-minutes',
      '1',
      '--poll-seconds',
      '1',
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${tempDir}${path.delimiter}${process.env.PATH ?? ''}`,
      },
    }
  );

  assert.match(output, /Release gate satisfied: E2E Tests \/ E2E Summary/);
});

test('release quality gate ignores a newer cancelled dispatch when the required summary job succeeded', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'openpath-gh-cancelled-dispatch-'));
  const fakeGh = path.join(tempDir, 'gh');
  const matchingSha = 'e88ccd5e7931de41d2d789e81b9b98f32ba2a164';

  writeFileSync(
    fakeGh,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'run' && args[1] === 'list') {
  console.log(JSON.stringify([
    {
      databaseId: 25104214917,
      status: 'completed',
      conclusion: 'cancelled',
      headSha: '${matchingSha}',
      createdAt: '2026-04-29T10:39:31Z',
      url: 'https://example.invalid/runs/25104214917',
      workflowName: 'CI'
    },
    {
      databaseId: 25098824685,
      status: 'completed',
      conclusion: 'success',
      headSha: '${matchingSha}',
      createdAt: '2026-04-29T08:31:48Z',
      url: 'https://example.invalid/runs/25098824685',
      workflowName: 'CI'
    }
  ]));
  process.exit(0);
}
if (args[0] === 'run' && args[1] === 'view') {
  const runId = args[2];
  if (runId === '25104214917') {
    console.log(JSON.stringify({
      status: 'completed',
      conclusion: 'cancelled',
      headSha: '${matchingSha}',
      url: 'https://example.invalid/runs/25104214917',
      workflowName: 'CI',
      jobs: [{ name: 'CI Success', conclusion: 'success' }]
    }));
    process.exit(0);
  }

  if (runId === '25098824685') {
    console.log(JSON.stringify({
      status: 'completed',
      conclusion: 'success',
      headSha: '${matchingSha}',
      url: 'https://example.invalid/runs/25098824685',
      workflowName: 'CI',
      jobs: [{ name: 'CI Success', conclusion: 'success' }]
    }));
    process.exit(0);
  }
}
console.error('unexpected gh call: ' + args.join(' '));
process.exit(2);
`,
    'utf8'
  );
  chmodSync(fakeGh, 0o755);

  const output = execFileSync(
    process.execPath,
    [
      'scripts/require-release-quality-gate.mjs',
      '--repo',
      'balejosg/Openpath',
      '--sha',
      matchingSha,
      '--require',
      'CI::CI Success',
      '--timeout-minutes',
      '1',
      '--poll-seconds',
      '1',
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${tempDir}${path.delimiter}${process.env.PATH ?? ''}`,
      },
    }
  );

  assert.match(output, /Release gate satisfied: CI \/ CI Success/);
  assert.match(output, /25104214917/);
});

test('release quality gate writes a clear skipped artifact summary when evidence is red', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'openpath-gh-red-summary-'));
  const fakeGh = path.join(tempDir, 'gh');
  const summaryPath = path.join(tempDir, 'summary.md');
  const matchingSha = '4b90d567a9d20ccbb7c54a5666c96212e833a004';

  writeFileSync(
    fakeGh,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'run' && args[1] === 'list') {
  console.log(JSON.stringify([{
    databaseId: 25201234567,
    status: 'completed',
    conclusion: 'failure',
    headSha: '${matchingSha}',
    createdAt: '2026-05-18T10:15:00Z',
    url: 'https://example.invalid/runs/25201234567',
    workflowName: 'E2E Tests'
  }]));
  process.exit(0);
}
if (args[0] === 'run' && args[1] === 'view') {
  console.log(JSON.stringify({
    status: 'completed',
    conclusion: 'failure',
    headSha: '${matchingSha}',
    url: 'https://example.invalid/runs/25201234567',
    workflowName: 'E2E Tests',
    jobs: [{ name: 'E2E Summary', conclusion: 'failure' }]
  }));
  process.exit(0);
}
console.error('unexpected gh call: ' + args.join(' '));
process.exit(2);
`,
    'utf8'
  );
  chmodSync(fakeGh, 0o755);

  assert.throws(
    () =>
      execFileSync(
        process.execPath,
        [
          'scripts/require-release-quality-gate.mjs',
          '--repo',
          'balejosg/Openpath',
          '--sha',
          matchingSha,
          '--require',
          'E2E Tests::E2E Summary',
          '--timeout-minutes',
          '1',
          '--poll-seconds',
          '1',
        ],
        {
          cwd: repoRoot,
          encoding: 'utf8',
          env: {
            ...process.env,
            GITHUB_STEP_SUMMARY: summaryPath,
            PATH: `${tempDir}${path.delimiter}${process.env.PATH ?? ''}`,
          },
        }
      ),
    /E2E Tests \/ E2E Summary concluded "failure"/
  );

  const summary = execFileSync('cat', [summaryPath], { encoding: 'utf8' });
  assert.match(summary, /Release Quality Gate/);
  assert.match(summary, /Package and publish jobs are blocked/);
  assert.match(summary, /E2E Tests \/ E2E Summary.*failure/);
  assert.match(summary, /https:\/\/example\.invalid\/runs\/25201234567/);
});

test('release quality gate accepts a completed summary job inside the in-progress current run', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'openpath-gh-current-run-'));
  const fakeGh = path.join(tempDir, 'gh');
  const matchingSha = '2ffa52a1c20c2a52e5b0d4a3f6f2a4a4c3b1d9e1';

  writeFileSync(
    fakeGh,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'run' && args[1] === 'list') {
  console.log(JSON.stringify([{
    databaseId: 26000000001,
    status: 'in_progress',
    conclusion: null,
    headSha: '${matchingSha}',
    createdAt: '2026-09-29T10:00:00Z',
    url: 'https://example.invalid/runs/26000000001',
    workflowName: 'Release Installation Scripts'
  }]));
  process.exit(0);
}
if (args[0] === 'run' && args[1] === 'view') {
  console.log(JSON.stringify({
    status: 'in_progress',
    conclusion: null,
    headSha: '${matchingSha}',
    url: 'https://example.invalid/runs/26000000001',
    workflowName: 'Release Installation Scripts',
    jobs: [{ name: 'Release Scripts Success', status: 'completed', conclusion: 'success' }]
  }));
  process.exit(0);
}
console.error('unexpected gh call: ' + args.join(' '));
process.exit(2);
`,
    'utf8'
  );
  chmodSync(fakeGh, 0o755);

  const output = execFileSync(
    process.execPath,
    [
      'scripts/require-release-quality-gate.mjs',
      '--repo',
      'balejosg/openpath',
      '--sha',
      matchingSha,
      '--require',
      'Release Installation Scripts::Release Scripts Success',
      '--timeout-minutes',
      '0.05',
      '--poll-seconds',
      '1',
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        GITHUB_RUN_ID: '26000000001',
        PATH: `${tempDir}${path.delimiter}${process.env.PATH ?? ''}`,
      },
    }
  );

  assert.match(
    output,
    /Release gate satisfied: Release Installation Scripts \/ Release Scripts Success/
  );
});

test('release quality gate rejects a failed summary job inside the in-progress current run', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'openpath-gh-current-run-failure-'));
  const fakeGh = path.join(tempDir, 'gh');
  const matchingSha = '2ffa52a1c20c2a52e5b0d4a3f6f2a4a4c3b1d9e1';

  writeFileSync(
    fakeGh,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'run' && args[1] === 'list') {
  console.log(JSON.stringify([{
    databaseId: 26000000002,
    status: 'in_progress',
    conclusion: null,
    headSha: '${matchingSha}',
    createdAt: '2026-09-29T10:00:00Z',
    url: 'https://example.invalid/runs/26000000002',
    workflowName: 'Release Installation Scripts'
  }]));
  process.exit(0);
}
if (args[0] === 'run' && args[1] === 'view') {
  console.log(JSON.stringify({
    status: 'in_progress',
    conclusion: null,
    headSha: '${matchingSha}',
    url: 'https://example.invalid/runs/26000000002',
    workflowName: 'Release Installation Scripts',
    jobs: [{ name: 'Release Scripts Success', status: 'completed', conclusion: 'failure' }]
  }));
  process.exit(0);
}
console.error('unexpected gh call: ' + args.join(' '));
process.exit(2);
`,
    'utf8'
  );
  chmodSync(fakeGh, 0o755);

  assert.throws(
    () =>
      execFileSync(
        process.execPath,
        [
          'scripts/require-release-quality-gate.mjs',
          '--repo',
          'balejosg/openpath',
          '--sha',
          matchingSha,
          '--require',
          'Release Installation Scripts::Release Scripts Success',
          '--timeout-minutes',
          '0.05',
          '--poll-seconds',
          '1',
        ],
        {
          cwd: repoRoot,
          encoding: 'utf8',
          env: {
            ...process.env,
            GITHUB_RUN_ID: '26000000002',
            PATH: `${tempDir}${path.delimiter}${process.env.PATH ?? ''}`,
          },
        }
      ),
    /Release Installation Scripts \/ Release Scripts Success concluded "failure"/
  );
});

test('release quality gate keeps waiting for an in-progress run that is not the current run', () => {
  const tempDir = mkdtempSync(path.join(tmpdir(), 'openpath-gh-foreign-run-wait-'));
  const fakeGh = path.join(tempDir, 'gh');
  const matchingSha = '2ffa52a1c20c2a52e5b0d4a3f6f2a4a4c3b1d9e1';

  writeFileSync(
    fakeGh,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'run' && args[1] === 'list') {
  console.log(JSON.stringify([{
    databaseId: 26000000003,
    status: 'in_progress',
    conclusion: null,
    headSha: '${matchingSha}',
    createdAt: '2026-09-29T10:00:00Z',
    url: 'https://example.invalid/runs/26000000003',
    workflowName: 'Release Installation Scripts'
  }]));
  process.exit(0);
}
if (args[0] === 'run' && args[1] === 'view') {
  console.log(JSON.stringify({
    status: 'in_progress',
    conclusion: null,
    headSha: '${matchingSha}',
    url: 'https://example.invalid/runs/26000000003',
    workflowName: 'Release Installation Scripts',
    jobs: [{ name: 'Release Scripts Success', status: 'completed', conclusion: 'success' }]
  }));
  process.exit(0);
}
console.error('unexpected gh call: ' + args.join(' '));
process.exit(2);
`,
    'utf8'
  );
  chmodSync(fakeGh, 0o755);

  assert.throws(
    () =>
      execFileSync(
        process.execPath,
        [
          'scripts/require-release-quality-gate.mjs',
          '--repo',
          'balejosg/openpath',
          '--sha',
          matchingSha,
          '--require',
          'Release Installation Scripts::Release Scripts Success',
          '--timeout-minutes',
          '0.01',
          '--poll-seconds',
          '1',
        ],
        {
          cwd: repoRoot,
          encoding: 'utf8',
          env: {
            ...process.env,
            GITHUB_RUN_ID: '26009999999',
            PATH: `${tempDir}${path.delimiter}${process.env.PATH ?? ''}`,
          },
        }
      ),
    (error) => {
      assert.match(
        String(error.stdout),
        /Waiting for Release Installation Scripts on/,
        'a non-current in-progress run must keep waiting even when its summary job is done'
      );
      return /Timed out waiting for Release Installation Scripts \/ Release Scripts Success/.test(
        String(error.stderr)
      );
    }
  );
});

test('generic release quality gate rejects internal Windows metadata flags', () => {
  assert.throws(
    () =>
      execFileSync(
        process.execPath,
        [
          'scripts/require-release-quality-gate.mjs',
          '--repo',
          'balejosg/OpenPath',
          '--sha',
          '93f8d1d585c87342b62d003c4377b65dd0d3ad8e',
          '--require',
          'CI::CI Success',
          '--windows-evidence-artifact-name',
          'desktop-survival',
        ],
        { cwd: repoRoot, encoding: 'utf8' }
      ),
    /Unknown or incomplete argument/
  );
});
