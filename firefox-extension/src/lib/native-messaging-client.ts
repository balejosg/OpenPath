import type { Browser, Runtime } from 'webextension-polyfill';

import { getErrorMessage, logger as defaultLogger } from './logger.js';

declare const browser: Browser;

export interface NativeResponse {
  success: boolean;
  [key: string]: unknown;
}

export interface NativeBlockedSubdomainsResponse extends NativeResponse {
  action?: 'get-blocked-subdomains';
  subdomains?: string[];
  count?: number;
  hash?: string;
  mtime?: number;
  source?: string;
  error?: string;
}

export interface NativeCheckResult {
  domain: string;
  in_whitelist: boolean;
  policy_active?: boolean;
  resolves?: boolean;
  resolved_ip?: string;
  error?: string;
}

export interface NativeCheckResponse {
  success: boolean;
  results?: NativeCheckResult[];
  error?: string;
}

export interface VerifyResult {
  domain: string;
  inWhitelist: boolean;
  policyActive?: boolean;
  resolves?: boolean;
  resolvedIp?: string;
  error?: string;
}

export interface VerifyResponse {
  success: boolean;
  results: VerifyResult[];
  error?: string;
}

export interface NativeMessagingClient {
  allowLocalRuntimeDependency: (input: {
    anchorHost: string;
    dependencyHost: string;
    requestType: string;
  }) => Promise<NativeResponse>;
  checkDomains: (domains: string[]) => Promise<VerifyResponse>;
  connect: () => Promise<boolean>;
  isAvailable: () => Promise<boolean>;
  requestLocalWhitelistUpdate: (domains?: string[]) => Promise<boolean>;
  sendMessage: (message: unknown) => Promise<unknown>;
}

export function createNativeMessagingClient(options: {
  browserApi?: Browser;
  hostName: string;
  logger?: Pick<typeof defaultLogger, 'error' | 'info'>;
}): NativeMessagingClient {
  const browserApi = options.browserApi ?? browser;
  const logger = options.logger ?? defaultLogger;
  let nativePort: Runtime.Port | null = null;

  async function connect(): Promise<boolean> {
    return new Promise((resolve) => {
      try {
        nativePort = browserApi.runtime.connectNative(options.hostName);
        nativePort.onDisconnect.addListener(() => {
          logger.info('[Monitor] Native host desconectado', {
            lastError: browserApi.runtime.lastError,
          });
          nativePort = null;
        });

        logger.info('[Monitor] Native host conectado');
        resolve(true);
      } catch (error) {
        logger.error('[Monitor] Error conectando Native host', {
          error: getErrorMessage(error),
        });
        nativePort = null;
        resolve(false);
      }
    });
  }

  async function sendMessage(message: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const attempt = async (): Promise<void> => {
        try {
          if (!nativePort) {
            const connected = await connect();
            if (!connected) {
              reject(new Error('No se pudo conectar con el host nativo'));
              return;
            }
          }

          const response = await browserApi.runtime.sendNativeMessage(
            options.hostName,
            message as object
          );

          resolve(response);
        } catch (error) {
          logger.error('[Monitor] Error en Native Messaging', { error: getErrorMessage(error) });
          reject(error instanceof Error ? error : new Error(String(error)));
        }
      };

      void attempt();
    });
  }

  async function checkDomains(domains: string[]): Promise<VerifyResponse> {
    try {
      const response = await sendMessage({ action: 'check', domains });
      const nativeResponse = response as NativeCheckResponse;
      const results: VerifyResult[] = (nativeResponse.results ?? []).map((result) => {
        const mapped: VerifyResult = {
          domain: result.domain,
          inWhitelist: result.in_whitelist,
        };

        if (result.policy_active !== undefined) {
          mapped.policyActive = result.policy_active;
        }
        if (result.resolves !== undefined) {
          mapped.resolves = result.resolves;
        }
        if (result.resolved_ip !== undefined) {
          mapped.resolvedIp = result.resolved_ip;
        }
        if (result.error !== undefined) {
          mapped.error = result.error;
        }

        return mapped;
      });

      return {
        success: nativeResponse.success,
        results,
        ...(nativeResponse.error !== undefined ? { error: nativeResponse.error } : {}),
      };
    } catch (error) {
      return {
        success: false,
        results: [],
        error: error instanceof Error ? error.message : 'Error desconocido',
      };
    }
  }

  async function isAvailable(): Promise<boolean> {
    try {
      const response = (await sendMessage({ action: 'ping' })) as NativeResponse;
      return response.success;
    } catch {
      return false;
    }
  }

  async function requestLocalWhitelistUpdate(domains: string[] = []): Promise<boolean> {
    try {
      const response = (await sendMessage({
        action: 'update-whitelist',
        ...(domains.length > 0 ? { domains } : {}),
      })) as NativeResponse;
      return response.success;
    } catch {
      return false;
    }
  }

  async function allowLocalRuntimeDependency(input: {
    anchorHost: string;
    dependencyHost: string;
    requestType: string;
  }): Promise<NativeResponse> {
    const response = (await sendMessage({
      action: 'allow-local-runtime-dependency',
      anchorHost: input.anchorHost,
      dependencyHost: input.dependencyHost,
      requestType: input.requestType,
    })) as NativeResponse;
    return response;
  }

  return {
    allowLocalRuntimeDependency,
    checkDomains,
    connect,
    isAvailable,
    requestLocalWhitelistUpdate,
    sendMessage,
  };
}
