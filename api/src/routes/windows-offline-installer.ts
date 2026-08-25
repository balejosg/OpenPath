import { createReadStream } from 'node:fs';
import { access, rm, stat } from 'node:fs/promises';
import path from 'node:path';

import type express from 'express';
import type { RequestHandler } from 'express';

import {
  artifactFileNameFromReferenceHash,
  createWindowsOfflineDownloadRefsService,
  DownloadReferenceError,
  isValidWindowsOfflineDownloadReference,
  logReferenceFailure,
  type WindowsOfflineDownloadRefsService,
} from '../services/windows-offline-installer-download-refs.service.js';
import { sanitizeWindowsInstallerFileName } from '../services/windows-offline-installer-artifact.service.js';
import { hashFileSha256 } from '../lib/windows-offline-installer.js';
import { resolveWindowsOfflineInstallerArtifactsDir } from '../lib/windows-offline-installer-config.js';
import { logger } from '../lib/logger.js';

export interface WindowsOfflineInstallerRouteDeps {
  refs: Pick<WindowsOfflineDownloadRefsService, 'consumeAttempt' | 'markConsumed'>;
  resolveArtifactPath: (referenceHash: string) => string;
}

const STATUS_BY_CODE: Record<DownloadReferenceError['code'], number> = {
  INVALID: 404,
  EXPIRED: 410,
  EXHAUSTED: 410,
  CONSUMED: 410,
};

function sendSafeError(res: Parameters<RequestHandler>[1], status: number, error: string): void {
  if (!res.headersSent) res.status(status).json({ error });
}

/**
 * Serves an opaque, short-lived reference. The attempt is reserved before
 * opening the file, but the reference is consumed only after the complete
 * response has finished. Aborted streams therefore remain eligible for the
 * bounded retry budget.
 */
export function createWindowsOfflineInstallerDownloadHandler(
  deps: WindowsOfflineInstallerRouteDeps
): RequestHandler {
  return (req, res): void => {
    const reference = req.query.ref;
    if (typeof reference !== 'string' || !isValidWindowsOfflineDownloadReference(reference)) {
      sendSafeError(res, 400, 'Invalid download reference');
      return;
    }

    void deps.refs
      .consumeAttempt(reference)
      .then(async (record) => {
        const artifactPath = deps.resolveArtifactPath(record.referenceHash);
        let artifactStat;
        try {
          await access(artifactPath);
          artifactStat = await stat(artifactPath);
          if (!artifactStat.isFile() || artifactStat.size !== record.artifactSize) {
            throw new Error('artifact identity mismatch');
          }
          const artifactHash = await hashFileSha256(artifactPath);
          if (artifactHash !== record.artifactSha256) {
            throw new Error('artifact checksum mismatch');
          }
        } catch {
          logger.warn('offline_installer_artifact_unavailable', { code: 'ARTIFACT_INVALID' });
          sendSafeError(res, 404, 'Installer artifact unavailable');
          return;
        }

        const fileName = sanitizeWindowsInstallerFileName(record.classroomName);
        res.status(200);
        res.setHeader('Content-Type', 'application/octet-stream');
        res.setHeader('Content-Disposition', `attachment; filename="${fileName}"`);
        res.setHeader('Cache-Control', 'no-store');
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('Content-Length', String(artifactStat.size));

        const stream = createReadStream(artifactPath);
        let streamEnded = false;
        let streamFailed = false;
        let responseClosed = false;
        let finalized = false;

        const finalizeSuccessfulDownload = (): void => {
          if (
            finalized ||
            streamFailed ||
            responseClosed ||
            !streamEnded ||
            !res.writableFinished
          ) {
            return;
          }
          finalized = true;
          void deps.refs
            .markConsumed(reference)
            .then(() => rm(artifactPath, { force: true }))
            .catch(() => {
              logger.error('offline_installer_reference_consume_mark_failed', {
                code: 'CONSUME_MARK_FAILED',
              });
            });
        };

        stream.on('end', () => {
          streamEnded = true;
          finalizeSuccessfulDownload();
        });
        stream.on('error', () => {
          streamFailed = true;
          logger.warn('offline_installer_download_stream_failed', { code: 'STREAM_FAILED' });
          if (!res.destroyed) res.destroy();
        });
        res.on('finish', finalizeSuccessfulDownload);
        res.on('close', () => {
          if (!res.writableFinished) responseClosed = true;
        });

        stream.pipe(res);
      })
      .catch((error: unknown) => {
        if (error instanceof DownloadReferenceError) {
          logReferenceFailure(error.code);
          sendSafeError(res, STATUS_BY_CODE[error.code], 'Download reference unavailable');
          return;
        }
        logger.error('offline_installer_download_failed', { code: 'DOWNLOAD_FAILED' });
        sendSafeError(res, 500, 'Download failed');
      });
  };
}

export interface RegisterWindowsOfflineInstallerRouteOptions {
  artifactsDir?: string;
  refs?: WindowsOfflineDownloadRefsService;
}

export function registerWindowsOfflineInstallerRoutes(
  app: express.Express,
  options: RegisterWindowsOfflineInstallerRouteOptions = {}
): void {
  const artifactsDir = path.resolve(
    options.artifactsDir ?? resolveWindowsOfflineInstallerArtifactsDir()
  );
  const refs = options.refs ?? createWindowsOfflineDownloadRefsService();
  app.get(
    '/api/windows-offline-installer/download',
    createWindowsOfflineInstallerDownloadHandler({
      refs,
      resolveArtifactPath: (referenceHash) =>
        path.join(artifactsDir, artifactFileNameFromReferenceHash(referenceHash)),
    })
  );
}
