import { createHash } from 'node:crypto';
import { chmod, mkdir, mkdtemp, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  getWindowsOfflineInstallerTemplatePath,
  loadWindowsOfflineInstallerConfig,
  type WindowsOfflineInstallerConfig,
} from '../lib/windows-offline-installer-config.js';
import {
  loadCachedWindowsOfflineTemplate,
  WindowsOfflineTemplateCacheError,
} from '../lib/windows-offline-installer-template.js';

export type WindowsOfflineInstallerProvisionErrorCode =
  | 'CONFIG_INVALID'
  | 'TEMPLATE_MISSING'
  | 'DOWNLOAD_FAILED'
  | 'HASH_MISMATCH'
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
  verifyOnly?: boolean;
}

const TEMPLATE_FILE_NAME = 'OpenPath-Windows-Setup-Template.exe';
const HEX_SHA256 = /^[0-9a-f]{64}$/u;

function mapTemplateError(
  error: WindowsOfflineTemplateCacheError
): 'TEMPLATE_MISSING' | 'HASH_MISMATCH' {
  return error.code === 'TEMPLATE_MISSING' || error.code === 'SIDECAR_MISSING'
    ? 'TEMPLATE_MISSING'
    : 'HASH_MISMATCH';
}

function releaseAssetUrl(config: WindowsOfflineInstallerConfig, fileName: string): string {
  return `https://github.com/${config.githubRepo}/releases/download/${encodeURIComponent(config.templateReleaseTag)}/${fileName}`;
}

async function fetchBytes(fetchImpl: typeof fetch, url: string): Promise<Buffer> {
  let response: Response;
  try {
    response = await fetchImpl(url, { redirect: 'error' });
  } catch {
    throw new WindowsOfflineInstallerProvisionError('DOWNLOAD_FAILED', 'Template download failed');
  }
  if (!response.ok) {
    throw new WindowsOfflineInstallerProvisionError('DOWNLOAD_FAILED', 'Template download failed');
  }

  try {
    return Buffer.from(await response.arrayBuffer());
  } catch {
    throw new WindowsOfflineInstallerProvisionError('DOWNLOAD_FAILED', 'Template download failed');
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
  try {
    loadCachedWindowsOfflineTemplate(config.templateDir, {
      version: config.templateVersion,
      commit: config.templateCommit,
      sha256: config.templateSha256,
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

  const fetchImpl = options.fetchImpl ?? globalThis.fetch;

  const templateUrl = releaseAssetUrl(config, TEMPLATE_FILE_NAME);
  const sidecarUrl = releaseAssetUrl(config, `${TEMPLATE_FILE_NAME}.sha256`);
  const [templateBytes, sidecarBytes] = await Promise.all([
    fetchBytes(fetchImpl, templateUrl),
    fetchBytes(fetchImpl, sidecarUrl),
  ]);
  verifyPinnedBytes(templateBytes, sidecarBytes, config.templateSha256);

  const stagingRoot = await mkdtemp(path.join(tmpdir(), 'openpath-windows-template-'));
  const stagingDir = path.join(stagingRoot, config.templateCommit);
  const targetDir = path.dirname(templatePath);
  try {
    await mkdir(stagingDir, { recursive: true, mode: 0o750 });
    await writeFile(path.join(stagingDir, TEMPLATE_FILE_NAME), templateBytes, { mode: 0o640 });
    await writeFile(path.join(stagingDir, `${TEMPLATE_FILE_NAME}.sha256`), sidecarBytes, {
      mode: 0o640,
    });
    await chmod(path.join(stagingDir, TEMPLATE_FILE_NAME), 0o640);
    await chmod(path.join(stagingDir, `${TEMPLATE_FILE_NAME}.sha256`), 0o640);

    await mkdir(path.dirname(targetDir), { recursive: true, mode: 0o750 });
    try {
      await rename(stagingDir, targetDir);
    } catch {
      // A concurrent provision may have published the same pin. Reuse it only
      // after the normal full verification path succeeds.
      try {
        loadCachedWindowsOfflineTemplate(config.templateDir, {
          version: config.templateVersion,
          commit: config.templateCommit,
          sha256: config.templateSha256,
        });
        return existingTemplateResult(config, templatePath);
      } catch {
        throw new WindowsOfflineInstallerProvisionError(
          'PUBLISH_FAILED',
          'Pinned template could not be published'
        );
      }
    }

    loadCachedWindowsOfflineTemplate(config.templateDir, {
      version: config.templateVersion,
      commit: config.templateCommit,
      sha256: config.templateSha256,
    });
    return {
      status: 'provisioned',
      filePath: templatePath,
      releaseTag: config.templateReleaseTag,
      sha256: config.templateSha256,
    };
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
