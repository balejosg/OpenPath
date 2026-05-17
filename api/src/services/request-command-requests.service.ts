import * as push from '../lib/push.js';
import * as storage from '../lib/storage.js';
import { logger } from '../lib/logger.js';
import { normalizeManualRequestDomain } from '@openpath/shared/domain';

import type { RequestResult } from './request-service-shared.js';
import {
  createStoredRequest,
  toErrorMessage,
  type RequestCreationInput,
  type StoredDomainRequest,
} from './request-command-shared.js';

export async function createRequest(
  input: RequestCreationInput
): Promise<RequestResult<StoredDomainRequest>> {
  const normalizedInput = {
    ...input,
    domain:
      input.source === 'auto_extension' ? input.domain : normalizeManualRequestDomain(input.domain),
  };

  if (await storage.hasPendingRequest(normalizedInput.domain)) {
    return {
      ok: false,
      error: { code: 'CONFLICT', message: 'Pending request exists for this domain' },
    };
  }

  try {
    const request = await createStoredRequest(normalizedInput);

    push.notifyTeachersOfNewRequest(request).catch((error: unknown) => {
      logger.error('Failed to notify teachers of new request', {
        requestId: request.id,
        domain: request.domain,
        error: toErrorMessage(error),
      });
    });

    return { ok: true, data: request };
  } catch (error) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: toErrorMessage(error) },
    };
  }
}

export async function deleteRequest(id: string): Promise<RequestResult<{ success: boolean }>> {
  const deleted = await storage.deleteRequest(id);
  if (!deleted) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Request not found' } };
  }
  return { ok: true, data: { success: true } };
}
