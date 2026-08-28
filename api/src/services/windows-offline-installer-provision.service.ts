import { createHash, randomUUID } from 'node:crypto';
import { lstatSync, readFileSync } from 'node:fs';
import {
  chmod,
  mkdir,
  mkdtemp,
  open,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises';
import type { FileHandle } from 'node:fs/promises';
import path from 'node:path';

import {
  getWindowsOfflineInstallerTemplatePath,
  loadWindowsOfflineInstallerConfig,
  type WindowsOfflineInstallerConfig,
} from '../lib/windows-offline-installer-config.js';
import {
  loadCachedWindowsOfflineTemplate,
  loadWindowsOfflineTemplateBundle,
  getWindowsOfflineInstallerTemplateProvenancePath,
  WINDOWS_OFFLINE_TEMPLATE_CURRENT_FILE_NAME,
  WINDOWS_OFFLINE_TEMPLATE_FILE_NAME,
  WINDOWS_OFFLINE_TEMPLATE_GENERATIONS_DIR_NAME,
  type CachedWindowsOfflineTemplate,
  type WindowsOfflineTemplateProvenance,
  WindowsOfflineTemplateCacheError,
} from '../lib/windows-offline-installer-template.js';
import { logger } from '../lib/logger.js';

export type WindowsOfflineInstallerProvisionErrorCode =
  | 'CONFIG_INVALID'
  | 'TEMPLATE_MISSING'
  | 'DOWNLOAD_FAILED'
  | 'HASH_MISMATCH'
  | 'PROVENANCE_MISSING'
  | 'PROVENANCE_INVALID'
  | 'PROVENANCE_MISMATCH'
  | 'PUBLISH_FAILED';

export class WindowsOfflineInstallerProvisionError extends Error {
  readonly code: WindowsOfflineInstallerProvisionErrorCode;

  constructor(code: WindowsOfflineInstallerProvisionErrorCode, message: string) {
    super(message);
    this.code = code;
    this.name = 'WindowsOfflineInstallerProvisionError';
  }
}

export interface ProvisionResult {
  status: 'verified' | 'provisioned';
  filePath: string;
  releaseTag: string;
  sha256: string;
}

export interface ProvisionOptions {
  env?: Readonly<Record<string, string | undefined>>;
  fetchImpl?: typeof fetch;
  renamePath?: (sourcePath: string, targetPath: string) => Promise<void>;
  writeFileImpl?: (
    filePath: string,
    data: string | Buffer,
    options?: { mode?: number }
  ) => Promise<void>;
  verifyOnly?: boolean;
}

const HEX_SHA256 = /^[0-9a-f]{64}$/u;
const GITHUB_ASSET_HOSTS = new Set([
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
]);
const FULL_COMMIT_SHA = /^[0-9a-f]{40}$/u;
const STALE_PUBLISH_RETENTION_MS = 24 * 60 * 60 * 1000;
const STAGING_ROOT_PATTERN = /^\.openpath-windows-template-[A-Za-z0-9]+$/u;
const LEGACY_QUARANTINE_PATTERN = /^\.[0-9a-f]{40}-[0-9a-f-]{36}\.quarantine$/u;
const GENERATION_PATTERN =
  /^generation-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const ABANDONED_GENERATION_PATTERN = /^generation-[A-Za-z0-9._-]+$/u;
const POINTER_TEMP_PATTERN = /^\.current\.[0-9a-f-]+\.tmp$/u;
const PUBLISH_LOCK_FILE_NAME = '.publish.lock';
const PUBLISH_LOCK_STALE_MS = 10 * 60 * 1000;
const PUBLISH_LOCK_WAIT_MS = 30 * 1000;
const PUBLISH_LOCK_RETRY_MS = 25;
const publishLocks = new Map<string, Promise<void>>();

function errorCode(error: unknown): unknown {
  return typeof error === 'object' && error !== null && 'code' in error
    ? (error as { code?: unknown }).code
    : undefined;
}

function isMissingPathError(error: unknown): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    (error as { code?: unknown }).code === 'ENOENT'
  );
}

function pathContainsSymlink(filePath: string): boolean {
  const absolutePath = path.resolve(filePath);
  const parsed = path.parse(absolutePath);
  let current = parsed.root;
  const relativeParts = absolutePath.slice(parsed.root.length).split(path.sep).filter(Boolean);

  for (const part of relativeParts) {
    current = path.join(current, part);
    try {
      if (lstatSync(current).isSymbolicLink()) return true;
    } catch (error) {
      if (isMissingPathError(error)) return false;
      return true;
    }
  }
  return false;
}

function templatePathContainsSymlink(config: WindowsOfflineInstallerConfig): boolean {
  return (
    pathContainsSymlink(config.templateDir) ||
    pathContainsSymlink(path.join(config.templateDir, config.templateVersion)) ||
    pathContainsSymlink(
      path.join(config.templateDir, config.templateVersion, config.templateCommit)
    )
  );
}

function assertSafeTemplatePath(config: WindowsOfflineInstallerConfig): void {
  if (templatePathContainsSymlink(config)) {
    throw new WindowsOfflineInstallerProvisionError(
      'PUBLISH_FAILED',
      'Pinned template path contains an unsupported symbolic link'
    );
  }
}

async function withPublishLock<T>(key: string, operation: () => Promise<T>): Promise<T> {
  const previous = publishLocks.get(key) ?? Promise.resolve();
  let release!: () => void;
  const current = new Promise<void>((resolve) => {
    release = resolve;
  });
  publishLocks.set(key, current);
  await previous;
  try {
    return await operation();
  } finally {
    release();
    if (publishLocks.get(key) === current) publishLocks.delete(key);
  }
}

function processIsAlive(pid: number): boolean {
  if (pid === process.pid) return true;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return errorCode(error) !== 'ESRCH';
  }
}

async function isStaleFilesystemLock(lockPath: string): Promise<boolean> {
  let lockStat;
  try {
    lockStat = await stat(lockPath);
  } catch (error) {
    return errorCode(error) === 'ENOENT';
  }

  try {
    const lockHandle = await open(lockPath, 'r');
    try {
      const contents = await lockHandle.readFile('utf8');
      const parsed: unknown = JSON.parse(contents);
      const pid =
        typeof parsed === 'object' && parsed !== null && 'pid' in parsed
          ? (parsed as { pid?: unknown }).pid
          : undefined;
      if (typeof pid === 'number' && Number.isInteger(pid) && !processIsAlive(pid)) return true;
      if (Date.now() - lockStat.mtimeMs <= PUBLISH_LOCK_STALE_MS) return false;
      return typeof pid !== 'number' || !Number.isInteger(pid);
    } finally {
      await lockHandle.close();
    }
  } catch {
    // A creator owns the file immediately after the exclusive open, before it
    // can write its PID. Treat a fresh malformed/empty lock as live; only an
    // old unreadable lock may be reclaimed after a crash.
    return Date.now() - lockStat.mtimeMs > PUBLISH_LOCK_STALE_MS;
  }
}

async function wait(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

async function reclaimStaleFilesystemLock(lockPath: string): Promise<boolean> {
  const reclaimedPath = `${lockPath}.${String(process.pid)}-${randomUUID()}.stale`;
  try {
    // Rename claims the exact lock entry before removing it. A check followed
    // by unlink could delete a new owner's lock between those two operations.
    await rename(lockPath, reclaimedPath);
  } catch (error) {
    return errorCode(error) === 'ENOENT';
  }
  await rm(reclaimedPath, { force: true });
  return true;
}

async function acquireFilesystemPublishLock(lockPath: string): Promise<() => Promise<void>> {
  const deadline = Date.now() + PUBLISH_LOCK_WAIT_MS;
  while (Date.now() < deadline) {
    let lockHandle: FileHandle | undefined;
    let lockCreated = false;
    try {
      lockHandle = await open(lockPath, 'wx', 0o600);
      lockCreated = true;
      await lockHandle.writeFile(
        JSON.stringify({ pid: process.pid, createdAt: new Date().toISOString() })
      );
      await lockHandle.sync();
      const ownedLockHandle = lockHandle;
      let released = false;
      return async (): Promise<void> => {
        if (released) return;
        released = true;
        try {
          await ownedLockHandle.close();
        } finally {
          await rm(lockPath, { force: true });
        }
      };
    } catch (error) {
      try {
        await lockHandle?.close();
      } catch {
        // The acquisition failed before the handle could be closed.
      }
      if (lockCreated) await rm(lockPath, { force: true });
      if (errorCode(error) !== 'EEXIST') {
        throw new Error('template publish lock acquisition failed', { cause: error });
      }
      if ((await isStaleFilesystemLock(lockPath)) && (await reclaimStaleFilesystemLock(lockPath))) {
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error('template publish lock timeout', { cause: error });
      }
      await wait(PUBLISH_LOCK_RETRY_MS);
    }
  }
  throw new Error('template publish lock timeout');
}

async function withFilesystemPublishLock<T>(
  lockPath: string,
  operation: () => Promise<T>
): Promise<T> {
  const release = await acquireFilesystemPublishLock(lockPath);
  try {
    return await operation();
  } finally {
    await release();
  }
}

async function syncFile(filePath: string): Promise<void> {
  const handle = await open(filePath, 'r');
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function syncDirectory(directoryPath: string): Promise<void> {
  try {
    const handle = await open(directoryPath, 'r');
    try {
      await handle.sync();
    } finally {
      await handle.close();
    }
  } catch (error) {
    const code = errorCode(error);
    if (code !== 'EINVAL' && code !== 'ENOTSUP' && code !== 'EISDIR') throw error;
  }
}

function mapTemplateError(
  error: WindowsOfflineTemplateCacheError
):
  | 'TEMPLATE_MISSING'
  | 'HASH_MISMATCH'
  | 'PROVENANCE_MISSING'
  | 'PROVENANCE_INVALID'
  | 'PROVENANCE_MISMATCH' {
  if (error.code === 'TEMPLATE_MISSING' || error.code === 'SIDECAR_MISSING') {
    return 'TEMPLATE_MISSING';
  }
  if (error.code === 'PROVENANCE_MISSING') return 'PROVENANCE_MISSING';
  if (error.code === 'PROVENANCE_INVALID') return 'PROVENANCE_INVALID';
  if (error.code === 'PROVENANCE_MISMATCH') return 'PROVENANCE_MISMATCH';
  return 'HASH_MISMATCH';
}

function releaseAssetUrl(config: WindowsOfflineInstallerConfig, fileName: string): string {
  return `https://github.com/${config.githubRepo}/releases/download/${encodeURIComponent(config.templateReleaseTag)}/${fileName}`;
}

async function fetchBytes(fetchImpl: typeof fetch, url: string): Promise<Buffer> {
  let response: Response;
  try {
    response = await fetchImpl(url, { redirect: 'follow' });
  } catch {
    throw new WindowsOfflineInstallerProvisionError('DOWNLOAD_FAILED', 'Template download failed');
  }
  if (!response.ok) {
    throw new WindowsOfflineInstallerProvisionError('DOWNLOAD_FAILED', 'Template download failed');
  }

  validateReleaseRedirect(url, response.url);

  try {
    return Buffer.from(await response.arrayBuffer());
  } catch {
    throw new WindowsOfflineInstallerProvisionError('DOWNLOAD_FAILED', 'Template download failed');
  }
}

async function resolveExactReleaseCommit(
  fetchImpl: typeof fetch,
  config: WindowsOfflineInstallerConfig
): Promise<void> {
  const refUrl =
    `https://api.github.com/repos/${config.githubRepo}/git/ref/tags/` +
    encodeURIComponent(config.templateReleaseTag);
  let response: Response;
  try {
    response = await fetchImpl(refUrl, {
      redirect: 'error',
      headers: {
        accept: 'application/vnd.github+json',
        'user-agent': 'OpenPath-installer-provisioner',
      },
    });
  } catch {
    throw new WindowsOfflineInstallerProvisionError(
      'DOWNLOAD_FAILED',
      'Template provenance lookup failed'
    );
  }
  if (!response.ok) {
    throw new WindowsOfflineInstallerProvisionError(
      'DOWNLOAD_FAILED',
      'Pinned release tag could not be resolved'
    );
  }

  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new WindowsOfflineInstallerProvisionError(
      'PROVENANCE_MISMATCH',
      'Pinned release tag metadata is invalid'
    );
  }

  if (typeof body !== 'object' || body === null || !('object' in body)) {
    throw new WindowsOfflineInstallerProvisionError(
      'PROVENANCE_MISMATCH',
      'Pinned release tag metadata is invalid'
    );
  }

  const tagObject = body.object;
  if (
    typeof tagObject !== 'object' ||
    tagObject === null ||
    !('type' in tagObject) ||
    !('sha' in tagObject) ||
    typeof tagObject.type !== 'string' ||
    typeof tagObject.sha !== 'string'
  ) {
    throw new WindowsOfflineInstallerProvisionError(
      'PROVENANCE_MISMATCH',
      'Pinned release tag metadata is invalid'
    );
  }
  if (tagObject.type !== 'commit' && tagObject.type !== 'tag') {
    throw new WindowsOfflineInstallerProvisionError(
      'PROVENANCE_MISMATCH',
      'Pinned release tag does not point to a commit'
    );
  }

  let resolvedCommit = tagObject.sha;
  if (tagObject.type === 'tag') {
    const tagUrl = `https://api.github.com/repos/${config.githubRepo}/git/tags/${encodeURIComponent(tagObject.sha)}`;
    let tagResponse: Response;
    try {
      tagResponse = await fetchImpl(tagUrl, {
        redirect: 'error',
        headers: {
          accept: 'application/vnd.github+json',
          'user-agent': 'OpenPath-installer-provisioner',
        },
      });
    } catch {
      throw new WindowsOfflineInstallerProvisionError(
        'DOWNLOAD_FAILED',
        'Annotated release tag provenance lookup failed'
      );
    }
    if (!tagResponse.ok) {
      throw new WindowsOfflineInstallerProvisionError(
        'DOWNLOAD_FAILED',
        'Annotated release tag provenance could not be resolved'
      );
    }
    try {
      const annotatedBody: unknown = await tagResponse.json();
      if (
        typeof annotatedBody !== 'object' ||
        annotatedBody === null ||
        !('object' in annotatedBody) ||
        typeof annotatedBody.object !== 'object' ||
        annotatedBody.object === null ||
        !('type' in annotatedBody.object) ||
        !('sha' in annotatedBody.object) ||
        annotatedBody.object.type !== 'commit' ||
        typeof annotatedBody.object.sha !== 'string'
      ) {
        throw new Error('invalid annotated tag');
      }
      resolvedCommit = annotatedBody.object.sha;
    } catch {
      throw new WindowsOfflineInstallerProvisionError(
        'PROVENANCE_MISMATCH',
        'Annotated release tag provenance is invalid'
      );
    }
  }

  if (!FULL_COMMIT_SHA.test(resolvedCommit) || resolvedCommit !== config.templateCommit) {
    throw new WindowsOfflineInstallerProvisionError(
      'PROVENANCE_MISMATCH',
      'Pinned release tag does not resolve to the configured full commit'
    );
  }
}

function validateReleaseRedirect(initialUrl: string, finalUrl: string): void {
  if (!finalUrl) return;

  let initial: URL;
  let final: URL;
  try {
    initial = new URL(initialUrl);
    final = new URL(finalUrl);
  } catch {
    throw new WindowsOfflineInstallerProvisionError(
      'DOWNLOAD_FAILED',
      'Template download redirected to an invalid URL'
    );
  }

  if (final.protocol !== 'https:' || !GITHUB_ASSET_HOSTS.has(final.hostname.toLowerCase())) {
    throw new WindowsOfflineInstallerProvisionError(
      'DOWNLOAD_FAILED',
      'Template download redirected outside GitHub asset storage'
    );
  }

  const initialReleasePath = initial.pathname;
  const finalIsLogicalRelease = final.pathname.includes('/releases/download/');
  if (
    (final.origin === initial.origin &&
      (final.pathname !== initialReleasePath || final.search !== initial.search)) ||
    (final.origin !== initial.origin && finalIsLogicalRelease)
  ) {
    throw new WindowsOfflineInstallerProvisionError(
      'DOWNLOAD_FAILED',
      'Template download redirected to a different release asset'
    );
  }
}

function parseSidecarDigest(sidecar: Buffer): string {
  const digest = sidecar.toString('utf8').trim().split(/\s+/u)[0]?.toLowerCase();
  if (!digest || !HEX_SHA256.test(digest)) {
    throw new WindowsOfflineInstallerProvisionError('HASH_MISMATCH', 'Template checksum invalid');
  }
  return digest;
}

function hashBytes(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

function verifyPinnedBytes(
  templateBytes: Buffer,
  sidecarBytes: Buffer,
  expectedSha256: string
): void {
  const sidecarDigest = parseSidecarDigest(sidecarBytes);
  const actualDigest = hashBytes(templateBytes);
  if (sidecarDigest !== expectedSha256 || actualDigest !== expectedSha256) {
    throw new WindowsOfflineInstallerProvisionError('HASH_MISMATCH', 'Template checksum mismatch');
  }
}

function existingTemplateResult(
  config: WindowsOfflineInstallerConfig,
  filePath: string
): ProvisionResult {
  return {
    status: 'verified',
    filePath,
    releaseTag: config.templateReleaseTag,
    sha256: config.templateSha256,
  };
}

function provenanceFor(config: WindowsOfflineInstallerConfig): WindowsOfflineTemplateProvenance {
  return {
    version: config.templateVersion,
    commit: config.templateCommit,
    releaseTag: config.templateReleaseTag,
    sha256: config.templateSha256,
  };
}

function currentGenerationName(commitDirectory: string): string | null | undefined {
  const currentPath = path.join(commitDirectory, WINDOWS_OFFLINE_TEMPLATE_CURRENT_FILE_NAME);
  let currentStat;
  try {
    currentStat = lstatSync(currentPath);
  } catch (error) {
    return isMissingPathError(error) ? null : undefined;
  }
  if (!currentStat.isFile() || currentStat.isSymbolicLink()) return undefined;
  try {
    const value = readFileSync(currentPath, 'utf8').trim();
    return GENERATION_PATTERN.test(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

async function removeIfStale(candidate: string, cutoff: number): Promise<void> {
  try {
    if (lstatSync(candidate).isSymbolicLink()) return;
    if ((await stat(candidate)).mtimeMs > cutoff) return;
    await rm(candidate, { recursive: true, force: true });
  } catch {
    logger.warn('offline_installer_template_recovery_cleanup_failed', {
      code: 'RECOVERY_CLEANUP_FAILED',
    });
  }
}

async function cleanupGenerationDirectory(
  generationsDirectory: string,
  currentName: string,
  cutoff: number
): Promise<void> {
  let entries;
  try {
    entries = await readdir(generationsDirectory, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name === currentName) continue;
    if (!ABANDONED_GENERATION_PATTERN.test(entry.name)) continue;
    await removeIfStale(path.join(generationsDirectory, entry.name), cutoff);
  }
}

export async function cleanupStaleWindowsOfflineInstallerProvisioningDirectories(
  config: WindowsOfflineInstallerConfig
): Promise<void> {
  if (pathContainsSymlink(config.templateDir)) return;

  const scanDirectories = [config.templateDir];
  try {
    const versionEntries = await readdir(config.templateDir, { withFileTypes: true });
    for (const versionEntry of versionEntries) {
      if (!versionEntry.isDirectory()) continue;
      const versionDirectory = path.join(config.templateDir, versionEntry.name);
      scanDirectories.push(versionDirectory);
      try {
        const commitEntries = await readdir(versionDirectory, { withFileTypes: true });
        for (const commitEntry of commitEntries) {
          if (commitEntry.isDirectory()) {
            scanDirectories.push(path.join(versionDirectory, commitEntry.name));
          }
        }
      } catch {
        // A missing or concurrently removed version directory is harmless.
      }
    }
  } catch {
    return;
  }
  const cutoff = Date.now() - STALE_PUBLISH_RETENTION_MS;

  for (const directory of scanDirectories) {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch {
      continue;
    }

    const currentName = currentGenerationName(directory);
    for (const entry of entries) {
      const candidate = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (STAGING_ROOT_PATTERN.test(entry.name) || LEGACY_QUARANTINE_PATTERN.test(entry.name)) {
          await removeIfStale(candidate, cutoff);
        } else if (entry.name === WINDOWS_OFFLINE_TEMPLATE_GENERATIONS_DIR_NAME) {
          // If the pointer is malformed, preserve every generation. Cleanup
          // must never destroy the only recoverable copy after a crash.
          if (currentName !== null && currentName !== undefined) {
            await cleanupGenerationDirectory(candidate, currentName, cutoff);
          }
        }
      } else if (POINTER_TEMP_PATTERN.test(entry.name)) {
        await removeIfStale(candidate, cutoff);
      } else if (entry.name === PUBLISH_LOCK_FILE_NAME) {
        if (await isStaleFilesystemLock(candidate)) await reclaimStaleFilesystemLock(candidate);
      }
    }
  }
}

function verifiedTemplate(
  config: WindowsOfflineInstallerConfig
): CachedWindowsOfflineTemplate | null {
  if (templatePathContainsSymlink(config)) return null;
  try {
    return loadCachedWindowsOfflineTemplate(config.templateDir, {
      version: config.templateVersion,
      commit: config.templateCommit,
      sha256: config.templateSha256,
      releaseTag: config.templateReleaseTag,
    });
  } catch {
    return null;
  }
}

function assertSafePublicationPaths(config: WindowsOfflineInstallerConfig): void {
  assertSafeTemplatePath(config);
  const canonicalDirectory = path.dirname(getWindowsOfflineInstallerTemplatePath(config));
  const generationsDirectory = path.join(
    canonicalDirectory,
    WINDOWS_OFFLINE_TEMPLATE_GENERATIONS_DIR_NAME
  );
  const currentPath = path.join(canonicalDirectory, WINDOWS_OFFLINE_TEMPLATE_CURRENT_FILE_NAME);
  if (pathContainsSymlink(generationsDirectory) || pathContainsSymlink(currentPath)) {
    throw new WindowsOfflineInstallerProvisionError(
      'PUBLISH_FAILED',
      'Pinned template publication path contains an unsupported symbolic link'
    );
  }
}

type ProvisionWriteFile = (
  filePath: string,
  data: string | Buffer,
  options?: { mode?: number }
) => Promise<void>;

async function publishStagedTemplate(
  config: WindowsOfflineInstallerConfig,
  stagingDir: string,
  renamePath: (sourcePath: string, targetPath: string) => Promise<void>,
  writeFileImpl: ProvisionWriteFile
): Promise<ProvisionResult> {
  const canonicalTemplatePath = getWindowsOfflineInstallerTemplatePath(config);
  const targetDir = path.dirname(canonicalTemplatePath);
  const generationsDirectory = path.join(targetDir, WINDOWS_OFFLINE_TEMPLATE_GENERATIONS_DIR_NAME);
  const currentPath = path.join(targetDir, WINDOWS_OFFLINE_TEMPLATE_CURRENT_FILE_NAME);
  const lockPath = path.join(targetDir, PUBLISH_LOCK_FILE_NAME);

  return (async (): Promise<ProvisionResult> => {
    assertSafePublicationPaths(config);
    await mkdir(targetDir, { recursive: true, mode: 0o755 });
    await chmod(targetDir, 0o755);
    assertSafePublicationPaths(config);

    return withPublishLock(targetDir, async () =>
      withFilesystemPublishLock(lockPath, async () => {
        const existing = verifiedTemplate(config);
        if (existing) return existingTemplateResult(config, existing.filePath);

        try {
          assertSafePublicationPaths(config);
          await mkdir(targetDir, { recursive: true, mode: 0o755 });
          await chmod(targetDir, 0o755);
          assertSafePublicationPaths(config);
          await mkdir(generationsDirectory, { recursive: true, mode: 0o755 });
          await chmod(generationsDirectory, 0o755);
          assertSafePublicationPaths(config);

          // The staging directory is validated as a complete bundle before it
          // is made reachable from the canonical pointer.
          loadWindowsOfflineTemplateBundle(stagingDir, {
            version: config.templateVersion,
            commit: config.templateCommit,
            sha256: config.templateSha256,
            releaseTag: config.templateReleaseTag,
          });

          const generationName = `generation-${randomUUID()}`;
          const generationPath = path.join(generationsDirectory, generationName);
          assertSafePublicationPaths(config);
          await renamePath(stagingDir, generationPath);
          await syncDirectory(generationsDirectory);
          await syncDirectory(targetDir);

          const pointerTempPath = path.join(targetDir, `.current.${randomUUID()}.tmp`);
          try {
            await writeFileImpl(pointerTempPath, `${generationName}\n`, { mode: 0o444 });
            await chmod(pointerTempPath, 0o444);
            await syncFile(pointerTempPath);
            // This is the single observable commit. Readers resolve one
            // immutable generation through this pointer and never combine files.
            await renamePath(pointerTempPath, currentPath);
            await syncDirectory(targetDir);
          } finally {
            await rm(pointerTempPath, { force: true });
          }

          const published = verifiedTemplate(config);
          if (!published) throw new Error('published template verification failed');
          return {
            status: 'provisioned',
            filePath: published.filePath,
            releaseTag: config.templateReleaseTag,
            sha256: config.templateSha256,
          };
        } catch {
          // A failed preparation or pointer commit cannot affect an already
          // committed generation. Accept a concurrent complete publication only.
          const preserved = verifiedTemplate(config);
          if (preserved) return existingTemplateResult(config, preserved.filePath);
          throw new WindowsOfflineInstallerProvisionError(
            'PUBLISH_FAILED',
            'Pinned template could not be published'
          );
        }
      })
    );
  })();
}

export async function provisionWindowsOfflineInstallerTemplate(
  options: ProvisionOptions = {}
): Promise<ProvisionResult> {
  let config: WindowsOfflineInstallerConfig;
  try {
    config = loadWindowsOfflineInstallerConfig(options.env);
  } catch {
    throw new WindowsOfflineInstallerProvisionError(
      'CONFIG_INVALID',
      'Windows offline installer configuration invalid'
    );
  }

  if (!options.verifyOnly) {
    await cleanupStaleWindowsOfflineInstallerProvisioningDirectories(config);
  }
  try {
    const cached = loadCachedWindowsOfflineTemplate(config.templateDir, {
      version: config.templateVersion,
      commit: config.templateCommit,
      sha256: config.templateSha256,
      releaseTag: config.templateReleaseTag,
    });
    return existingTemplateResult(config, cached.filePath);
  } catch (error) {
    const code =
      error instanceof WindowsOfflineTemplateCacheError
        ? mapTemplateError(error)
        : ('TEMPLATE_MISSING' as const);
    if (options.verifyOnly) {
      throw new WindowsOfflineInstallerProvisionError(code, 'Pinned template is not ready');
    }
  }

  // Reject an existing symlink in the configured path before any recursive
  // mkdir can follow it into a directory outside the template root.
  assertSafeTemplatePath(config);

  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  const writeFileImpl: ProvisionWriteFile =
    options.writeFileImpl ??
    (async (filePath, data, writeOptions): Promise<void> => {
      await writeFile(filePath, data, writeOptions);
    });

  await resolveExactReleaseCommit(fetchImpl, config);

  const templateUrl = releaseAssetUrl(config, WINDOWS_OFFLINE_TEMPLATE_FILE_NAME);
  const sidecarUrl = releaseAssetUrl(config, `${WINDOWS_OFFLINE_TEMPLATE_FILE_NAME}.sha256`);
  const [templateBytes, sidecarBytes] = await Promise.all([
    fetchBytes(fetchImpl, templateUrl),
    fetchBytes(fetchImpl, sidecarUrl),
  ]);
  verifyPinnedBytes(templateBytes, sidecarBytes, config.templateSha256);

  await mkdir(config.templateDir, { recursive: true, mode: 0o755 });
  assertSafeTemplatePath(config);
  await chmod(config.templateDir, 0o755);
  assertSafeTemplatePath(config);
  await mkdir(path.join(config.templateDir, config.templateVersion), {
    recursive: true,
    mode: 0o755,
  });
  assertSafeTemplatePath(config);
  await chmod(path.join(config.templateDir, config.templateVersion), 0o755);

  // Keep staging on the mounted template volume so the final rename remains
  // atomic in Docker and other deployments where /tmp is another filesystem.
  const stagingRoot = await mkdtemp(path.join(config.templateDir, '.openpath-windows-template-'));
  const stagingDir = path.join(stagingRoot, config.templateCommit);
  try {
    await mkdir(stagingDir, { recursive: true, mode: 0o755 });
    await chmod(stagingDir, 0o755);
    const stagedTemplatePath = path.join(stagingDir, WINDOWS_OFFLINE_TEMPLATE_FILE_NAME);
    const stagedSidecarPath = `${stagedTemplatePath}.sha256`;
    await writeFileImpl(stagedTemplatePath, templateBytes, { mode: 0o444 });
    await writeFileImpl(stagedSidecarPath, sidecarBytes, {
      mode: 0o444,
    });
    await chmod(stagedTemplatePath, 0o444);
    await chmod(stagedSidecarPath, 0o444);
    const provenancePath = getWindowsOfflineInstallerTemplateProvenancePath(stagedTemplatePath);
    await writeFileImpl(provenancePath, `${JSON.stringify(provenanceFor(config))}\n`, {
      mode: 0o444,
    });
    await chmod(provenancePath, 0o444);
    await syncFile(stagedTemplatePath);
    await syncFile(stagedSidecarPath);
    await syncFile(provenancePath);
    await syncDirectory(stagingDir);

    return await publishStagedTemplate(
      config,
      stagingDir,
      options.renamePath ?? rename,
      writeFileImpl
    );
  } catch (error) {
    if (error instanceof WindowsOfflineInstallerProvisionError) throw error;
    throw new WindowsOfflineInstallerProvisionError(
      'PUBLISH_FAILED',
      'Pinned template could not be prepared for publication'
    );
  } finally {
    await rm(stagingRoot, { recursive: true, force: true });
  }
}

export function formatProvisionResult(result: ProvisionResult): string {
  return JSON.stringify({
    status: result.status,
    releaseTag: result.releaseTag,
    sha256: result.sha256,
  });
}
