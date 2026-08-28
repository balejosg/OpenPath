import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, statSync } from 'node:fs';
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
export const WINDOWS_OFFLINE_TEMPLATE_CURRENT_FILE_NAME = '.current';
export const WINDOWS_OFFLINE_TEMPLATE_GENERATIONS_DIR_NAME = 'generations';
export const WINDOWS_OFFLINE_TEMPLATE_FILE_NAME = 'OpenPath-Windows-Setup-Template.exe';

const GENERATION_NAME =
  /^generation-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;

export function getWindowsOfflineInstallerTemplateProvenancePath(templatePath: string): string {
  return path.join(path.dirname(templatePath), WINDOWS_OFFLINE_TEMPLATE_PROVENANCE_FILE_NAME);
}

const HEX_SHA256 = /^[0-9a-f]{64}$/;

function containsSymbolicLink(filePath: string): boolean {
  const absolutePath = path.resolve(filePath);
  const parsed = path.parse(absolutePath);
  let current = parsed.root;
  const relativeParts = absolutePath.slice(parsed.root.length).split(path.sep).filter(Boolean);

  for (const part of relativeParts) {
    current = path.join(current, part);
    try {
      if (lstatSync(current).isSymbolicLink()) return true;
    } catch (error) {
      if (
        typeof error === 'object' &&
        error !== null &&
        'code' in error &&
        (error as { code?: unknown }).code === 'ENOENT'
      ) {
        return false;
      }
      return true;
    }
  }
  return false;
}

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

function cacheMissing(message: string): WindowsOfflineTemplateCacheError {
  return new WindowsOfflineTemplateCacheError('TEMPLATE_MISSING', message);
}

function readCurrentGenerationDirectory(commitDirectory: string): string | null {
  const currentPath = path.join(commitDirectory, WINDOWS_OFFLINE_TEMPLATE_CURRENT_FILE_NAME);
  let currentStat;
  try {
    currentStat = lstatSync(currentPath);
  } catch (error) {
    if (
      typeof error === 'object' &&
      error !== null &&
      'code' in error &&
      (error as { code?: unknown }).code === 'ENOENT'
    ) {
      return null;
    }
    throw cacheMissing('Pinned OpenPath Windows setup template is unavailable');
  }

  if (!currentStat.isFile() || currentStat.isSymbolicLink()) {
    throw cacheMissing('Pinned OpenPath Windows setup template is unavailable');
  }

  let generationName: string;
  try {
    generationName = readFileSync(currentPath, 'utf8').trim();
  } catch {
    throw cacheMissing('Pinned OpenPath Windows setup template is unavailable');
  }
  if (!GENERATION_NAME.test(generationName)) {
    throw cacheMissing('Pinned OpenPath Windows setup template is unavailable');
  }

  const generationsDirectory = path.join(
    commitDirectory,
    WINDOWS_OFFLINE_TEMPLATE_GENERATIONS_DIR_NAME
  );
  const generationDirectory = path.join(generationsDirectory, generationName);
  if (containsSymbolicLink(generationsDirectory) || containsSymbolicLink(generationDirectory)) {
    throw cacheMissing('Pinned OpenPath Windows setup template is unavailable');
  }
  try {
    if (!statSync(generationDirectory).isDirectory()) {
      throw new Error('generation is not a directory');
    }
  } catch {
    throw cacheMissing('Pinned OpenPath Windows setup template is unavailable');
  }
  return generationDirectory;
}

export function resolveWindowsOfflineInstallerTemplatePath(
  templateDir: string,
  expected: { version: string; commit: string }
): string {
  const canonicalTemplatePath = getWindowsOfflineInstallerTemplatePath({
    templateDir: path.resolve(templateDir),
    templateVersion: expected.version,
    templateCommit: expected.commit,
  });
  const commitDirectory = path.dirname(canonicalTemplatePath);
  const generationDirectory = readCurrentGenerationDirectory(commitDirectory);
  return path.join(generationDirectory ?? commitDirectory, WINDOWS_OFFLINE_TEMPLATE_FILE_NAME);
}

export function loadWindowsOfflineTemplateBundle(
  bundleDirectory: string,
  expected: { version: string; commit: string; sha256: string; releaseTag?: string },
  io: WindowsOfflineTemplateLoaderIo = {}
): CachedWindowsOfflineTemplate {
  const exists = io.exists ?? existsSync;
  const templatePath = path.join(path.resolve(bundleDirectory), WINDOWS_OFFLINE_TEMPLATE_FILE_NAME);
  const sidecarPath = `${templatePath}.sha256`;
  const provenancePath = getWindowsOfflineInstallerTemplateProvenancePath(templatePath);

  if (
    containsSymbolicLink(bundleDirectory) ||
    containsSymbolicLink(templatePath) ||
    containsSymbolicLink(sidecarPath) ||
    (expected.releaseTag !== undefined && containsSymbolicLink(provenancePath))
  ) {
    throw cacheMissing('Pinned OpenPath Windows setup template is unavailable');
  }

  if (!exists(templatePath)) {
    throw cacheMissing('Pinned OpenPath Windows setup template is missing');
  }

  if (!exists(sidecarPath)) {
    throw new WindowsOfflineTemplateCacheError(
      'SIDECAR_MISSING',
      'Pinned Windows setup template is missing its SHA-256 sidecar'
    );
  }

  let sidecarDigest: string | undefined;
  try {
    sidecarDigest = String(readTemplateFile(sidecarPath, 'utf8', io))
      .trim()
      .split(/\s+/u)[0]
      ?.toLowerCase();
  } catch {
    sidecarDigest = undefined;
  }
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

  let actualDigest: string;
  try {
    actualDigest = io.hashFile?.(templatePath) ?? sha256File(templatePath, io);
  } catch {
    throw new WindowsOfflineTemplateCacheError(
      'TEMPLATE_HASH_MISMATCH',
      'Pinned Windows setup template bytes do not match configuration'
    );
  }
  if (actualDigest.toLowerCase() !== expectedDigest) {
    throw new WindowsOfflineTemplateCacheError(
      'TEMPLATE_HASH_MISMATCH',
      'Pinned Windows setup template bytes do not match configuration'
    );
  }

  if (expected.releaseTag !== undefined) {
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

/**
 * Loads only the exact version/commit selected by configuration. There is no
 * latest-release fallback and no network path in this function.
 */
export function loadCachedWindowsOfflineTemplate(
  templateDir: string,
  expected: { version: string; commit: string; sha256: string; releaseTag?: string },
  io: WindowsOfflineTemplateLoaderIo = {}
): CachedWindowsOfflineTemplate {
  const templatePath = resolveWindowsOfflineInstallerTemplatePath(templateDir, expected);
  return loadWindowsOfflineTemplateBundle(path.dirname(templatePath), expected, io);
}
