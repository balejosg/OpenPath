import type express from 'express';
import type { Request, Response } from 'express';

import * as api from './api-client.js';
import { asyncHandler, getApiClient, getFirstValue, requireAuth } from './app-middleware.js';
import { getTRPCErrorCode, isTRPCError } from './trpc.js';

export function registerDashboardRoutes(app: express.Express): void {
  app.get(
    '/api/stats',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const stats = await getApiClient(req).getStats();
      res.json(stats);
    })
  );

  app.get(
    '/api/system/status',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const status = await getApiClient(req).getSystemStatus();
      res.json(status);
    })
  );

  app.post(
    '/api/system/toggle',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const { enable } = req.body as Record<string, unknown>;
      const status = await getApiClient(req).toggleSystemStatus(!!enable);
      res.json({ success: true, ...status });
    })
  );

  app.get(
    '/api/groups',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const groups = await getApiClient(req).getAllGroups();
      res.json(groups);
    })
  );

  app.post(
    '/api/groups',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const { name, displayName } = req.body as Record<string, unknown>;
      if (!name || !displayName || typeof name !== 'string' || typeof displayName !== 'string') {
        res.status(400).json({ error: 'Name is required' });
        return;
      }

      try {
        const result = await getApiClient(req).createGroup(name, displayName);
        res.json({ success: true, id: result.id, name: result.name });
      } catch (err: unknown) {
        if (isTRPCError(err) && getTRPCErrorCode(err) === 'CONFLICT') {
          res.status(400).json({ error: 'A group with that name already exists' });
          return;
        }
        throw err;
      }
    })
  );

  app.get(
    '/api/groups/:id',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const id = getFirstValue(req.params.id);
      if (!id) {
        res.status(400).json({ error: 'ID is required' });
        return;
      }

      const group = await getApiClient(req).getGroupById(id);
      if (!group) {
        res.status(404).json({ error: 'Group not found' });
        return;
      }
      res.json(group);
    })
  );

  app.put(
    '/api/groups/:id',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const id = getFirstValue(req.params.id);
      if (!id) {
        res.status(400).json({ error: 'ID is required' });
        return;
      }

      const { displayName, enabled } = req.body as Record<string, unknown>;
      if (typeof displayName !== 'string') {
        res.status(400).json({ error: 'Invalid details' });
        return;
      }

      await getApiClient(req).updateGroup(id, displayName, !!enabled);
      res.json({ success: true });
    })
  );

  app.delete(
    '/api/groups/:id',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const id = getFirstValue(req.params.id);
      if (!id) {
        res.status(400).json({ error: 'ID is required' });
        return;
      }

      await getApiClient(req).deleteGroup(id);
      res.json({ success: true });
    })
  );

  app.get(
    '/api/groups/:groupId/rules',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const groupId = getFirstValue(req.params.groupId);
      if (!groupId) {
        res.status(400).json({ error: 'Group ID is required' });
        return;
      }

      const type = getFirstValue(req.query.type as string | string[] | undefined);
      const rules = await getApiClient(req).getRulesByGroup(
        groupId,
        (type as api.RuleType | undefined) ?? undefined
      );
      res.json(rules);
    })
  );

  app.post(
    '/api/groups/:groupId/rules',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const groupId = getFirstValue(req.params.groupId);
      if (!groupId) {
        res.status(400).json({ error: 'Group ID is required' });
        return;
      }

      const { type, value, comment } = req.body as Record<string, unknown>;
      if (!type || !value || typeof type !== 'string' || typeof value !== 'string') {
        res.status(400).json({ error: 'Type and value are required' });
        return;
      }

      try {
        const result = await getApiClient(req).createRule(
          groupId,
          type as api.RuleType,
          value,
          comment as string | undefined
        );
        res.json({ success: true, id: result.id });
      } catch (err: unknown) {
        if (isTRPCError(err) && getTRPCErrorCode(err) === 'CONFLICT') {
          res.status(400).json({ error: 'Rule already exists' });
          return;
        }
        throw err;
      }
    })
  );

  app.post(
    '/api/groups/:groupId/rules/bulk',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const groupId = getFirstValue(req.params.groupId);
      if (!groupId) {
        res.status(400).json({ error: 'Group ID is required' });
        return;
      }

      const { type, values } = req.body as Record<string, unknown>;
      if (!type || !values || !Array.isArray(values)) {
        res.status(400).json({ error: 'Type and values are required' });
        return;
      }

      const count = await getApiClient(req).bulkCreateRules(
        groupId,
        type as api.RuleType,
        values as string[]
      );
      res.json({ success: true, count });
    })
  );

  app.delete(
    '/api/rules/:id',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const id = getFirstValue(req.params.id);
      if (!id) {
        res.status(400).json({ error: 'ID is required' });
        return;
      }

      await getApiClient(req).deleteRule(id);
      res.json({ success: true });
    })
  );

  app.get('/export/:name.txt', (req: Request, res: Response): void => {
    const name = getFirstValue(req.params.name);
    if (!name) {
      res.status(400).send('Name is required');
      return;
    }

    res.redirect(api.getExportUrl(name));
  });
}
