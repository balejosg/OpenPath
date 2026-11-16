import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { test } from 'node:test';

import {
  buildWorkflowRunsUrl,
  isValidCommitSha,
  selectPushDiffBase,
  sortWorkflowRunsNewestFirst,
  ZERO_SHA,
} from '../../scripts/select-e2e-tests-diff-base.mjs';
import { projectRoot } from './support.mjs';

const BASE_RUN_SHA = '4a886c8160cef12a6ec4d09f654d92a5af5015b4';
const CANCELLED_RUN_SHA = 'bbcd0c56519e73b7d42c1c9282739817b034d7d8';
const OMITTED_RUN_SHA = '09f5cf995538ef54f33e49894b68d3b6f9a9a8ed';
const HEAD_SHA = '42afd931727dd7c5093ca8799b8faf686a065893';

function createRun(overrides) {
  return {
    id: 1,
    event: 'push',
    head_branch: 'main',
    head_sha: BASE_RUN_SHA,
    status: 'completed',
    conclusion: 'success',
    created_at: '2025-01-01T00:00:00Z',
    ...overrides,
  };
}

function git(args) {
  return execFileSync('git', args, {
    cwd: projectRoot,
    encoding: 'utf8',
  }).trim();
}

function gitHasCommit(sha) {
  return (
    spawnSync('git', ['cat-file', '-e', `${sha}^{commit}`], {
      cwd: projectRoot,
      stdio: 'ignore',
    }).status === 0
  );
}

test('push diff base uses the newest successful main push run that is an ancestor', () => {
  const runs = [
    createRun({ id: 10, head_sha: BASE_RUN_SHA, created_at: '2025-01-01T00:00:00Z' }),
    createRun({ id: 20, head_sha: OMITTED_RUN_SHA, created_at: '2025-02-01T00:00:00Z' }),
    createRun({
      id: 30,
      head_sha: CANCELLED_RUN_SHA,
      conclusion: 'cancelled',
      created_at: '2025-03-01T00:00:00Z',
    }),
    createRun({
      id: 40,
      event: 'workflow_dispatch',
      head_sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      created_at: '2025-04-01T00:00:00Z',
    }),
    createRun({
      id: 50,
      head_branch: 'feature/topic',
      head_sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      created_at: '2025-05-01T00:00:00Z',
    }),
    createRun({
      id: 60,
      head_sha: 'cccccccccccccccccccccccccccccccccccccccc',
      conclusion: 'failure',
      created_at: '2025-06-01T00:00:00Z',
    }),
  ];

  const resolution = selectPushDiffBase({
    runs,
    headSha: HEAD_SHA,
    isAncestor: (candidateSha) => candidateSha === BASE_RUN_SHA || candidateSha === OMITTED_RUN_SHA,
  });

  assert.equal(resolution.baseSha, OMITTED_RUN_SHA);
  assert.equal(resolution.mode, 'run');
  assert.equal(resolution.runId, '20');
  assert.match(resolution.reason, /most recent successful push run on main \(run 20\)/);
});

test('push diff base falls back to all lanes when no successful main push run exists', () => {
  const resolution = selectPushDiffBase({
    runs: [
      createRun({ id: 1, conclusion: 'cancelled' }),
      createRun({ id: 2, conclusion: 'failure' }),
      createRun({ id: 3, event: 'pull_request' }),
      createRun({ id: 4, head_branch: 'release' }),
    ],
    headSha: HEAD_SHA,
    isAncestor: () => true,
  });

  assert.equal(resolution.baseSha, null);
  assert.equal(resolution.mode, 'all-lanes');
  assert.match(resolution.reason, /no successful e2e-tests\.yml push run on main/);
});

test('push diff base falls back to all lanes when no successful run is an ancestor', () => {
  const resolution = selectPushDiffBase({
    runs: [createRun({ id: 7, head_sha: BASE_RUN_SHA })],
    headSha: HEAD_SHA,
    isAncestor: () => false,
  });

  assert.equal(resolution.baseSha, null);
  assert.equal(resolution.mode, 'all-lanes');
  assert.match(resolution.reason, /base is unreachable \(zero SHA or force-push\)/);
});

test('push diff base rejects zero and malformed head SHAs', () => {
  for (const headSha of ['', ZERO_SHA, 'not-a-sha']) {
    const resolution = selectPushDiffBase({
      runs: [createRun({ id: 7 })],
      headSha,
      isAncestor: () => true,
    });

    assert.equal(resolution.baseSha, null);
    assert.equal(resolution.mode, 'all-lanes');
    assert.match(resolution.reason, /push head SHA is missing, zero, or not a commit SHA/);
  }

  assert.equal(isValidCommitSha('a'.repeat(40)), true);
  assert.equal(isValidCommitSha(ZERO_SHA), false);
});

test('workflow run sorting is deterministic for equal timestamps', () => {
  const runs = [
    createRun({ id: 1, created_at: '2025-01-01T00:00:00Z' }),
    createRun({ id: 3, created_at: '2025-01-01T00:00:00Z' }),
    createRun({ id: 2, created_at: '2025-02-01T00:00:00Z' }),
  ];

  assert.deepEqual(
    sortWorkflowRunsNewestFirst(runs).map((run) => run.id),
    [2, 3, 1]
  );
});

test('workflow run listing never sends the stale branch filter', () => {
  const url = buildWorkflowRunsUrl({ repo: 'owner/openpath', page: 2 });

  assert.equal(url.searchParams.has('branch'), false);
  assert.equal(url.searchParams.get('per_page'), '100');
  assert.equal(url.searchParams.get('page'), '2');
  assert.match(url.pathname, /\/actions\/workflows\/e2e-tests\.yml\/runs$/);
});

test('regression: cancelled contract lane is recovered from the last green main push', (t) => {
  const requiredCommits = [BASE_RUN_SHA, CANCELLED_RUN_SHA, OMITTED_RUN_SHA, HEAD_SHA];
  if (!requiredCommits.every(gitHasCommit)) {
    t.skip('requires the full OpenPath git history (shallow clone cannot run this regression)');
    return;
  }

  const runs = [
    createRun({
      id: 41805463244,
      head_sha: CANCELLED_RUN_SHA,
      conclusion: 'cancelled',
      created_at: '2025-09-15T10:00:00Z',
    }),
    createRun({
      id: 41811185224,
      head_sha: OMITTED_RUN_SHA,
      conclusion: 'failure',
      created_at: '2025-09-16T10:00:00Z',
    }),
    createRun({
      id: 41042735170,
      head_sha: BASE_RUN_SHA,
      created_at: '2025-09-10T10:00:00Z',
    }),
    createRun({
      id: 41813954186,
      head_sha: HEAD_SHA,
      status: 'in_progress',
      conclusion: null,
      created_at: '2025-09-17T10:00:00Z',
    }),
  ];

  const resolution = selectPushDiffBase({
    runs,
    headSha: HEAD_SHA,
    isAncestor: (candidateSha, headSha) => {
      const result = spawnSync('git', ['merge-base', '--is-ancestor', candidateSha, headSha], {
        cwd: projectRoot,
        stdio: 'ignore',
      });
      return result.status === 0;
    },
  });

  assert.equal(resolution.baseSha, BASE_RUN_SHA);
  assert.equal(resolution.runId, '41042735170');

  const changedFiles = git(['diff', '--name-only', resolution.baseSha, HEAD_SHA]).split('\n');

  for (const firewallFile of [
    'windows/lib/Firewall.psm1',
    'windows/lib/internal/Firewall.Policy.ps1',
    'windows/lib/internal/Firewall.State.ps1',
  ]) {
    assert.ok(
      changedFiles.includes(firewallFile),
      `regression diff from the last green push must include ${firewallFile}`
    );
  }

  const immediatePreviousFiles = git(['diff', '--name-only', OMITTED_RUN_SHA, HEAD_SHA]).split(
    '\n'
  );
  assert.ok(
    !immediatePreviousFiles.includes('windows/lib/Firewall.psm1'),
    'the immediate-previous-SHA diff is the regression case that lost Windows contract coverage'
  );
});
