#!/usr/bin/env node

import { existsSync, readFileSync } from 'node:fs';
import { isAbsolute, relative, resolve } from 'node:path';

function assertRecord(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
}

function requireString(value, label) {
  const normalized = String(value ?? '').trim();
  if (!normalized) throw new Error(`${label} is required`);
  return normalized;
}

function resolveContainedPath(root, relativePath, label) {
  const resolvedRoot = resolve(root);
  const resolvedPath = resolve(resolvedRoot, relativePath);
  const pathFromRoot = relative(resolvedRoot, resolvedPath);
  if (isAbsolute(pathFromRoot) || pathFromRoot === '..' || pathFromRoot.startsWith('../')) {
    throw new Error(`${label} must stay inside its root`);
  }
  return resolvedPath;
}

export function verifyGitHubReleaseAssets({
  release,
  expectedTag,
  expectedAssets,
  localRoot,
  downloadedRoot,
}) {
  assertRecord(release, 'GitHub Release');
  const normalizedExpectedTag = requireString(expectedTag, 'expectedTag');
  if (release.tag_name !== normalizedExpectedTag) {
    throw new Error(
      `GitHub Release tag ${release.tag_name} does not match expected ${normalizedExpectedTag}`
    );
  }
  if (!Array.isArray(expectedAssets) || expectedAssets.length === 0) {
    throw new Error('expectedAssets must contain at least one authoritative asset');
  }
  if (!Array.isArray(release.assets)) {
    throw new Error('GitHub Release assets are missing');
  }

  const remoteNames = new Set();
  for (const asset of release.assets) {
    assertRecord(asset, 'GitHub Release asset');
    const name = requireString(asset.name, 'GitHub Release asset.name');
    if (remoteNames.has(name)) throw new Error(`GitHub Release has duplicate asset ${name}`);
    remoteNames.add(name);
  }

  const verifiedNames = [];
  for (const expectedAsset of expectedAssets) {
    assertRecord(expectedAsset, 'expected release asset');
    const name = requireString(expectedAsset.name, 'expected release asset.name');
    if (remoteNames.has(name) === false) {
      throw new Error(`GitHub Release is missing authoritative asset ${name}`);
    }
    const localPath = resolveContainedPath(
      localRoot,
      requireString(expectedAsset.localPath, `local path for ${name}`),
      `local path for ${name}`
    );
    const downloadedPath = resolveContainedPath(
      downloadedRoot,
      name,
      `downloaded path for ${name}`
    );
    if (!existsSync(localPath))
      throw new Error(`Local authoritative asset is missing: ${localPath}`);
    if (!existsSync(downloadedPath)) {
      throw new Error(`Downloaded authoritative asset is missing: ${downloadedPath}`);
    }
    const localBytes = readFileSync(localPath);
    const downloadedBytes = readFileSync(downloadedPath);
    if (Buffer.compare(localBytes, downloadedBytes) !== 0) {
      throw new Error(`GitHub Release asset ${name} has different bytes`);
    }
    verifiedNames.push(name);
  }

  return { status: 'identical', assets: verifiedNames };
}

function parseCliArgs(argv) {
  const parsed = { assets: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg !== '--asset' && !arg.startsWith('--')) throw new Error(`Unknown argument: ${arg}`);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) {
      throw new Error(`Value is required for ${arg}`);
    }
    if (arg === '--asset') parsed.assets.push(value);
    else parsed[arg.slice(2)] = value;
    index += 1;
  }
  return parsed;
}

function requireArgument(args, name) {
  return requireString(args[name], `--${name}`);
}

function runCli() {
  const [command, ...rawArgs] = process.argv.slice(2);
  if (!command) return;
  if (command !== 'verify-existing-release') {
    throw new Error(`Unknown release asset verifier command: ${command}`);
  }
  const args = parseCliArgs(rawArgs);
  const expectedAssets = args.assets.map((asset) => {
    const separator = asset.indexOf('=');
    if (separator < 1) throw new Error(`--asset must use NAME=LOCAL_PATH: ${asset}`);
    return { name: asset.slice(0, separator), localPath: asset.slice(separator + 1) };
  });
  const result = verifyGitHubReleaseAssets({
    release: JSON.parse(readFileSync(requireArgument(args, 'release-json'), 'utf8')),
    expectedTag: requireArgument(args, 'expected-tag'),
    expectedAssets,
    localRoot: requireArgument(args, 'local-root'),
    downloadedRoot: requireArgument(args, 'downloaded-root'),
  });
  console.log(`Verified existing GitHub Release assets: ${result.assets.join(', ')}`);
}

runCli();
