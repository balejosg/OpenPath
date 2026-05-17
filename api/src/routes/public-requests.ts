import type { Express, Request, Response } from 'express';

import {
  type AutoMachineRequestOutcome,
  handleAutoMachineRequest,
  type PendingMachineRequestOutcome,
  type PublicRequestResult,
  submitMachineRequest,
} from '../services/public-request.service.js';
import RequestService from '../services/request.service.js';
import {
  normalizeDiagnosticContext,
  parseAutoRequestPayload,
  parseSubmitRequestPayload,
} from '../lib/public-request-input.js';
import { createAsyncRouteHandler, sendJsonInternalError } from './route-helpers.js';

function sendRequestServiceError(res: Response, error: { code: string; message: string }): void {
  const statusMap: Record<string, number> = {
    CONFLICT: 409,
    NOT_FOUND: 404,
    FORBIDDEN: 403,
    BAD_REQUEST: 400,
  };
  const statusCode = statusMap[error.code] ?? 400;
  res.status(statusCode).json({
    success: false,
    error: error.message,
  });
}

export function registerPublicRequestRoutes(app: Express): void {
  app.get(
    '/api/requests/status/:id',
    createAsyncRouteHandler(
      'Request status route failed',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const requestId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
        const result = await RequestService.getRequestStatus(requestId ?? '');
        if (!result.ok) {
          sendRequestServiceError(res, result.error);
          return;
        }

        res.json({
          success: true,
          ...result.data,
        });
      }
    )
  );

  app.post(
    '/api/requests/auto',
    createAsyncRouteHandler(
      'Auto request route failed',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const body = parseAutoRequestPayload(req.body);

        if (!body.domainRaw || !body.hostnameRaw || !body.token) {
          res.status(400).json({
            success: false,
            error: 'domain, hostname and token are required',
          });
          return;
        }

        const result: PublicRequestResult<AutoMachineRequestOutcome> =
          await handleAutoMachineRequest({
            domainRaw: body.domainRaw,
            hostnameRaw: body.hostnameRaw,
            token: body.token,
            originPage: body.originPageRaw.slice(0, 2048) || undefined,
            targetUrl: body.targetUrlRaw.slice(0, 2048) || undefined,
            reason: body.reasonRaw.slice(0, 200) || undefined,
            diagnosticContext: normalizeDiagnosticContext(body.diagnosticContextRaw),
          });

        if (!result.ok) {
          sendRequestServiceError(res, result.error);
          return;
        }

        if (!result.data.autoApproved) {
          const pendingData: PendingMachineRequestOutcome = result.data;
          res.json({
            success: true,
            id: pendingData.requestId,
            approved: false,
            autoApproved: false,
            status: pendingData.requestStatus,
            groupId: pendingData.groupId,
            domain: pendingData.domain,
            source: pendingData.source,
          });
          return;
        }

        res.json({
          success: true,
          approved: true,
          autoApproved: true,
          status: result.data.status,
          groupId: result.data.groupId,
          domain: result.data.domain,
          source: result.data.source,
          duplicate: result.data.duplicate,
        });
      }
    )
  );

  app.post(
    '/api/requests/submit',
    createAsyncRouteHandler(
      'Request submit route failed',
      sendJsonInternalError,
      async (req: Request, res: Response): Promise<void> => {
        const body = parseSubmitRequestPayload(req.body);

        if (!body.domainRaw || !body.hostnameRaw || !body.token) {
          res.status(400).json({
            success: false,
            error: 'domain, hostname and token are required',
          });
          return;
        }

        const created: PublicRequestResult<PendingMachineRequestOutcome> =
          await submitMachineRequest({
            domainRaw: body.domainRaw,
            hostnameRaw: body.hostnameRaw,
            token: body.token,
            reason: body.reasonRaw.slice(0, 200) || undefined,
            originHost: body.originHostRaw.slice(0, 255) || undefined,
            originPage: body.originPageRaw.slice(0, 2048) || undefined,
            clientVersion: body.clientVersionRaw.slice(0, 50) || undefined,
            errorType: body.errorTypeRaw.slice(0, 100) || undefined,
          });

        if (!created.ok) {
          sendRequestServiceError(res, created.error);
          return;
        }

        const pendingData: PendingMachineRequestOutcome = created.data;
        res.json({
          success: true,
          id: pendingData.requestId,
          status: pendingData.requestStatus,
          groupId: pendingData.groupId,
          domain: pendingData.domain,
          source: pendingData.source,
        });
      }
    )
  );
}
