import path from 'node:path';

export interface WindowsOfflineInstallerConfig {
  tokenTtlHours: number;
  downloadRefTtlMinutes: number;
  downloadRefMaxAttempts: number;
  artifactRetentionHours: number;
  templateVersion: string;
  templateCommit: string;
  templateSha256: string;
  templateReleaseTag: string;
  githubRepo: string;
  templateDir: string;
  artifactsDir: string;
  openpathUrl?: string;
}

export class WindowsOfflineInstallerConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WindowsOfflineInstallerConfigError';
  }
}

const HEX_SHA256 = /^[0-9a-f]{64}$/;
const FULL_COMMIT_SHA = /^[0-9a-f]{40}$/;
const TEMPLATE_VERSION = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const RELEASE_TAG = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;
const RELEASE_COMMIT_SUFFIX = /^[0-9a-f]{7,40}$/;
const GITHUB_REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const MAX_TOKEN_TTL_HOURS = 24;
const MAX_DOWNLOAD_TTL_MINUTES = 60;
const MAX_DOWNLOAD_ATTEMPTS = 10;
const MAX_ARTIFACT_RETENTION_HOURS = 24 * 7;

function readPositiveIntEnv(
  env: Readonly<Record<string, string | undefined>>,
  name: string,
  fallback: number,
  maximum: number
): number {
  const raw = env[name];
  if (!raw) return fallback;
  if (!/^\d+$/.test(raw) || Number.parseInt(raw, 10) <= 0) {
    throw new WindowsOfflineInstallerConfigError(`${name} must be a positive integer`);
  }
  const parsed = Number.parseInt(raw, 10);
  if (parsed > maximum) {
    throw new WindowsOfflineInstallerConfigError(`${name} must not exceed ${String(maximum)}`);
  }
  return parsed;
}

function readRequiredEnv(env: Readonly<Record<string, string | undefined>>, name: string): string {
  const raw = env[name]?.trim();
  if (!raw) {
    throw new WindowsOfflineInstallerConfigError(`${name} is required`);
  }
  return raw;
}

function resolveStorageDirectories(env: Readonly<Record<string, string | undefined>>): {
  templateDir: string;
  artifactsDir: string;
} {
  const templateDir = env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR?.trim();
  const artifactsDir = env.OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR?.trim();

  if (!templateDir || !artifactsDir) {
    throw new WindowsOfflineInstallerConfigError(
      'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR and OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR are required'
    );
  }

  const resolvedTemplateDir = path.resolve(templateDir);
  const resolvedArtifactsDir = path.resolve(artifactsDir);
  const artifactsRelativeToTemplate = path.relative(resolvedTemplateDir, resolvedArtifactsDir);
  const templateRelativeToArtifacts = path.relative(resolvedArtifactsDir, resolvedTemplateDir);
  const artifactsInsideTemplate =
    artifactsRelativeToTemplate === '' ||
    (!artifactsRelativeToTemplate.startsWith('..') &&
      !path.isAbsolute(artifactsRelativeToTemplate));
  const templateInsideArtifacts =
    templateRelativeToArtifacts === '' ||
    (!templateRelativeToArtifacts.startsWith('..') &&
      !path.isAbsolute(templateRelativeToArtifacts));
  if (artifactsInsideTemplate || templateInsideArtifacts) {
    throw new WindowsOfflineInstallerConfigError(
      'Windows offline installer template and artifact roots must be separate'
    );
  }

  return { templateDir: resolvedTemplateDir, artifactsDir: resolvedArtifactsDir };
}

export function isWindowsOfflineInstallerConfigured(
  env: Readonly<Record<string, string | undefined>> = process.env
): boolean {
  return [
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR',
    'OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG',
  ].some((name) => Boolean(env[name]?.trim()));
}

/**
 * Resolves only the writable artifact root so the binary route can remain
 * registered even while readiness reports an invalid capability configuration.
 */
export function resolveWindowsOfflineInstallerArtifactsDir(
  env: Readonly<Record<string, string | undefined>> = process.env
): string {
  return path.resolve(
    env.OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR?.trim() ??
      './var/windows-offline-installer/artifacts'
  );
}

export function getWindowsOfflineInstallerTemplatePath(
  config: Pick<WindowsOfflineInstallerConfig, 'templateDir' | 'templateVersion' | 'templateCommit'>
): string {
  return path.join(
    config.templateDir,
    config.templateVersion,
    config.templateCommit,
    'OpenPath-Windows-Setup-Template.exe'
  );
}

export function loadWindowsOfflineInstallerConfig(
  env: Readonly<Record<string, string | undefined>> = process.env,
  overrides: { openpathUrl?: string } = {}
): WindowsOfflineInstallerConfig {
  const templateSha256 = readRequiredEnv(
    env,
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256'
  ).toLowerCase();
  if (!HEX_SHA256.test(templateSha256)) {
    throw new WindowsOfflineInstallerConfigError(
      'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256 must be a hex SHA-256 digest'
    );
  }

  const templateCommit = readRequiredEnv(env, 'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT');
  if (!FULL_COMMIT_SHA.test(templateCommit)) {
    throw new WindowsOfflineInstallerConfigError(
      'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT must be a full 40-character lowercase commit SHA'
    );
  }

  const templateVersion = readRequiredEnv(env, 'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION');
  if (!TEMPLATE_VERSION.test(templateVersion) || templateVersion.toLowerCase() === 'latest') {
    throw new WindowsOfflineInstallerConfigError(
      'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION must be a valid release version'
    );
  }

  const templateReleaseTag =
    env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG?.trim() ??
    `scripts-v${templateVersion}-${templateCommit.slice(0, 7)}`;
  if (
    !RELEASE_TAG.test(templateReleaseTag) ||
    templateReleaseTag.toLowerCase().includes('latest')
  ) {
    throw new WindowsOfflineInstallerConfigError(
      'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG must be an exact release tag, not latest'
    );
  }

  const expectedReleaseTagPrefix = `scripts-v${templateVersion}-`;
  const releaseCommitSuffix = templateReleaseTag.slice(expectedReleaseTagPrefix.length);
  if (
    !templateReleaseTag.startsWith(expectedReleaseTagPrefix) ||
    !RELEASE_COMMIT_SUFFIX.test(releaseCommitSuffix) ||
    !templateCommit.startsWith(releaseCommitSuffix)
  ) {
    throw new WindowsOfflineInstallerConfigError(
      'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG must be scripts-v<version>-<commit-prefix>'
    );
  }

  const githubRepo = env.OPENPATH_GITHUB_REPO?.trim() ?? 'balejosg/openpath';
  if (!GITHUB_REPOSITORY.test(githubRepo)) {
    throw new WindowsOfflineInstallerConfigError(
      'OPENPATH_GITHUB_REPO must use the owner/repository form'
    );
  }

  const storageDirectories = resolveStorageDirectories(env);
  const openpathUrl =
    overrides.openpathUrl ?? env.PUBLIC_URL?.trim() ?? env.OPENPATH_PUBLIC_URL?.trim();

  return {
    tokenTtlHours: readPositiveIntEnv(
      env,
      'OPENPATH_WINDOWS_OFFLINE_TOKEN_TTL_HOURS',
      2,
      MAX_TOKEN_TTL_HOURS
    ),
    downloadRefTtlMinutes: readPositiveIntEnv(
      env,
      'OPENPATH_WINDOWS_OFFLINE_DOWNLOAD_TTL_MINUTES',
      10,
      MAX_DOWNLOAD_TTL_MINUTES
    ),
    downloadRefMaxAttempts: readPositiveIntEnv(
      env,
      'OPENPATH_WINDOWS_OFFLINE_DOWNLOAD_MAX_ATTEMPTS',
      3,
      MAX_DOWNLOAD_ATTEMPTS
    ),
    artifactRetentionHours: readPositiveIntEnv(
      env,
      'OPENPATH_WINDOWS_OFFLINE_ARTIFACT_RETENTION_HOURS',
      24,
      MAX_ARTIFACT_RETENTION_HOURS
    ),
    templateVersion,
    templateCommit,
    templateSha256,
    templateReleaseTag,
    githubRepo,
    ...storageDirectories,
    ...(openpathUrl ? { openpathUrl: openpathUrl.replace(/\/+$/, '') } : {}),
  };
}
