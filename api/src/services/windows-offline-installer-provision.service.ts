import { createHash } from 'node:crypto';
import { lstatSync } from 'node:fs';
import { chmod, mkdir, mkdtemp, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

import {
  getWindowsOfflineInstallerTemplatePath,
  loadWindowsOfflineInstallerConfig,
  type WindowsOfflineInstallerConfig,
} from '../lib/windows-offline-installer-config.js';
import {
  loadCachedWindowsOfflineTemplate,
  getWindowsOfflineInstallerTemplateProvenancePath,
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
  verifyOnly?: boolean;
}

const TEMPLATE_FILE_NAME = 'OpenPath-Windows-Setup-Template.exe';
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
const publishLocks = new Map<string, Promise<void>>();

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

export async function cleanupStaleWindowsOfflineInstallerProvisioningDirectories(
  config: WindowsOfflineInstallerConfig
): Promise<void> {
  if (pathContainsSymlink(config.templateDir)) return;

  const scanDirectories = [config.templateDir];
  try {
    const versionEntries = await readdir(config.templateDir, { withFileTypes: true });
    for (const entry of versionEntries) {
      if (entry.isDirectory()) scanDirectories.push(path.join(config.templateDir, entry.name));
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

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (!STAGING_ROOT_PATTERN.test(entry.name) && !LEGACY_QUARANTINE_PATTERN.test(entry.name)) {
        continue;
      }
      const candidate = path.join(directory, entry.name);
      try {
        if (lstatSync(candidate).isSymbolicLink()) continue;
        const metadata = await stat(candidate);
        if (metadata.mtimeMs > cutoff) continue;
        await rm(candidate, { recursive: true, force: true });
      } catch {
        // A stale recovery directory is best effort. It is never used as a
        // published template, and a later provisioning attempt can retry it.
        logger.warn('offline_installer_template_recovery_cleanup_failed', {
          code: 'RECOVERY_CLEANUP_FAILED',
        });
      }
    }
  }
}

function isVerifiedTemplate(config: WindowsOfflineInstallerConfig, templateDir: string): boolean {
  if (templatePathContainsSymlink(config)) return false;
  try {
    loadCachedWindowsOfflineTemplate(templateDir, {
      version: config.templateVersion,
      commit: config.templateCommit,
      sha256: config.templateSha256,
      releaseTag: config.templateReleaseTag,
    });
    return true;
  } catch {
    return false;
  }
}

async function publishStagedTemplate(
  config: WindowsOfflineInstallerConfig,
  templatePath: string,
  stagingDir: string,
  renamePath: (sourcePath: string, targetPath: string) => Promise<void>
): Promise<ProvisionResult> {
  const targetDir = path.dirname(templatePath);
  return withPublishLock(templatePath, async () => {
    if (isVerifiedTemplate(config, config.templateDir)) {
      return existingTemplateResult(config, templatePath);
    }

    try {
      // Keep the canonical directory in place for readers. Each replacement
      // is atomic, and the loader/readiness code accepts the directory only
      // after the executable, sidecar, and provenance all verify together.
      assertSafeTemplatePath(config);
      await mkdir(targetDir, { recursive: true, mode: 0o755 });
      assertSafeTemplatePath(config);
      await chmod(targetDir, 0o755);

      const publishFiles = [
        TEMPLATE_FILE_NAME,
        `${TEMPLATE_FILE_NAME}.sha256`,
        `${TEMPLATE_FILE_NAME}.provenance.json`,
      ];
      for (const fileName of publishFiles) {
        try {
          await renamePath(path.join(stagingDir, fileName), path.join(targetDir, fileName));
        } catch {
          // Another process may have completed the same pinned bundle while
          // this process was publishing. Accept only a fully verified result.
          if (isVerifiedTemplate(config, config.templateDir)) {
            return existingTemplateResult(config, templatePath);
          }
          throw new Error('template file publish failed');
        }
      }
      if (!isVerifiedTemplate(config, config.templateDir)) {
        throw new Error('published template verification failed');
      }
      return {
        status: 'provisioned',
        filePath: templatePath,
        releaseTag: config.templateReleaseTag,
        sha256: config.templateSha256,
      };
    } catch {
      // Do not remove or roll back the canonical directory here. A failed
      // file replacement can leave an incomplete bundle, but readers fail
      // closed until the next complete verification. Removing the directory
      // would reintroduce an observable missing-path window and could destroy
      // a valid bundle published concurrently by another process.
      if (isVerifiedTemplate(config, config.templateDir)) {
        return existingTemplateResult(config, templatePath);
      }

      throw new WindowsOfflineInstallerProvisionError(
        'PUBLISH_FAILED',
        'Pinned template could not be published'
      );
    }
  });
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

  const templatePath = getWindowsOfflineInstallerTemplatePath(config);
  if (!options.verifyOnly) {
    await cleanupStaleWindowsOfflineInstallerProvisioningDirectories(config);
  }
  try {
    loadCachedWindowsOfflineTemplate(config.templateDir, {
      version: config.templateVersion,
      commit: config.templateCommit,
      sha256: config.templateSha256,
      releaseTag: config.templateReleaseTag,
    });
    return existingTemplateResult(config, templatePath);
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

  await resolveExactReleaseCommit(fetchImpl, config);

  const templateUrl = releaseAssetUrl(config, TEMPLATE_FILE_NAME);
  const sidecarUrl = releaseAssetUrl(config, `${TEMPLATE_FILE_NAME}.sha256`);
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
    await writeFile(path.join(stagingDir, TEMPLATE_FILE_NAME), templateBytes, { mode: 0o444 });
    await writeFile(path.join(stagingDir, `${TEMPLATE_FILE_NAME}.sha256`), sidecarBytes, {
      mode: 0o444,
    });
    await chmod(path.join(stagingDir, TEMPLATE_FILE_NAME), 0o444);
    await chmod(path.join(stagingDir, `${TEMPLATE_FILE_NAME}.sha256`), 0o444);
    const provenancePath = getWindowsOfflineInstallerTemplateProvenancePath(
      path.join(stagingDir, TEMPLATE_FILE_NAME)
    );
    await writeFile(provenancePath, `${JSON.stringify(provenanceFor(config))}\n`, { mode: 0o444 });
    await chmod(provenancePath, 0o444);

    return await publishStagedTemplate(
      config,
      templatePath,
      stagingDir,
      options.renamePath ?? rename
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
