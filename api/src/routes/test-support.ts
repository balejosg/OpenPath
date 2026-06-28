import type { Express, Request, Response } from 'express';

import { config } from '../config.js';
import { verifyAccessTokenFromRequest } from '../lib/server-request-auth.js';
import TestSupportService from '../services/test-support.service.js';
import { createAsyncRouteHandler, sendJsonInternalError } from './route-helpers.js';

function getBodyField(body: unknown, key: string): unknown {
  if (typeof body !== 'object' || body === null) {
    return undefined;
  }

  return (body as Record<string, unknown>)[key];
}

function hasTeacherOrAdminRole(roles: readonly unknown[]): boolean {
  return roles.some((role): boolean => {
    if (typeof role !== 'object' || role === null) {
      return false;
    }

    const roleName = (role as { role?: unknown }).role;
    return roleName === 'admin' || roleName === 'teacher';
  });
}

async function requireTeacherOrAdmin(req: Request, res: Response): Promise<boolean> {
  const decoded = await verifyAccessTokenFromRequest(req);
  if (!decoded) {
    res.status(401).json({ success: false, error: 'Authorization required' });
    return false;
  }

  if (!hasTeacherOrAdminRole(decoded.roles)) {
    res.status(403).json({ success: false, error: 'Teacher access required' });
    return false;
  }

  return true;
}

async function handleMachineContext(
  req: Request,
  res: Response,
  deps: {
    getCurrentEvaluationTime: () => Date;
  }
): Promise<void> {
  const authorized = await requireTeacherOrAdmin(req, res);
  if (!authorized) return;

  const hostname = Array.isArray(req.params.hostname)
    ? req.params.hostname[0]
    : req.params.hostname;
  if (!hostname) {
    res.status(400).json({ success: false, error: 'hostname is required' });
    return;
  }

  const now = deps.getCurrentEvaluationTime();
  const snapshot = await TestSupportService.getMachineContextSnapshot(hostname, now);

  res.json({
    success: true,
    ...snapshot,
  });
}

async function handleClock(
  req: Request,
  res: Response,
  deps: {
    setTestNowOverride: (nextValue: Date | null) => void;
  }
): Promise<void> {
  const authorized = await requireTeacherOrAdmin(req, res);
  if (!authorized) return;

  const rawAt = getBodyField(req.body as unknown, 'at');
  if (rawAt === null) {
    deps.setTestNowOverride(null);
    res.json({ success: true, now: null });
    return;
  }

  if (typeof rawAt !== 'string' || rawAt.trim() === '') {
    res.status(400).json({ success: false, error: 'at must be an ISO timestamp or null' });
    return;
  }

  const at = new Date(rawAt);
  if (!Number.isFinite(at.getTime())) {
    res.status(400).json({ success: false, error: 'at must be a valid ISO timestamp' });
    return;
  }

  deps.setTestNowOverride(at);
  res.json({ success: true, now: at.toISOString() });
}

async function handleTickBoundaries(req: Request, res: Response): Promise<void> {
  const authorized = await requireTeacherOrAdmin(req, res);
  if (!authorized) return;

  const rawAt = getBodyField(req.body as unknown, 'at');
  if (typeof rawAt !== 'string' || rawAt.trim() === '') {
    res.status(400).json({ success: false, error: 'at ISO timestamp is required' });
    return;
  }

  const at = new Date(rawAt);
  if (!Number.isFinite(at.getTime())) {
    res.status(400).json({ success: false, error: 'at must be a valid ISO timestamp' });
    return;
  }

  res.json({ success: true, ...(await TestSupportService.tickScheduleBoundaries(at)) });
}

export function registerTestSupportRoutes(
  app: Express,
  deps: {
    getCurrentEvaluationTime: () => Date;
    setTestNowOverride: (nextValue: Date | null) => void;
  }
): void {
  if (!config.isTest) {
    return;
  }

  app.get(
    '/api/test-support/machine-context/:hostname',
    createAsyncRouteHandler(
      'Test-support machine context error',
      sendJsonInternalError,
      (req, res) =>
        handleMachineContext(req, res, { getCurrentEvaluationTime: deps.getCurrentEvaluationTime })
    )
  );

  app.post(
    '/api/test-support/clock',
    createAsyncRouteHandler('Test-support clock error', sendJsonInternalError, (req, res) =>
      handleClock(req, res, { setTestNowOverride: deps.setTestNowOverride })
    )
  );

  app.post(
    '/api/test-support/tick-boundaries',
    createAsyncRouteHandler(
      'Test-support schedule tick error',
      sendJsonInternalError,
      handleTickBoundaries
    )
  );
}
