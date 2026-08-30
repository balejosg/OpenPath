import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DOCKER_MANIFEST_CASES } from '../../scripts/generate-docker-manifests.mjs';

const currentFilePath = fileURLToPath(import.meta.url);
const currentDir = dirname(currentFilePath);
export const projectRoot = resolve(currentDir, '..', '..');

export function readPackageJson() {
  return JSON.parse(readFileSync(resolve(projectRoot, 'package.json'), 'utf8'));
}

export function readJson(relativePath) {
  return JSON.parse(readFileSync(resolve(projectRoot, relativePath), 'utf8'));
}

export function readText(relativePath) {
  return readFileSync(resolve(projectRoot, relativePath), 'utf8');
}

export function extractWorkflowJobBlock(workflowText, jobId) {
  const jobPattern = new RegExp(`(^  ${jobId}:\\n[\\s\\S]*?)(?=^  [a-z0-9-]+:\\n|\\Z)`, 'm');
  const match = workflowText.match(jobPattern);

  assert.ok(match, `workflow should define a ${jobId} job block`);
  return match[1];
}

export function listStableReleaseTags() {
  const tags = new Set();
  const gitDir = execFileSync('git', ['rev-parse', '--git-dir'], {
    cwd: projectRoot,
    encoding: 'utf8',
  }).trim();
  const resolvedGitDir = resolve(projectRoot, gitDir);
  const tagsDir = resolve(resolvedGitDir, 'refs/tags');
  const packedRefsPath = resolve(resolvedGitDir, 'packed-refs');

  function collectTagRefs(directory, prefix = '') {
    if (!existsSync(directory)) {
      return;
    }

    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const relativeName = prefix ? `${prefix}/${entry.name}` : entry.name;

      if (entry.isDirectory()) {
        collectTagRefs(resolve(directory, entry.name), relativeName);
        continue;
      }

      if (entry.isFile() && relativeName.startsWith('v')) {
        tags.add(relativeName);
      }
    }
  }

  collectTagRefs(tagsDir);

  if (existsSync(packedRefsPath)) {
    const packedRefs = readFileSync(packedRefsPath, 'utf8');

    for (const line of packedRefs.split(/\r?\n/)) {
      if (!line || line.startsWith('#') || line.startsWith('^')) {
        continue;
      }

      const [, ref] = line.split(' ');
      const tagName = ref?.replace(/^refs\/tags\//, '') ?? '';
      if (tagName.startsWith('v')) {
        tags.add(tagName);
      }
    }
  }

  return [...tags].sort((left, right) =>
    compareSemver(right.replace(/^v/, ''), left.replace(/^v/, ''))
  );
}

export function compareSemver(left, right) {
  const leftParts = left.split('.').map(Number);
  const rightParts = right.split('.').map(Number);

  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    const leftPart = leftParts[index] ?? 0;
    const rightPart = rightParts[index] ?? 0;

    if (leftPart !== rightPart) {
      return leftPart - rightPart;
    }
  }

  return 0;
}

export function walkTextFiles(relativePath) {
  const root = resolve(projectRoot, relativePath);
  const entries = readdirSync(root, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const nextRelativePath = `${relativePath}/${entry.name}`;
    const nextAbsolutePath = resolve(projectRoot, nextRelativePath);

    if (entry.isDirectory()) {
      files.push(...walkTextFiles(nextRelativePath));
      continue;
    }

    if (!entry.isFile()) {
      continue;
    }

    const stat = statSync(nextAbsolutePath);
    if (stat.size > 1024 * 1024) {
      continue;
    }

    files.push(nextRelativePath);
  }

  return files;
}

export { DOCKER_MANIFEST_CASES };
