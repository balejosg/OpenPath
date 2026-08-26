import { randomUUID } from 'node:crypto';
import { chmod, mkdir, rename, rm, stat } from 'node:fs/promises';
import path from 'node:path';

import {
  MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAINS,
  MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAIN_LENGTH,
  WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA,
  WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION,
  type WindowsOfflineInstallerConfig as WindowsOfflineInstallerPayload,
} from '@openpath/shared/windows-offline-installer';
import { z } from 'zod';

import { getClassroomById } from '../lib/classroom-storage.js';
import { applyOverlay, hashFileSha256 } from '../lib/windows-offline-installer.js';
import {
  loadWindowsOfflineInstallerConfig,
  type WindowsOfflineInstallerConfig,
} from '../lib/windows-offline-installer-config.js';
import {
  loadCachedWindowsOfflineTemplate,
  WindowsOfflineTemplateCacheError,
  type CachedWindowsOfflineTemplate,
} from '../lib/windows-offline-installer-template.js';
import { logger } from '../lib/logger.js';
import { issueEnrollmentTicket } from './enrollment-access.service.js';
import {
  createWindowsOfflineDownloadRefsService,
  artifactFileNameFromReferenceHash,
  type WindowsOfflineDownloadRefsService,
} from './windows-offline-installer-download-refs.service.js';
import type { JWTPayload } from '../types/index.js';

export class WindowsOfflineInstallerError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = 'WindowsOfflineInstallerError';
  }
}

export interface GenerateWindowsOfflineInstallerInput {
  apiUrl: string;
  classroomId: string;
  user: JWTPayload;
}

export interface WindowsOfflineInstallerArtifact {
  fileName: string;
  version: string;
  sha256: string;
  tokenExpiresAt: string;
  downloadUrl: string;
  downloadExpiresAt: string;
  artifactPath: string;
  reference: string;
  referenceHash: string;
  expiresAt: Date;
}

interface ClassroomForInstaller {
  id: string;
  name: string;
  displayName: string;
  captivePortalDomains?: string[] | null;
}

interface ArtifactRefs {
  cleanupExpired?: (artifactsDir: string) => Promise<number>;
  invalidateReference: (rawToken: string) => Promise<void>;
  mintReference: WindowsOfflineDownloadRefsService['mintReference'];
}

export interface ArtifactServiceDeps {
  applyOverlay?: typeof applyOverlay;
  env?: Readonly<Record<string, string | undefined>>;
  findClassroom?: (classroomId: string) => Promise<ClassroomForInstaller | null>;
  issueEnrollmentTicket?: typeof issueEnrollmentTicket;
  loadTemplate?: (config: WindowsOfflineInstallerConfig) => CachedWindowsOfflineTemplate;
  now?: () => Date;
  refs?: ArtifactRefs;
  renameArtifact?: (sourcePath: string, targetPath: string) => Promise<void>;
}

const TTL_TOLERANCE_MS = 5 * 60 * 1000;
const CAPTIVE_DOMAIN_SCHEMA = z
  .array(z.string().min(1).max(MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAIN_LENGTH))
  .max(MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAINS)
  .catch([]);

export function sanitizeWindowsInstallerFileName(classroomName: string): string {
  const sanitized = classroomName
    .normalize('NFKD')
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001F]/g, '')
    .replace(/[^A-Za-z0-9 _.-]+/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^[.\s]+|[.\s]+$/g, '')
    .slice(0, 80);

  const safeName = sanitized.length > 0 ? sanitized : 'classroom';
  return `OpenPath-${safeName.replace(/\s+/g, '-')}-Windows-Setup.exe`;
}

function toSafeBaseUrl(value: string): string {
  return value.replace(/\/+$/u, '');
}

function buildDownloadUrl(baseUrl: string, rawReference: string): string {
  return `${toSafeBaseUrl(baseUrl)}/api/windows-offline-installer/download?ref=${encodeURIComponent(rawReference)}`;
}

function readCaptivePortalDomains(classroom: ClassroomForInstaller): string[] {
  return CAPTIVE_DOMAIN_SCHEMA.parse(classroom.captivePortalDomains ?? []);
}

function mapEnrollmentError(code: string): string {
  if (code === 'FORBIDDEN') return 'FORBIDDEN';
  if (code === 'NOT_FOUND') return 'NOT_FOUND';
  if (code === 'UNAUTHORIZED') return 'UNAUTHORIZED';
  return 'TOKEN_FAILED';
}

function verifyEnrollmentExpiry(expiresAt: string, now: Date, tokenTtlHours: number): void {
  const expiry = Date.parse(expiresAt);
  const nowMs = now.getTime();
  const maximum = nowMs + tokenTtlHours * 60 * 60 * 1000 + TTL_TOLERANCE_MS;
  if (!Number.isFinite(expiry) || expiry <= nowMs || expiry > maximum) {
    throw new WindowsOfflineInstallerError('TOKEN_FAILED', 'Enrollment token lifetime invalid');
  }
}

export interface WindowsOfflineInstallerService {
  generate(input: GenerateWindowsOfflineInstallerInput): Promise<WindowsOfflineInstallerArtifact>;
  resolvePublishedArtifactPath(referenceHash: string): string;
  refs: ArtifactRefs;
}

export function createWindowsOfflineInstallerService(
  deps: ArtifactServiceDeps = {}
): WindowsOfflineInstallerService {
  const refs = deps.refs ?? createWindowsOfflineDownloadRefsService();
  const applyInstallerOverlay = deps.applyOverlay ?? applyOverlay;
  const findClassroom = deps.findClassroom ?? getClassroomById;
  const issueTicket = deps.issueEnrollmentTicket ?? issueEnrollmentTicket;
  const now = deps.now ?? ((): Date => new Date());
  const renameArtifact = deps.renameArtifact ?? rename;

  function loadConfig(apiUrl: string): WindowsOfflineInstallerConfig {
    try {
      return loadWindowsOfflineInstallerConfig(deps.env, { openpathUrl: apiUrl });
    } catch {
      throw new WindowsOfflineInstallerError(
        'CONFIG_INVALID',
        'Offline installer configuration invalid'
      );
    }
  }

  function loadTemplate(config: WindowsOfflineInstallerConfig): CachedWindowsOfflineTemplate {
    try {
      if (deps.loadTemplate) return deps.loadTemplate(config);
      return loadCachedWindowsOfflineTemplate(config.templateDir, {
        version: config.templateVersion,
        commit: config.templateCommit,
        sha256: config.templateSha256,
      });
    } catch (error) {
      logger.error('offline_installer_template_unavailable', {
        code: error instanceof WindowsOfflineTemplateCacheError ? error.code : 'TEMPLATE_ERROR',
        version: config.templateVersion,
      });
      throw new WindowsOfflineInstallerError('TEMPLATE_UNAVAILABLE', 'Template cache unavailable');
    }
  }

  async function generate(
    input: GenerateWindowsOfflineInstallerInput
  ): Promise<WindowsOfflineInstallerArtifact> {
    const config = loadConfig(input.apiUrl);
    const ticketResult = await issueTicket({
      classroomId: input.classroomId,
      user: input.user,
      expiresIn: `${String(config.tokenTtlHours)}h`,
    });
    if (!ticketResult.ok) {
      throw new WindowsOfflineInstallerError(
        mapEnrollmentError(ticketResult.error.code),
        ticketResult.error.message
      );
    }
    verifyEnrollmentExpiry(ticketResult.data.expiresAt, now(), config.tokenTtlHours);

    const classroom = await findClassroom(input.classroomId);
    if (!classroom) {
      throw new WindowsOfflineInstallerError('NOT_FOUND', 'Classroom not found');
    }

    const template = loadTemplate(config);
    let payload: WindowsOfflineInstallerPayload;
    try {
      payload = WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        schemaVersion: WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION,
        apiUrl: input.apiUrl,
        classroomId: input.classroomId,
        enrollmentToken: ticketResult.data.enrollmentToken,
        enrollmentTokenExpiresAt: ticketResult.data.expiresAt,
        captivePortalDomains: readCaptivePortalDomains(classroom),
        options: {
          approvedStudentBrowsers: ['Firefox'],
          installFirefoxIfMissing: true,
          enforceManagedBrowserBoundary: true,
        },
      });
    } catch {
      throw new WindowsOfflineInstallerError('PAYLOAD_INVALID', 'Installer payload invalid');
    }

    try {
      await mkdir(config.artifactsDir, { recursive: true, mode: 0o700 });
      await chmod(config.artifactsDir, 0o700);
    } catch {
      throw new WindowsOfflineInstallerError(
        'ARTIFACTS_UNAVAILABLE',
        'Offline installer artifact storage unavailable'
      );
    }

    const cleanupPromise = refs.cleanupExpired?.(config.artifactsDir);
    if (cleanupPromise) void cleanupPromise.catch(() => undefined);

    const stagingPath = path.join(
      config.artifactsDir,
      `.${String(process.pid)}-${randomUUID()}.staging.exe`
    );
    const artifactFileName = sanitizeWindowsInstallerFileName(classroom.name);
    let publishedReference: string | undefined;

    try {
      try {
        await applyInstallerOverlay(template.filePath, stagingPath, payload);
      } catch {
        throw new WindowsOfflineInstallerError('OVERLAY_FAILED', 'Template customization failed');
      }

      const artifactSha256 = await hashFileSha256(stagingPath);
      const artifactSize = (await stat(stagingPath)).size;
      let minted: Awaited<ReturnType<ArtifactRefs['mintReference']>>;
      try {
        minted = await refs.mintReference({
          classroomId: input.classroomId,
          classroomName: classroom.name,
          createdBy: input.user.sub,
          artifactFileName,
          artifactSha256,
          artifactSize,
          ttlMinutes: config.downloadRefTtlMinutes,
          maxAttempts: config.downloadRefMaxAttempts,
        });
      } catch {
        throw new WindowsOfflineInstallerError(
          'REFERENCE_MINT_FAILED',
          'Could not mint download reference'
        );
      }
      publishedReference = minted.rawToken;

      const publishedPath = path.join(
        config.artifactsDir,
        artifactFileNameFromReferenceHash(minted.ref.referenceHash)
      );
      try {
        await renameArtifact(stagingPath, publishedPath);
      } catch {
        await rm(stagingPath, { force: true });
        try {
          await refs.invalidateReference(minted.rawToken);
        } catch {
          logger.error('offline_installer_reference_invalidate_failed', {
            code: 'INVALIDATE_FAILED',
          });
        }
        publishedReference = undefined;
        throw new WindowsOfflineInstallerError(
          'ARTIFACT_PUBLISH_FAILED',
          'Installer artifact could not be published'
        );
      }

      return {
        fileName: artifactFileName,
        version: template.version,
        sha256: artifactSha256,
        tokenExpiresAt: ticketResult.data.expiresAt,
        downloadUrl: buildDownloadUrl(input.apiUrl, minted.rawToken),
        downloadExpiresAt: minted.ref.expiresAt.toISOString(),
        artifactPath: publishedPath,
        reference: minted.rawToken,
        referenceHash: minted.ref.referenceHash,
        expiresAt: minted.ref.expiresAt,
      };
    } catch (error) {
      await rm(stagingPath, { force: true });
      if (error instanceof WindowsOfflineInstallerError) throw error;
      logger.error('offline_installer_generation_failed', { code: 'GENERATION_FAILED' });
      if (publishedReference) {
        try {
          await refs.invalidateReference(publishedReference);
        } catch {
          logger.error('offline_installer_reference_invalidate_failed', {
            code: 'INVALIDATE_FAILED',
          });
        }
      }
      throw new WindowsOfflineInstallerError('GENERATION_FAILED', 'Installer generation failed');
    }
  }

  function resolvePublishedArtifactPath(referenceHash: string): string {
    const config = loadConfig('https://openpath.invalid');
    return path.join(config.artifactsDir, artifactFileNameFromReferenceHash(referenceHash));
  }

  return { generate, resolvePublishedArtifactPath, refs };
}
