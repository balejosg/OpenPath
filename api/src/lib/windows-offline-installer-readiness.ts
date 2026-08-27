import { createHash, randomUUID } from 'node:crypto';
import {
  accessSync,
  constants,
  existsSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';

import {
  isWindowsOfflineInstallerConfigured,
  loadWindowsOfflineInstallerConfig,
  type WindowsOfflineInstallerConfig,
} from './windows-offline-installer-config.js';
import {
  getWindowsOfflineInstallerTemplateProvenancePath,
  loadCachedWindowsOfflineTemplate,
  WindowsOfflineTemplateCacheError,
  type WindowsOfflineTemplateLoaderIo,
} from './windows-offline-installer-template.js';

export type WindowsOfflineInstallerReadinessCode =
  | 'OK'
  | 'NOT_CONFIGURED'
  | 'CONFIG_INVALID'
  | 'TEMPLATE_MISSING'
  | 'SIDECAR_MISSING'
  | 'SIDECAR_INVALID'
  | 'SIDECAR_HASH_MISMATCH'
  | 'TEMPLATE_HASH_MISMATCH'
  | 'PROVENANCE_MISSING'
  | 'PROVENANCE_INVALID'
  | 'PROVENANCE_MISMATCH'
  | 'ARTIFACTS_DIR_UNAVAILABLE'
  | 'ARTIFACTS_DIR_NOT_WRITABLE';

export interface WindowsOfflineInstallerReadiness {
  ready: boolean;
  code: WindowsOfflineInstallerReadinessCode;
}

export interface WindowsOfflineInstallerReadinessOptions {
  env?: Readonly<Record<string, string | undefined>>;
  probeArtifactsWrite?: (artifactsDir: string) => void;
  readTemplateFile?: WindowsOfflineTemplateLoaderIo['readFile'];
  hashTemplateFile?: (filePath: string) => string;
  statTemplateFile?: (filePath: string) => {
    size: number;
    mtimeMs: number;
    ctimeMs?: number;
    ino?: number;
  };
}

const templateReadinessCache = new Map<string, WindowsOfflineInstallerReadiness>();

export function resetWindowsOfflineInstallerReadinessCache(): void {
  templateReadinessCache.clear();
}

function defaultProbeArtifactsWrite(artifactsDir: string): void {
  const probePath = path.join(
    artifactsDir,
    `.openpath-readiness-${String(process.pid)}-${randomUUID()}`
  );
  let created = false;
  try {
    writeFileSync(probePath, 'ok', { flag: 'wx' });
    created = true;
  } finally {
    if (created) rmSync(probePath, { force: true });
  }
}

function mapTemplateError(
  error: WindowsOfflineTemplateCacheError
): WindowsOfflineInstallerReadinessCode {
  return error.code;
}

function notReady(code: WindowsOfflineInstallerReadinessCode): WindowsOfflineInstallerReadiness {
  return { ready: false, code };
}

function fileIdentity(
  filePath: string,
  statTemplateFile: NonNullable<WindowsOfflineInstallerReadinessOptions['statTemplateFile']>,
  readForFingerprint?: WindowsOfflineTemplateLoaderIo['readFile']
): string | null {
  try {
    const fileStat = statTemplateFile(filePath);
    const contentFingerprint = readForFingerprint
      ? createHash('sha256').update(readForFingerprint(filePath)).digest('hex')
      : '';
    return [
      filePath,
      fileStat.size,
      fileStat.mtimeMs,
      fileStat.ctimeMs ?? '',
      fileStat.ino ?? '',
      contentFingerprint,
    ].join(':');
  } catch {
    return null;
  }
}

function checkTemplateWithCache(
  config: WindowsOfflineInstallerConfig,
  options: WindowsOfflineInstallerReadinessOptions
): WindowsOfflineInstallerReadiness {
  const statTemplateFile = options.statTemplateFile ?? statSync;
  const templatePath = path.join(
    config.templateDir,
    config.templateVersion,
    config.templateCommit,
    'OpenPath-Windows-Setup-Template.exe'
  );
  const sidecarPath = `${templatePath}.sha256`;
  const provenancePath = getWindowsOfflineInstallerTemplateProvenancePath(templatePath);
  const templateIdentity = fileIdentity(templatePath, statTemplateFile);
  const readForFingerprint: NonNullable<WindowsOfflineTemplateLoaderIo['readFile']> =
    options.readTemplateFile ?? ((filePath: string): Buffer | string => readFileSync(filePath));
  const sidecarIdentity = fileIdentity(sidecarPath, statTemplateFile, readForFingerprint);
  const provenanceIdentity = fileIdentity(provenancePath, statTemplateFile, readForFingerprint);
  const cacheKey =
    templateIdentity && sidecarIdentity && provenanceIdentity
      ? [templateIdentity, sidecarIdentity, provenanceIdentity, config.templateSha256].join('|')
      : null;

  if (cacheKey) {
    const cached = templateReadinessCache.get(cacheKey);
    if (cached) return cached;
  }

  let result: WindowsOfflineInstallerReadiness;
  try {
    loadCachedWindowsOfflineTemplate(
      config.templateDir,
      {
        version: config.templateVersion,
        commit: config.templateCommit,
        sha256: config.templateSha256,
        releaseTag: config.templateReleaseTag,
      },
      {
        ...(options.readTemplateFile ? { readFile: options.readTemplateFile } : {}),
        ...(options.hashTemplateFile ? { hashFile: options.hashTemplateFile } : {}),
      }
    );
    result = { ready: true, code: 'OK' };
  } catch (error) {
    result =
      error instanceof WindowsOfflineTemplateCacheError
        ? notReady(mapTemplateError(error))
        : notReady('TEMPLATE_MISSING');
  }

  // A healthy identity can be reused. Broken files are deliberately retried
  // on the next probe so repair becomes visible immediately.
  if (cacheKey && result.ready) templateReadinessCache.set(cacheKey, result);
  return result;
}

function checkArtifactsDirectory(
  config: WindowsOfflineInstallerConfig,
  probeArtifactsWrite: (artifactsDir: string) => void
): WindowsOfflineInstallerReadiness {
  if (!existsSync(config.artifactsDir)) return notReady('ARTIFACTS_DIR_UNAVAILABLE');

  try {
    if (!statSync(config.artifactsDir).isDirectory()) {
      return notReady('ARTIFACTS_DIR_UNAVAILABLE');
    }
    accessSync(config.artifactsDir, constants.W_OK);
    probeArtifactsWrite(config.artifactsDir);
  } catch {
    return notReady('ARTIFACTS_DIR_NOT_WRITABLE');
  }

  return { ready: true, code: 'OK' };
}

/**
 * Local-only capability check. It never fetches releases, provisions files, or
 * repairs storage. The full template hash is cached by file identity.
 */
export function checkWindowsOfflineInstallerReadiness(
  options: WindowsOfflineInstallerReadinessOptions = {}
): WindowsOfflineInstallerReadiness {
  const env = options.env ?? process.env;
  if (!isWindowsOfflineInstallerConfigured(env)) return { ready: true, code: 'NOT_CONFIGURED' };

  let config: WindowsOfflineInstallerConfig;
  try {
    config = loadWindowsOfflineInstallerConfig(env);
  } catch {
    return notReady('CONFIG_INVALID');
  }

  const templateResult = checkTemplateWithCache(config, options);
  if (!templateResult.ready) return templateResult;

  return checkArtifactsDirectory(config, options.probeArtifactsWrite ?? defaultProbeArtifactsWrite);
}
