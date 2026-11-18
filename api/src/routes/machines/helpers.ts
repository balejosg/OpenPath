import type { Request, Response } from 'express';

import { logger } from '../../lib/logger.js';
import {
  FAIL_OPEN_RESPONSE,
  type MachineWhitelistDelivery,
} from '../../services/machine-policy.service.js';

export interface MachineRouteDeps {
  getCurrentEvaluationTime: () => Date;
}

export function getWildcardPathParam(value: string | string[] | undefined): string {
  if (Array.isArray(value)) {
    return value
      .map((segment) => segment.trim())
      .filter(Boolean)
      .join('/');
  }

  return value?.trim() ?? '';
}

export function sendMachineServiceError(
  res: Response,
  error: { code: string; message: string }
): void {
  const statusMap: Record<string, number> = {
    UNAUTHORIZED: 401,
    FORBIDDEN: 403,
    NOT_FOUND: 404,
    BAD_REQUEST: 400,
    CONFLICT: 409,
    UNAVAILABLE: 503,
  };

  res.status(statusMap[error.code] ?? 400).json({ success: false, error: error.message });
}

export function sendJsonInternalError(res: Response, message = 'Internal error'): void {
  res.status(500).json({ success: false, error: message });
}

export function sendWhitelistDelivery(res: Response, delivery: MachineWhitelistDelivery): void {
  res.setHeader('Cache-Control', delivery.cacheControl);
  if ('pragma' in delivery && delivery.pragma) {
    res.setHeader('Pragma', delivery.pragma);
  }
  if ('etag' in delivery && delivery.etag) {
    res.setHeader('ETag', delivery.etag);
  }

  if (delivery.kind === 'not-modified') {
    res.status(304).end();
    return;
  }

  res.type('text/plain').send(delivery.body);
}

export function sendFailOpenWhitelist(res: Response): void {
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.setHeader('Pragma', 'no-cache');
  res.type('text/plain').send(FAIL_OPEN_RESPONSE);
}

export function createRouteHandler(
  logMessage: string,
  onError: (res: Response) => void,
  handler: (req: Request, res: Response) => Promise<void>
): (req: Request, res: Response) => void {
  return (req: Request, res: Response): void => {
    void handler(req, res).catch((error: unknown) => {
      logger.error(logMessage, {
        error: error instanceof Error ? error.message : String(error),
      });
      if (!res.headersSent) {
        onError(res);
      }
    });
  };
}
