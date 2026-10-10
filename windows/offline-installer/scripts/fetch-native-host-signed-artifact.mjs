#!/usr/bin/env node
// Phase 8: stages the prebuilt signed native host for the current C# source
// hash into windows/native-host/signed/ before the offline payload manifest
// and the windows zip are built.
//
// The signed assets live as release assets on the rolling `native-host-signing`
// GitHub release (Actions artifacts expire; a release asset does not). The
// signing workflow uploads:
//   OpenPath-NativeHost-<sourceSha256>.exe
//   OpenPath-NativeHost-<sourceSha256>.signing.json
//
// Missing assets are NOT an error: the template and the zip ship without the
// signed host (payload manifest nativeHostSigned:false) until the signing
// channel produces that hash. An internally inconsistent staged pair IS an
// error and fails the release build.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const SIGNING_RELEASE_TAG = 'native-host-signing';
export const NATIVE_HOST_SOURCE_RELATIVE_PATH = 'windows/native-host/OpenPathNativeHost.cs';
export const SIGNED_EXECUTABLE_NAME = 'OpenPath-NativeHost.exe';
export const SIGNED_METADATA_NAME = 'OpenPath-NativeHost.signing.json';

export function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

export function signedAssetNames(sourceSha256) {
  return {
    executable: `OpenPath-NativeHost-${sourceSha256}.exe`,
    metadata: `OpenPath-NativeHost-${sourceSha256}.signing.json`,
  };
}

export function validateSigningMetadata({ sourceSha256, executablePath, metadataPath }) {
  let metadata;
  try {
    metadata = JSON.parse(readFileSync(metadataPath, 'utf8'));
  } catch (error) {
    return { ok: false, error: `unreadable signing metadata: ${error.message}` };
  }
  const metadataSource = String(metadata.sourceSha256 ?? '').toLowerCase();
  if (metadataSource !== sourceSha256) {
    return {
      ok: false,
      error: `signing metadata is for source ${metadataSource || '<missing>'}, expected ${sourceSha256}`,
    };
  }
  const executableSha256 = sha256File(executablePath);
  const metadataExecutable = String(metadata.executableSha256 ?? '').toLowerCase();
  if (metadataExecutable !== executableSha256) {
    return {
      ok: false,
      error: `signed executable ${executableSha256} does not match its metadata ${metadataExecutable || '<missing>'}`,
    };
  }
  return { ok: true, executableSha256, metadata };
}

function defaultGhRunner(args) {
  return execFileSync('gh', args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

export function fetchSignedNativeHost({
  repoRoot,
  releaseTag = SIGNING_RELEASE_TAG,
  runGh = defaultGhRunner,
  log = console.log,
}) {
  const sourcePath = join(repoRoot, NATIVE_HOST_SOURCE_RELATIVE_PATH);
  if (!existsSync(sourcePath)) {
    throw new Error(`native host source not found: ${sourcePath}`);
  }
  const sourceSha256 = sha256File(sourcePath);
  const assets = signedAssetNames(sourceSha256);

  let listing;
  try {
    listing = runGh([
      'api',
      `repos/{owner}/{repo}/releases/tags/${releaseTag}`,
      '--jq',
      '.assets[].name',
    ]);
  } catch {
    log(`No ${releaseTag} release yet; shipping without a signed native host (${sourceSha256}).`);
    return { signed: false, sourceSha256 };
  }
  const assetNames = String(listing)
    .split(/\r?\n/u)
    .map((name) => name.trim())
    .filter(Boolean);
  if (!assetNames.includes(assets.executable) || !assetNames.includes(assets.metadata)) {
    log(`No signed native host assets for ${sourceSha256}; shipping without them.`);
    return { signed: false, sourceSha256 };
  }

  const stagingDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-signed-'));
  try {
    runGh([
      'release',
      'download',
      releaseTag,
      '--pattern',
      assets.executable,
      '--pattern',
      assets.metadata,
      '--dir',
      stagingDir,
      '--clobber',
    ]);
    const validation = validateSigningMetadata({
      sourceSha256,
      executablePath: join(stagingDir, assets.executable),
      metadataPath: join(stagingDir, assets.metadata),
    });
    if (!validation.ok) {
      throw new Error(validation.error);
    }
    const outDir = join(repoRoot, 'windows', 'native-host', 'signed');
    mkdirSync(outDir, { recursive: true });
    copyFileSync(join(stagingDir, assets.executable), join(outDir, SIGNED_EXECUTABLE_NAME));
    copyFileSync(join(stagingDir, assets.metadata), join(outDir, SIGNED_METADATA_NAME));
    log(`Staged signed native host ${validation.executableSha256} for source ${sourceSha256}.`);
    return { signed: true, sourceSha256, executableSha256: validation.executableSha256 };
  } finally {
    rmSync(stagingDir, { recursive: true, force: true });
  }
}

function parseArgs(argv) {
  const args = {};
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith('--')) continue;
    args[arg.slice(2)] = argv[index + 1];
    index += 1;
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv);
  const repoRoot = resolve(args['repo-root'] ?? '.');
  fetchSignedNativeHost({
    repoRoot,
    releaseTag: args['release-tag'] ?? SIGNING_RELEASE_TAG,
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
