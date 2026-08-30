#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, lstatSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDir, '..');

export const RELEASE_INPUT_FINGERPRINT_SCHEMA_VERSION = 1;

const COMMON_BUILD_FILES = [
  'VERSION',
  'package.json',
  'package-lock.json',
  'patches/multimatch+6.0.0.patch',
  'tsconfig.base.json',
  'turbo.json',
  '.github/actions/build-workspaces/action.yml',
  '.github/actions/setup-node/action.yml',
];

const FIREFOX_RUNTIME_TREES = [
  'firefox-extension/src',
  'firefox-extension/_locales',
  'firefox-extension/blocked',
  'firefox-extension/popup',
  'firefox-extension/icons',
  'firefox-extension/native',
];

const FIREFOX_BUILD_FILES = [
  'firefox-extension/manifest.json',
  'firefox-extension/package.json',
  'firefox-extension/build-firefox-release.mjs',
  'firefox-extension/build-firefox-source-submission.mjs',
  'firefox-extension/build-chromium-managed.mjs',
  'firefox-extension/build-xpi.sh',
  'firefox-extension/firefox-release-payload-hash.mjs',
  'firefox-extension/sign-firefox-release.mjs',
  'firefox-extension/tsconfig.build.json',
  'firefox-extension/tsconfig.json',
  'firefox-extension/verify-firefox-release-artifacts.mjs',
];

const RELEASE_INPUT_DEFINITIONS_MUTABLE = {
  linuxAgent: {
    files: [
      ...COMMON_BUILD_FILES,
      '.github/actions/prepare-firefox-release-artifacts/action.yml',
      '.github/workflows/build-deb.yml',
      '.github/workflows/prerelease-deb.yml',
      '.github/workflows/reusable-deb-publish.yml',
      'linux/scripts/build/build-deb.sh',
      'linux/uninstall.sh',
      'runtime/browser-policy-spec.json',
      ...FIREFOX_BUILD_FILES,
    ],
    trees: [
      'linux/debian-package',
      'linux/lib',
      'linux/libexec',
      'linux/scripts/runtime',
      ...FIREFOX_RUNTIME_TREES,
    ],
    excludes: [],
  },
  windowsOfflineInstaller: {
    files: [
      ...COMMON_BUILD_FILES,
      '.github/actions/prepare-firefox-release-artifacts/action.yml',
      '.github/workflows/release-scripts.yml',
      ...FIREFOX_BUILD_FILES,
    ],
    trees: ['windows', 'runtime', ...FIREFOX_RUNTIME_TREES],
    excludes: ['windows/offline-installer/build'],
  },
  browserPolicy: {
    files: [
      ...COMMON_BUILD_FILES,
      '.github/actions/prepare-firefox-release-artifacts/action.yml',
      '.github/workflows/build-deb.yml',
      '.github/workflows/firefox-release-assets.yml',
      '.github/workflows/release-scripts.yml',
      'runtime/browser-policy-spec.json',
      'linux/lib/browser-request-readiness.sh',
      'linux/lib/firefox-policy.sh',
      ...FIREFOX_BUILD_FILES,
    ],
    trees: ['linux/lib', 'windows/lib', ...FIREFOX_RUNTIME_TREES],
    excludes: [],
  },
};

function freezeDefinition(definition) {
  return Object.freeze({
    files: Object.freeze([...new Set(definition.files)].sort()),
    trees: Object.freeze([...new Set(definition.trees)].sort()),
    excludes: Object.freeze([...new Set(definition.excludes)].sort()),
  });
}

export const RELEASE_INPUT_DEFINITIONS = Object.freeze(
  Object.fromEntries(
    Object.entries(RELEASE_INPUT_DEFINITIONS_MUTABLE).map(([component, definition]) => [
      component,
      freezeDefinition(definition),
    ])
  )
);

function normalizeRelativePath(relativePath) {
  const normalized = String(relativePath).split('\\').join('/');
  if (!normalized || normalized.startsWith('/') || normalized.split('/').includes('..')) {
    throw new Error(`Invalid release input path: ${relativePath}`);
  }
  return normalized;
}

function getDefinition(component) {
  const definition = RELEASE_INPUT_DEFINITIONS[component];
  if (!definition) {
    throw new Error(`Unknown release component: ${component}`);
  }
  return definition;
}

function isExcluded(relativePath, excludes) {
  const normalized = normalizeRelativePath(relativePath);
  return excludes.some(
    (excludedPath) => normalized === excludedPath || normalized.startsWith(`${excludedPath}/`)
  );
}

function getGitErrorMessage(error) {
  const stderr = error?.stderr;
  if (stderr) return String(stderr).trim();
  return error instanceof Error ? error.message : String(error);
}

function listIgnoredPaths(repoRoot) {
  let isInsideWorktree;
  try {
    isInsideWorktree = execFileSync('git', ['rev-parse', '--is-inside-work-tree'], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (error) {
    const message = getGitErrorMessage(error);
    if (/not a git repository/i.test(message)) return [];
    throw new Error(`Unable to inspect Git worktree for release inputs: ${message}`, {
      cause: error,
    });
  }

  if (isInsideWorktree !== 'true') return [];

  try {
    const output = execFileSync(
      'git',
      ['ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '-z'],
      {
        cwd: repoRoot,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      }
    );
    return output
      .split('\0')
      .filter(Boolean)
      .map((path) => normalizeRelativePath(path.replace(/\/$/, '')));
  } catch (error) {
    const message = getGitErrorMessage(error);
    throw new Error(`Unable to enumerate ignored release inputs: ${message}`, {
      cause: error,
    });
  }
}

function isIgnoredPath(relativePath, ignoredPaths) {
  const normalizedPath = normalizeRelativePath(relativePath);
  return ignoredPaths.some(
    (ignoredPath) => normalizedPath === ignoredPath || normalizedPath.startsWith(`${ignoredPath}/`)
  );
}

function walkFiles(repoRoot, treePath, excludes, ignoredPaths) {
  const absoluteRoot = join(repoRoot, treePath);
  const files = [];

  function visit(absolutePath) {
    const relativePath = normalizeRelativePath(relative(repoRoot, absolutePath));
    if (isExcluded(relativePath, excludes)) return;
    if (isIgnoredPath(relativePath, ignoredPaths)) return;

    const stats = lstatSync(absolutePath);
    if (stats.isSymbolicLink()) {
      throw new Error(`Symlink release input is unsupported: ${relativePath}`);
    }
    if (stats.isFile()) {
      files.push(relativePath);
      return;
    }
    if (!stats.isDirectory()) {
      throw new Error(`Unsupported release input type: ${relativePath}`);
    }

    for (const entry of readdirSync(absolutePath, { withFileTypes: true })) {
      visit(join(absolutePath, entry.name));
    }
  }

  visit(absoluteRoot);
  return files;
}

function assertRequiredFile(repoRoot, relativePath) {
  const normalizedPath = normalizeRelativePath(relativePath);
  const absolutePath = join(repoRoot, normalizedPath);
  if (!existsSync(absolutePath) || !lstatSync(absolutePath).isFile()) {
    throw new Error(`Missing canonical release input: ${normalizedPath}`);
  }
  return normalizedPath;
}

function assertRequiredTree(repoRoot, relativePath) {
  const normalizedPath = normalizeRelativePath(relativePath);
  const absolutePath = join(repoRoot, normalizedPath);
  if (!existsSync(absolutePath) || !lstatSync(absolutePath).isDirectory()) {
    throw new Error(`Missing canonical release input tree: ${normalizedPath}`);
  }
  return normalizedPath;
}

export function listReleaseInputFiles({ repoRoot = projectRoot, component }) {
  const resolvedRoot = resolve(repoRoot);
  const definition = getDefinition(component);
  const ignoredPaths = listIgnoredPaths(resolvedRoot);
  const files = new Set();

  for (const relativePath of definition.files) {
    const normalizedPath = assertRequiredFile(resolvedRoot, relativePath);
    if (!isExcluded(normalizedPath, definition.excludes)) files.add(normalizedPath);
  }

  for (const relativePath of definition.trees) {
    const normalizedPath = assertRequiredTree(resolvedRoot, relativePath);
    for (const file of walkFiles(resolvedRoot, normalizedPath, definition.excludes, ignoredPaths)) {
      files.add(file);
    }
  }

  return [...files].sort();
}

export function computeReleaseInputFingerprint({ repoRoot = projectRoot, component }) {
  const resolvedRoot = resolve(repoRoot);
  const files = listReleaseInputFiles({ repoRoot: resolvedRoot, component });
  const hash = createHash('sha256');

  hash.update(
    `openpath-release-inputs\0${RELEASE_INPUT_FINGERPRINT_SCHEMA_VERSION}\0${component}\0`
  );

  for (const relativePath of files) {
    const bytes = readFileSync(join(resolvedRoot, relativePath));
    const pathBytes = Buffer.byteLength(relativePath, 'utf8');
    hash.update(`file\0${pathBytes}\0${relativePath}\0${bytes.byteLength}\0`);
    hash.update(bytes);
    hash.update('\0');
  }

  return hash.digest('hex');
}

export const fingerprintReleaseInputs = computeReleaseInputFingerprint;
