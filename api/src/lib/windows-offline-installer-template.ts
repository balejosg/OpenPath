import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { getWindowsOfflineInstallerTemplatePath } from './windows-offline-installer-config.js';

export interface CachedWindowsOfflineTemplate {
  filePath: string;
  version: string;
  commit: string;
  sha256: string;
}

export interface WindowsOfflineTemplateProvenance {
  version: string;
  commit: string;
  releaseTag: string;
  sha256: string;
}

export type WindowsOfflineTemplateCacheErrorCode =
  | 'TEMPLATE_MISSING'
  | 'SIDECAR_MISSING'
  | 'SIDECAR_INVALID'
  | 'SIDECAR_HASH_MISMATCH'
  | 'TEMPLATE_HASH_MISMATCH'
  | 'PROVENANCE_MISSING'
  | 'PROVENANCE_INVALID'
  | 'PROVENANCE_MISMATCH';

export class WindowsOfflineTemplateCacheError extends Error {
  readonly code: WindowsOfflineTemplateCacheErrorCode;

  constructor(code: WindowsOfflineTemplateCacheErrorCode, message: string) {
    super(message);
    this.name = 'WindowsOfflineTemplateCacheError';
    this.code = code;
  }
}

export type WindowsOfflineTemplateReadFile = (
  filePath: string,
  encoding?: BufferEncoding
) => Buffer | string;

export interface WindowsOfflineTemplateLoaderIo {
  exists?: (filePath: string) => boolean;
  readFile?: WindowsOfflineTemplateReadFile;
  hashFile?: (filePath: string) => string;
}

export const WINDOWS_OFFLINE_TEMPLATE_PROVENANCE_FILE_NAME =
  'OpenPath-Windows-Setup-Template.exe.provenance.json';

export function getWindowsOfflineInstallerTemplateProvenancePath(templatePath: string): string {
  return path.join(path.dirname(templatePath), WINDOWS_OFFLINE_TEMPLATE_PROVENANCE_FILE_NAME);
}

const HEX_SHA256 = /^[0-9a-f]{64}$/;

function readTemplateFile(
  filePath: string,
  encoding: BufferEncoding | undefined,
  io: WindowsOfflineTemplateLoaderIo
): Buffer | string {
  if (io.readFile) return io.readFile(filePath, encoding);
  return encoding ? readFileSync(filePath, encoding) : readFileSync(filePath);
}

function sha256File(filePath: string, io: WindowsOfflineTemplateLoaderIo): string {
  const bytes = readTemplateFile(filePath, undefined, io);
  return createHash('sha256').update(bytes).digest('hex');
}

/**
 * Loads only the exact version/commit selected by configuration. There is no
 * latest-release fallback and no network path in this function.
 */
export function loadCachedWindowsOfflineTemplate(
  templateDir: string,
  expected: { version: string; commit: string; sha256: string; releaseTag?: string },
  io: WindowsOfflineTemplateLoaderIo = {}
): CachedWindowsOfflineTemplate {
  const exists = io.exists ?? existsSync;
  const templatePath = getWindowsOfflineInstallerTemplatePath({
    templateDir: path.resolve(templateDir),
    templateVersion: expected.version,
    templateCommit: expected.commit,
  });

  if (!exists(templatePath)) {
    throw new WindowsOfflineTemplateCacheError(
      'TEMPLATE_MISSING',
      'Pinned OpenPath Windows setup template is missing'
    );
  }

  const sidecarPath = `${templatePath}.sha256`;
  if (!exists(sidecarPath)) {
    throw new WindowsOfflineTemplateCacheError(
      'SIDECAR_MISSING',
      'Pinned Windows setup template is missing its SHA-256 sidecar'
    );
  }

  const sidecarDigest = String(readTemplateFile(sidecarPath, 'utf8', io))
    .trim()
    .split(/\s+/u)[0]
    ?.toLowerCase();
  if (!sidecarDigest || !HEX_SHA256.test(sidecarDigest)) {
    throw new WindowsOfflineTemplateCacheError(
      'SIDECAR_INVALID',
      'Pinned Windows setup template sidecar is malformed'
    );
  }

  const expectedDigest = expected.sha256.toLowerCase();
  if (sidecarDigest !== expectedDigest) {
    throw new WindowsOfflineTemplateCacheError(
      'SIDECAR_HASH_MISMATCH',
      'Pinned Windows setup template sidecar does not match configuration'
    );
  }

  const actualDigest = io.hashFile?.(templatePath) ?? sha256File(templatePath, io);
  if (actualDigest.toLowerCase() !== expectedDigest) {
    throw new WindowsOfflineTemplateCacheError(
      'TEMPLATE_HASH_MISMATCH',
      'Pinned Windows setup template bytes do not match configuration'
    );
  }

  if (expected.releaseTag !== undefined) {
    const provenancePath = getWindowsOfflineInstallerTemplateProvenancePath(templatePath);
    if (!exists(provenancePath)) {
      throw new WindowsOfflineTemplateCacheError(
        'PROVENANCE_MISSING',
        'Pinned OpenPath Windows setup template is missing release provenance'
      );
    }

    let provenance: Partial<WindowsOfflineTemplateProvenance>;
    try {
      const parsed: unknown = JSON.parse(String(readTemplateFile(provenancePath, 'utf8', io)));
      if (typeof parsed !== 'object' || parsed === null) throw new Error('invalid provenance');
      provenance = parsed as Partial<WindowsOfflineTemplateProvenance>;
    } catch {
      throw new WindowsOfflineTemplateCacheError(
        'PROVENANCE_INVALID',
        'Pinned OpenPath Windows setup template provenance is malformed'
      );
    }

    if (
      provenance.version !== expected.version ||
      provenance.commit !== expected.commit ||
      provenance.releaseTag !== expected.releaseTag ||
      provenance.sha256?.toLowerCase() !== expectedDigest
    ) {
      throw new WindowsOfflineTemplateCacheError(
        'PROVENANCE_MISMATCH',
        'Pinned OpenPath Windows setup template provenance does not match configuration'
      );
    }
  }

  return {
    filePath: templatePath,
    version: expected.version,
    commit: expected.commit,
    sha256: actualDigest.toLowerCase(),
  };
}
