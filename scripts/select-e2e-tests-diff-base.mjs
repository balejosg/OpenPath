#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import process from 'node:process';

export const E2E_WORKFLOW_FILE = 'e2e-tests.yml';
export const E2E_PUSH_BRANCH = 'main';
export const ZERO_SHA = '0'.repeat(40);

const COMMIT_SHA_PATTERN = /^[0-9a-f]{40}$/;
const GITHUB_API_PAGE_SIZE = 100;
const DEFAULT_MAX_PAGES = 10;
const GITHUB_API_BASE_URL = 'https://api.github.com';

export function isValidCommitSha(value) {
  return typeof value === 'string' && COMMIT_SHA_PATTERN.test(value) && value !== ZERO_SHA;
}

export function isSuccessfulMainPushRun(run) {
  return (
    run?.event === 'push' &&
    run?.head_branch === E2E_PUSH_BRANCH &&
    run?.status === 'completed' &&
    run?.conclusion === 'success' &&
    isValidCommitSha(run?.head_sha)
  );
}

function runTimestamp(run) {
  const timestamp = Date.parse(run?.created_at ?? run?.run_started_at ?? '');
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

export function sortWorkflowRunsNewestFirst(runs) {
  return [...runs].sort((left, right) => {
    const timestampDelta = runTimestamp(right) - runTimestamp(left);
    if (timestampDelta !== 0) {
      return timestampDelta;
    }

    return (Number(right?.id) || 0) - (Number(left?.id) || 0);
  });
}

export function buildWorkflowRunsUrl({
  repo,
  workflow = E2E_WORKFLOW_FILE,
  page,
  perPage = GITHUB_API_PAGE_SIZE,
  apiBaseUrl = GITHUB_API_BASE_URL,
}) {
  const url = new URL(`${apiBaseUrl}/repos/${repo}/actions/workflows/${workflow}/runs`);
  url.searchParams.set('per_page', String(perPage));
  url.searchParams.set('page', String(page));
  // The branch= filter returns stale run data intermittently, so the caller
  // lists runs without it and filters by head_branch client-side.
  return url;
}

export function selectPushDiffBase({ runs = [], headSha, isAncestor }) {
  if (typeof isAncestor !== 'function') {
    throw new TypeError(
      'selectPushDiffBase requires an isAncestor(candidateSha, headSha) function'
    );
  }

  if (!isValidCommitSha(headSha)) {
    return {
      baseSha: null,
      mode: 'all-lanes',
      runId: null,
      reason: 'push head SHA is missing, zero, or not a commit SHA; selecting all lanes',
    };
  }

  const successfulRuns = sortWorkflowRunsNewestFirst(runs).filter(isSuccessfulMainPushRun);

  if (successfulRuns.length === 0) {
    return {
      baseSha: null,
      mode: 'all-lanes',
      runId: null,
      reason: `no successful ${E2E_WORKFLOW_FILE} push run on ${E2E_PUSH_BRANCH} was found; selecting all lanes`,
    };
  }

  for (const run of successfulRuns) {
    if (!isAncestor(run.head_sha, headSha)) {
      continue;
    }

    return {
      baseSha: run.head_sha,
      mode: 'run',
      runId: run.id == null ? null : String(run.id),
      reason: `using the head_sha of the most recent successful push run on ${E2E_PUSH_BRANCH} (run ${run.id}) as the diff base`,
    };
  }

  return {
    baseSha: null,
    mode: 'all-lanes',
    runId: null,
    reason: `no successful push run on ${E2E_PUSH_BRANCH} is an ancestor of ${headSha.slice(0, 8)}; the base is unreachable (zero SHA or force-push), selecting all lanes`,
  };
}

function gitIsAncestor(candidateSha, headSha) {
  const result = spawnSync('git', ['merge-base', '--is-ancestor', candidateSha, headSha], {
    cwd: process.cwd(),
    stdio: 'ignore',
  });

  return result.status === 0;
}

function githubHeaders(token) {
  const headers = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'openpath-e2e-diff-base',
  };

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  return headers;
}

async function readGitHubError(response) {
  try {
    return (await response.text()).replace(/\s+/g, ' ').trim().slice(0, 200);
  } catch {
    return '';
  }
}

async function fetchWorkflowRuns({ repo, workflow, token, maxPages }) {
  const runs = [];

  for (let page = 1; page <= maxPages; page += 1) {
    const url = buildWorkflowRunsUrl({ repo, workflow, page });
    const response = await fetch(url, { headers: githubHeaders(token) });

    if (!response.ok) {
      const body = await readGitHubError(response);
      throw new Error(`GitHub API returned ${response.status}${body ? `: ${body}` : ''}`);
    }

    const payload = await response.json();
    const pageRuns = payload.workflow_runs ?? [];
    runs.push(...pageRuns);

    if (pageRuns.length < GITHUB_API_PAGE_SIZE) {
      break;
    }
  }

  return runs;
}

function parseArgs(argv) {
  const args = {
    headSha: process.env.GITHUB_SHA ?? '',
    repo: process.env.GITHUB_REPOSITORY ?? '',
    workflow: E2E_WORKFLOW_FILE,
    output: '',
    maxPages: DEFAULT_MAX_PAGES,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    if (arg === '--head-sha') {
      args.headSha = argv[index + 1] ?? '';
      index += 1;
      continue;
    }
    if (arg === '--repo') {
      args.repo = argv[index + 1] ?? '';
      index += 1;
      continue;
    }
    if (arg === '--workflow') {
      args.workflow = argv[index + 1] ?? E2E_WORKFLOW_FILE;
      index += 1;
      continue;
    }
    if (arg === '--output') {
      args.output = argv[index + 1] ?? '';
      index += 1;
      continue;
    }
    if (arg === '--max-pages') {
      const parsed = Number(argv[index + 1]);
      if (!Number.isInteger(parsed) || parsed <= 0) {
        throw new Error('--max-pages must be a positive integer');
      }
      args.maxPages = parsed;
      index += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  return args;
}

function sanitizeOutputValue(value) {
  return String(value ?? '')
    .replace(/\r?\n/g, ' ')
    .trim();
}

function writeResolution({ outputPath, resolution }) {
  const lines = [
    `base_sha=${resolution.baseSha ?? ''}`,
    `base_mode=${resolution.mode}`,
    `base_run_id=${resolution.runId ?? ''}`,
    `base_reason=${sanitizeOutputValue(resolution.reason)}`,
  ];
  const content = `${lines.join('\n')}\n`;

  if (outputPath) {
    appendFileSync(outputPath, content);
    return;
  }

  process.stdout.write(content);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN || '';
  let resolution;

  try {
    if (!args.repo) {
      throw new Error('--repo or GITHUB_REPOSITORY is required');
    }

    const runs = await fetchWorkflowRuns({
      repo: args.repo,
      workflow: args.workflow,
      token,
      maxPages: args.maxPages,
    });
    resolution = selectPushDiffBase({
      runs,
      headSha: args.headSha,
      isAncestor: gitIsAncestor,
    });
  } catch (error) {
    resolution = {
      baseSha: null,
      mode: 'all-lanes',
      runId: null,
      reason: `could not resolve the push diff base (${sanitizeOutputValue(
        error.message
      )}); selecting all lanes`,
    };
  }

  writeResolution({ outputPath: args.output, resolution });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await main();
}
