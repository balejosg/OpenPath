import type { Express, Request, Response } from 'express';

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
import { resolveMachineWhitelist } from '../../services/machine-policy.service.js';
import {
  createRouteHandler,
  getWildcardPathParam,
  sendFailOpenWhitelist,
  sendJsonInternalError,
  sendMachineServiceError,
  sendWhitelistDelivery,
  type MachineRouteDeps,
} from './helpers.js';

export function registerMachineDeliveryRoutes(app: Express, deps: MachineRouteDeps): void {
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

        const result = await getWindowsAgentManifest(machine.hostname);
        if (!result.ok) {
          sendMachineServiceError(res, result.error);
          return;
        }

        res.setHeader('Cache-Control', 'no-store, max-age=0');
        res.setHeader('Pragma', 'no-cache');
        res.json({
          success: true,
          version: result.data.version,
          generatedAt: result.data.generatedAt,
          files: result.data.files,
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
          getWildcardPathParam(req.params.path)
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
