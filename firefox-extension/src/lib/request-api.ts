import type { RequestConfig } from './config-storage.js';

export interface SubmitBlockedDomainApiResponse {
  success?: boolean;
  id?: string;
  status?: 'pending' | 'approved' | 'rejected';
  domain?: string;
  error?: string;
}

export interface SubmitBlockedDomainResult {
  success: boolean;
  id?: string;
  status?: 'pending' | 'approved' | 'rejected';
  domain?: string;
  error?: string;
}

export interface SubmitBlockedDomainInput {
  domain?: string;
  reason?: string;
  origin?: string;
  error?: string;
}

export interface RequestApiRuntimeConfig {
  requestApiUrl: RequestConfig['requestApiUrl'];
  fallbackApiUrls: RequestConfig['fallbackApiUrls'];
  requestTimeout: RequestConfig['requestTimeout'];
  enableRequests: RequestConfig['enableRequests'];
}

function isPendingRequestConflict(
  response: Response,
  payload: SubmitBlockedDomainApiResponse
): boolean {
  return (
    response.status === 409 &&
    typeof payload.error === 'string' &&
    /pending request exists for this domain/i.test(payload.error)
  );
}

export async function fetchWithFallback(
  endpoints: string[],
  path: string,
  init: RequestInit,
  timeoutMs: number,
  fetchImpl: typeof fetch = fetch
): Promise<Response> {
  let lastError: Error | null = null;

  for (const endpoint of endpoints) {
    const controller = new AbortController();
    const timeout = setTimeout(() => {
      controller.abort();
    }, timeoutMs);

    try {
      const response = await fetchImpl(`${endpoint}${path}`, {
        ...init,
        signal: controller.signal,
      });
      clearTimeout(timeout);
      return response;
    } catch (error) {
      clearTimeout(timeout);
      lastError = error instanceof Error ? error : new Error(String(error));
    }
  }

  throw lastError ?? new Error('No API endpoint available');
}

export async function submitBlockedDomainRequest(
  input: SubmitBlockedDomainInput,
  deps: {
    buildBlockedDomainSubmitBody: (input: {
      clientVersion: string;
      domain: string;
      error?: string;
      hostname: string;
      origin?: string;
      reason: string;
      token: string;
    }) => unknown;
    fetchImpl?: typeof fetch;
    getClientVersion: () => string;
    getRequestApiEndpoints: (config: RequestApiRuntimeConfig) => string[];
    loadRequestConfig: () => Promise<RequestApiRuntimeConfig>;
    sendNativeMessage: (message: unknown) => Promise<unknown>;
  }
): Promise<SubmitBlockedDomainResult> {
  const domain = input.domain?.trim();
  const reason = input.reason?.trim();

  if (!domain || !reason || reason.length < 3) {
    return { success: false, error: 'domain and reason are required' };
  }

  const requestConfig = await deps.loadRequestConfig();
  const endpoints = deps.getRequestApiEndpoints(requestConfig);
  if (!requestConfig.enableRequests || endpoints.length === 0) {
    return {
      success: false,
      error:
        'Configuracion incompleta: Firefox no recibio la URL de API del host nativo de OpenPath',
    };
  }

  const hostnameResponse = (await deps.sendNativeMessage({ action: 'get-hostname' })) as {
    success: boolean;
    hostname?: string;
    error?: string;
  };
  if (!hostnameResponse.success || !hostnameResponse.hostname) {
    return {
      success: false,
      error: hostnameResponse.error ?? 'No se pudo obtener el hostname del equipo',
    };
  }

  const tokenResponse = (await deps.sendNativeMessage({ action: 'get-machine-token' })) as {
    success: boolean;
    token?: string;
    error?: string;
  };
  if (!tokenResponse.success || !tokenResponse.token) {
    return {
      success: false,
      error: tokenResponse.error ?? 'No se pudo obtener token de la maquina',
    };
  }

  const requestBody = deps.buildBlockedDomainSubmitBody({
    domain,
    reason,
    token: tokenResponse.token,
    hostname: hostnameResponse.hostname,
    clientVersion: deps.getClientVersion(),
    ...(input.origin !== undefined ? { origin: input.origin } : {}),
    ...(input.error !== undefined ? { error: input.error } : {}),
  });

  const response = await fetchWithFallback(
    endpoints,
    '/api/requests/submit',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(requestBody),
    },
    requestConfig.requestTimeout,
    deps.fetchImpl
  );

  const payload = (await response
    .json()
    .catch((): SubmitBlockedDomainApiResponse => ({}))) as SubmitBlockedDomainApiResponse;

  if (isPendingRequestConflict(response, payload)) {
    return {
      success: true,
      status: 'pending',
      domain,
    };
  }

  if (!response.ok || payload.success !== true) {
    return {
      success: false,
      error: payload.error ?? `No se pudo enviar la solicitud (${response.status.toString()})`,
    };
  }

  return {
    success: true,
    ...(payload.id ? { id: payload.id } : {}),
    ...(payload.status ? { status: payload.status } : {}),
    ...(payload.domain ? { domain: payload.domain } : {}),
  };
}
