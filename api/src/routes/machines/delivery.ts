import type { Express, Request, Response } from 'express';
import { timingSafeEqual } from 'node:crypto';
import { z } from 'zod';

import { config } from '../../config.js';
import { emitAgentUpdateAvailable } from '../../lib/rule-events.js';
import {
  getActiveAgentRelease,
  publishAgentRelease,
  retireAgentRelease,
  setMachineAgentRing,
} from '../../services/agent-release.service.js';
import {
  authenticateEnrollmentToken,
  authenticateMachineToken,
  getFirstParam,
} from '../../lib/server-request-auth.js';
import {
  getLinuxAgentManifest,
  getLinuxAgentPackage,
  getWindowsAgentFile,
  getWindowsAgentManifest,
  getWindowsBootstrapBundle,
  getWindowsBootstrapFile,
  getWindowsBootstrapManifest,
} from '../../services/machine-agent-delivery.service.js';
import {
  resolveMachineClientConfig,
  resolveMachineWhitelist,
} from '../../services/machine-policy.service.js';
import {
  createRouteHandler,
  getWildcardPathParam,
  sendFailOpenWhitelist,
  sendJsonInternalError,
  sendMachineServiceError,
  sendWhitelistDelivery,
  type MachineRouteDeps,
} from './helpers.js';

const publishAgentReleaseSchema = z.object({
  build: z.string().optional(),
  sourceSha: z.string().min(7).max(64),
  signature: z.string().min(1),
  files: z
    .array(
      z.object({
        path: z.string().min(1).max(512),
        sha256: z.string().length(64),
        contentBase64: z.string().min(1),
      })
    )
    .min(1),
});

const setMachineRingSchema = z.object({
  hostname: z.string().min(1).max(255),
  ring: z.enum(['stable', 'canary']),
});

function extractReleaseToken(req: Request): string | null {
  const authorization = req.get('authorization');
  const bearerPrefix = 'Bearer ';
  if (authorization?.startsWith(bearerPrefix)) {
    return authorization.slice(bearerPrefix.length).trim() || null;
  }
  const headerToken = req.get('x-openpath-release-token')?.trim();
  return headerToken ?? null;
}

function releaseTokenMatches(expected: string, presented: string | null): boolean {
  if (!presented) {
    return false;
  }
  const expectedBuffer = Buffer.from(expected);
  const presentedBuffer = Buffer.from(presented);
  return (
    expectedBuffer.length === presentedBuffer.length &&
    timingSafeEqual(expectedBuffer, presentedBuffer)
  );
}

function authorizeAgentRelease(req: Request, res: Response): boolean {
  const expected = config.agentReleaseToken;
  if (!expected || !releaseTokenMatches(expected, extractReleaseToken(req))) {
    res.status(403).json({ success: false, error: 'Invalid release token' });
    return false;
  }
  return true;
}

function getAgentCapabilities(req: Request): string {
  return req.get('x-openpath-agent-capabilities') ?? '';
}

export function registerMachineDeliveryRoutes(app: Express, deps: MachineRouteDeps): void {
  app.post(
    '/api/agent/windows/releases',
    createRouteHandler(
      'Error publishing Windows agent release',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        if (!authorizeAgentRelease(req, res)) {
          return;
        }

        const parsed = publishAgentReleaseSchema.safeParse(req.body);
        if (!parsed.success) {
          res.status(400).json({ success: false, error: 'Invalid release payload' });
          return;
        }

        const result = await publishAgentRelease(parsed.data);
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.status(201).json({ success: true, release: result.data });
        emitAgentUpdateAvailable(result.data.build);
      }
    )
  );

  app.post(
    '/api/agent/windows/releases/:build/retire',
    createRouteHandler(
      'Error retiring Windows agent release',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        if (!authorizeAgentRelease(req, res)) {
          return;
        }

        const result = await retireAgentRelease(String(req.params.build ?? ''));
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.json({ success: true, ...result.data });
      }
    )
  );

  app.post(
    '/api/agent/windows/rings',
    createRouteHandler(
      'Error assigning Windows agent ring',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        if (!authorizeAgentRelease(req, res)) {
          return;
        }

        const parsed = setMachineRingSchema.safeParse(req.body);
        if (!parsed.success) {
          res.status(400).json({ success: false, error: 'Invalid ring payload' });
          return;
        }

        const result = await setMachineAgentRing(parsed.data.hostname, parsed.data.ring);
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.json({ success: true, ...result.data });
      }
    )
  );

  app.get(
    '/api/agent/windows/releases/active',
    createRouteHandler(
      'Error reading active Windows agent release',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        if (!authorizeAgentRelease(req, res)) {
          return;
        }

        const release = await getActiveAgentRelease('canary');
        res.setHeader('Cache-Control', 'no-store, max-age=0');
        res.json({
          success: true,
          release: release
            ? {
                build: release.build,
                ring: release.ring,
                sourceSha: release.sourceSha,
                fileCount: release.files.length,
              }
            : null,
        });
      }
    )
  );

  app.get(
    '/api/agent/windows/bootstrap/manifest',
    createRouteHandler(
      'Error serving Windows bootstrap manifest',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const enrollment = await authenticateEnrollmentToken(req, res);
        if (!enrollment) {
          return;
        }

        const result = getWindowsBootstrapManifest(enrollment.classroomId);
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.setHeader('Cache-Control', 'no-store, max-age=0');
        res.setHeader('Pragma', 'no-cache');
        res.json({
          success: true,
          classroomId: result.data.classroomId,
          version: result.data.version,
          generatedAt: result.data.generatedAt,
          bundle: result.data.bundle,
          files: result.data.files,
        });
      }
    )
  );

  app.get(
    '/api/agent/windows/bootstrap/bundle.zip',
    createRouteHandler(
      'Error serving Windows bootstrap bundle',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const enrollment = await authenticateEnrollmentToken(req, res);
        if (!enrollment) {
          return;
        }

        const result = getWindowsBootstrapBundle();
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.setHeader('Cache-Control', 'no-store, max-age=0');
        res.setHeader('Pragma', 'no-cache');
        res.type('application/zip').send(result.data.body);
      }
    )
  );

  app.get(
    '/api/agent/windows/bootstrap/files/*path',
    createRouteHandler(
      'Error serving Windows bootstrap file',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const enrollment = await authenticateEnrollmentToken(req, res);
        if (!enrollment) {
          return;
        }

        const result = getWindowsBootstrapFile(getWildcardPathParam(req.params.path));
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.setHeader('Cache-Control', 'no-store, max-age=0');
        res.setHeader('Pragma', 'no-cache');
        res.type('text/plain').send(result.data.body);
      }
    )
  );

  app.get(
    '/api/agent/windows/manifest',
    createRouteHandler(
      'Error serving Windows agent manifest',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const machine = await authenticateMachineToken(req, res);
        if (!machine) {
          return;
        }

        const result = await getWindowsAgentManifest(machine.hostname, {
          capabilityHeader: getAgentCapabilities(req),
        });
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.setHeader('Cache-Control', 'no-store, max-age=0');
        res.setHeader('Pragma', 'no-cache');
        res.json({
          success: true,
          version: result.data.version,
          build: result.data.build,
          generatedAt: result.data.generatedAt,
          files: result.data.files,
          ...(result.data.ring === 'canary'
            ? {
                ring: result.data.ring,
                sourceSha: result.data.sourceSha,
                signature: result.data.signature,
              }
            : {}),
        });
      }
    )
  );

  app.get(
    '/api/agent/windows/files/*path',
    createRouteHandler(
      'Error serving Windows agent file',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const machine = await authenticateMachineToken(req, res);
        if (!machine) {
          return;
        }

        const result = await getWindowsAgentFile(
          machine.hostname,
          getWildcardPathParam(req.params.path),
          {
            build: typeof req.query.build === 'string' ? req.query.build : undefined,
            capabilityHeader: getAgentCapabilities(req),
          }
        );
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.setHeader('Cache-Control', 'no-store, max-age=0');
        res.setHeader('Pragma', 'no-cache');
        res.type('text/plain').send(result.data.body);
      }
    )
  );

  app.get(
    '/api/agent/linux/manifest',
    createRouteHandler(
      'Error serving Linux agent manifest',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const machine = await authenticateMachineToken(req, res);
        if (!machine) {
          return;
        }

        const result = await getLinuxAgentManifest(machine.hostname);
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.setHeader('Cache-Control', 'no-store, max-age=0');
        res.setHeader('Pragma', 'no-cache');
        res.json({
          success: true,
          ...result.data,
        });
      }
    )
  );

  app.get(
    '/api/agent/linux/packages/:version',
    createRouteHandler(
      'Error serving Linux agent package',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const machine = await authenticateMachineToken(req, res);
        if (!machine) {
          return;
        }

        const result = await getLinuxAgentPackage(
          machine.hostname,
          getFirstParam(req.params.version)?.trim() ?? ''
        );
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.setHeader('Cache-Control', 'no-store, max-age=0');
        res.setHeader('Pragma', 'no-cache');
        res.setHeader('Content-Disposition', `attachment; filename="${result.data.fileName}"`);
        res.type('application/vnd.debian.binary-package').send(result.data.body);
      }
    )
  );

  app.get(
    '/api/machines/client-config',
    createRouteHandler(
      'Error serving machine client config',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const machine = await authenticateMachineToken(req, res);
        if (!machine) {
          return;
        }

        const result = await resolveMachineClientConfig(machine);
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.setHeader('Cache-Control', 'private, no-cache');
        res.json({
          success: true,
          captivePortalDomains: result.data.captivePortalDomains,
        });
      }
    )
  );

  app.get('/w/whitelist.txt', (_req: Request, res: Response): void => {
    sendFailOpenWhitelist(res);
  });

  app.get(
    '/w/:machineToken/whitelist.txt',
    createRouteHandler(
      'Error serving tokenized whitelist',
      sendFailOpenWhitelist,
      async (req: Request, res: Response): Promise<void> => {
        const delivery = await resolveMachineWhitelist(
          getFirstParam(req.params.machineToken),
          deps.getCurrentEvaluationTime(),
          req.headers['if-none-match']
        );
        sendWhitelistDelivery(res, delivery);
      }
    )
  );
}
