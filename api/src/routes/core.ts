import type { Express, Request, Response } from 'express';

import { buildWhitelistEtag, matchesIfNoneMatch } from '../lib/server-assets.js';
import CoreService from '../services/core.service.js';
import HealthcheckService, {
  type ReadinessCheckStatus,
  type ReadinessResult,
} from '../services/healthcheck.service.js';
import { createAsyncRouteHandler, sendTextInternalError } from './route-helpers.js';

export interface CoreRouteOptions {
  getReadinessStatus?: () => Promise<ReadinessResult>;
}

function publicReadinessCheck(check: ReadinessCheckStatus): ReadinessCheckStatus {
  return {
    status: check.status,
    ...(check.totalRequests === undefined ? {} : { totalRequests: check.totalRequests }),
    ...(check.error === undefined
      ? {}
      : { error: /^[A-Z][A-Z0-9_]{0,63}$/u.test(check.error) ? check.error : 'UNAVAILABLE' }),
  };
}

function publicReadiness(result: ReadinessResult): ReadinessResult {
  return {
    status: result.status,
    service: 'openpath-api',
    uptime: result.uptime,
    checks: Object.fromEntries(
      Object.entries(result.checks).map(([name, check]) => [name, publicReadinessCheck(check)])
    ),
    responseTime: result.responseTime,
  };
}

export function registerCoreRoutes(app: Express, options: CoreRouteOptions = {}): void {
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', service: 'openpath-api' });
  });

  app.get('/ready', (_req, res) => {
    void (options.getReadinessStatus ?? HealthcheckService.getReadinessStatus)()
      .then((result) => {
        res.status(result.status === 'ok' ? 200 : 503).json(publicReadiness(result));
      })
      .catch(() => {
        res.status(503).json({ status: 'degraded', service: 'openpath-api' });
      });
  });

  app.get('/api/config', (_req, res) => {
    res.json(CoreService.getPublicClientConfig());
  });

  app.get('/export/:name.txt', (req: Request, res: Response): void => {
    const name = Array.isArray(req.params.name) ? req.params.name[0] : req.params.name;
    if (!name) {
      res.status(400).type('text/plain').send('Group name required');
      return;
    }

    createAsyncRouteHandler(
      'Public export route failed',
      sendTextInternalError,
      async (_req: Request, response: Response): Promise<void> => {
        const result = await CoreService.getPublicGroupExportResource(name);
        if (!result.ok) {
          response
            .status(result.error.code === 'NOT_FOUND' ? 404 : 500)
            .type('text/plain')
            .send(result.error.message);
          return;
        }

        const resource = result.data;
        const etag = buildWhitelistEtag({
          groupId: resource.groupId,
          updatedAt: resource.groupUpdatedAt,
          enabled: resource.enabled,
        });
        response.setHeader('ETag', etag);
        response.setHeader('Cache-Control', 'no-cache');
        if (matchesIfNoneMatch(req, etag)) {
          response.status(304).end();
          return;
        }

        response.type('text/plain').send(resource.content);
      }
    )(req, res);
  });
}
