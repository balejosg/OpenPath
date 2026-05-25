import type { Browser, Runtime } from 'webextension-polyfill';

import { t } from './i18n.js';
import { getErrorMessage, logger as defaultLogger } from './logger.js';
import {
  LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS,
  LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS,
  LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS,
  RUNTIME_DEPENDENCY_ACTIONS,
  createRuntimeDependencyCacheKey,
  createRuntimeDependencyPendingKey,
  isQueuedRuntimeDependencyResponse,
  type LocalRuntimeDependencyInput,
} from './runtime-dependency-protocol.js';

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
  portal_recovery_eligible?: boolean;
  portal_recovery_signal?: string;
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
  portalRecoveryEligible?: boolean;
  portalRecoverySignal?: string;
  resolves?: boolean;
  resolvedIp?: string;
  error?: string;
}

export interface VerifyResponse {
  success: boolean;
  results: VerifyResult[];
  error?: string;
}

export interface CaptivePortalRecoveryInput {
  operation?: 'open' | 'reconcile';
  portalState?: string;
  source?: string;
  tabId?: number;
  triggerHost?: string;
}

export interface CaptivePortalRecoveryResponse extends NativeResponse {
  action?: 'recover-captive-portal-navigation';
  portalModeActive?: boolean;
  requestId?: string;
  state?: string;
  triggerHost?: string;
}

interface LocalRuntimeDependencyBatchResponse extends NativeResponse {
  action?: typeof RUNTIME_DEPENDENCY_ACTIONS.allowLocalBatch;
  results?: NativeResponse[];
  error?: string;
}

interface PendingLocalRuntimeDependency {
  input: LocalRuntimeDependencyInput;
  key: string;
  resolve: (response: NativeResponse) => void;
  reject: (error: unknown) => void;
}

export interface NativeMessagingClient {
  allowLocalRuntimeDependency: (input: LocalRuntimeDependencyInput) => Promise<NativeResponse>;
  checkDomains: (
    domains: string[],
    context?: { error?: string; source?: string }
  ) => Promise<VerifyResponse>;
  connect: () => Promise<boolean>;
  isAvailable: () => Promise<boolean>;
  recoverCaptivePortalNavigation: (
    input: CaptivePortalRecoveryInput
  ) => Promise<CaptivePortalRecoveryResponse>;
  requestLocalWhitelistUpdate: (domains?: string[]) => Promise<boolean>;
  sendMessage: (message: unknown) => Promise<unknown>;
}

export function createNativeMessagingClient(options: {
  browserApi?: Browser;
  hostName: string;
  logger?: Pick<typeof defaultLogger, 'error' | 'info'>;
  runtimeDependencyCacheMaxEntries?: number;
}): NativeMessagingClient {
  const browserApi = options.browserApi ?? browser;
  const logger = options.logger ?? defaultLogger;
  const runtimeDependencyCacheMaxEntries =
    options.runtimeDependencyCacheMaxEntries ?? LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES;
  let nativePort: Runtime.Port | null = null;
  const runtimeDependencyCache = new Map<string, number>();
  const queuedRuntimeDependencyDedupeCache = new Map<
    string,
    { expiresAt: number; response: NativeResponse }
  >();
  const pendingRuntimeDependencies: PendingLocalRuntimeDependency[] = [];
  const pendingRuntimeDependencyByKey = new Map<string, Promise<NativeResponse>>();
  let runtimeDependencyBatchTimer: ReturnType<typeof setTimeout> | null = null;

  async function connect(): Promise<boolean> {
    return new Promise((resolve) => {
      try {
        nativePort = browserApi.runtime.connectNative(options.hostName);
        nativePort.onDisconnect.addListener(() => {
          logger.info('[Monitor] Native host disconnected', {
            lastError: browserApi.runtime.lastError,
          });
          nativePort = null;
        });

        logger.info('[Monitor] Native host connected');
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
          // connectNative() owns the long-lived native-host availability state, while
          // sendNativeMessage() keeps individual request/response actions one-shot.
          if (!nativePort) {
            const connected = await connect();
            if (!connected) {
              reject(new Error(t('popupNativeHostConnectError')));
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

  async function checkDomains(
    domains: string[],
    context?: { error?: string; source?: string }
  ): Promise<VerifyResponse> {
    try {
      const response = await sendMessage({
        action: 'check',
        domains,
        ...(context?.error ? { error: context.error } : {}),
        ...(context?.source ? { source: context.source } : {}),
      });
      const nativeResponse = response as NativeCheckResponse;
      const results: VerifyResult[] = (nativeResponse.results ?? []).map((result) => {
        const mapped: VerifyResult = {
          domain: result.domain,
          inWhitelist: result.in_whitelist,
        };

        if (result.policy_active !== undefined) {
          mapped.policyActive = result.policy_active;
        }
        if (result.portal_recovery_eligible !== undefined) {
          mapped.portalRecoveryEligible = result.portal_recovery_eligible;
        }
        if (result.portal_recovery_signal !== undefined) {
          mapped.portalRecoverySignal = result.portal_recovery_signal;
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
        error: error instanceof Error ? error.message : t('popupUnknownError'),
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

  async function recoverCaptivePortalNavigation(
    input: CaptivePortalRecoveryInput
  ): Promise<CaptivePortalRecoveryResponse> {
    return (await sendMessage({
      action: 'recover-captive-portal-navigation',
      operation: input.operation ?? 'open',
      ...(input.triggerHost !== undefined ? { triggerHost: input.triggerHost } : {}),
      ...(input.portalState !== undefined ? { portalState: input.portalState } : {}),
      ...(input.source !== undefined ? { source: input.source } : {}),
      ...(input.tabId !== undefined ? { tabId: input.tabId } : {}),
    })) as CaptivePortalRecoveryResponse;
  }

  function pruneExpiredRuntimeDependencyEntries<T extends number | { expiresAt: number }>(
    cache: Map<string, T>,
    now: number
  ): void {
    for (const [key, value] of cache) {
      const expiresAt = typeof value === 'number' ? value : value.expiresAt;
      if (expiresAt <= now) {
        cache.delete(key);
      }
    }
  }

  function trimOldestRuntimeDependencyEntries<T>(cache: Map<string, T>): void {
    while (cache.size > runtimeDependencyCacheMaxEntries) {
      const oldestKey = cache.keys().next().value;
      if (oldestKey === undefined) {
        return;
      }
      cache.delete(oldestKey);
    }
  }

  function getCachedRuntimeDependency(input: LocalRuntimeDependencyInput): NativeResponse | null {
    const now = Date.now();
    pruneExpiredRuntimeDependencyEntries(runtimeDependencyCache, now);
    const cacheKey = createRuntimeDependencyCacheKey(input);
    const expiresAt = runtimeDependencyCache.get(cacheKey);
    if (expiresAt === undefined) {
      return null;
    }

    return {
      success: true,
      action: RUNTIME_DEPENDENCY_ACTIONS.allowLocal,
      anchorHost: input.anchorHost,
      dependencyHost: input.dependencyHost,
      cached: true,
    };
  }

  function getQueuedRuntimeDependencyDedupe(
    input: LocalRuntimeDependencyInput
  ): NativeResponse | null {
    const now = Date.now();
    pruneExpiredRuntimeDependencyEntries(queuedRuntimeDependencyDedupeCache, now);
    const pendingKey = createRuntimeDependencyPendingKey(input);
    const cached = queuedRuntimeDependencyDedupeCache.get(pendingKey);
    if (!cached) {
      return null;
    }

    return { ...cached.response, deduped: true };
  }

  function cacheRuntimeDependencySuccess(
    input: LocalRuntimeDependencyInput,
    response: NativeResponse
  ): void {
    const now = Date.now();
    if (!response.success) {
      return;
    }
    if (isQueuedRuntimeDependencyResponse(response)) {
      pruneExpiredRuntimeDependencyEntries(queuedRuntimeDependencyDedupeCache, now);
      queuedRuntimeDependencyDedupeCache.set(createRuntimeDependencyPendingKey(input), {
        expiresAt: now + LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS,
        response,
      });
      trimOldestRuntimeDependencyEntries(queuedRuntimeDependencyDedupeCache);
      return;
    }
    pruneExpiredRuntimeDependencyEntries(runtimeDependencyCache, now);
    runtimeDependencyCache.set(
      createRuntimeDependencyCacheKey(input),
      now + LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS
    );
    trimOldestRuntimeDependencyEntries(runtimeDependencyCache);
  }

  async function sendSingleLocalRuntimeDependency(
    input: LocalRuntimeDependencyInput
  ): Promise<NativeResponse> {
    const response = (await sendMessage({
      action: RUNTIME_DEPENDENCY_ACTIONS.allowLocal,
      anchorHost: input.anchorHost,
      dependencyHost: input.dependencyHost,
      requestType: input.requestType,
    })) as NativeResponse;
    cacheRuntimeDependencySuccess(input, response);
    return response;
  }

  function isBatchUnsupported(response: LocalRuntimeDependencyBatchResponse): boolean {
    const error = typeof response.error === 'string' ? response.error.toLowerCase() : '';
    return (
      !response.success &&
      (error.includes('unknown action') || error.includes('unsupported')) &&
      !Array.isArray(response.results)
    );
  }

  function findBatchResult(
    response: LocalRuntimeDependencyBatchResponse,
    input: LocalRuntimeDependencyInput,
    index: number
  ): NativeResponse {
    const results = Array.isArray(response.results) ? response.results : [];
    const exactResult = results.find((candidate) => {
      const result = candidate as {
        anchorHost?: unknown;
        dependencyHost?: unknown;
        requestType?: unknown;
      };
      return (
        result.anchorHost === input.anchorHost &&
        result.dependencyHost === input.dependencyHost &&
        result.requestType === input.requestType
      );
    });

    return exactResult ?? results[index] ?? response;
  }

  function scheduleRuntimeDependencyFlush(): void {
    if (runtimeDependencyBatchTimer !== null) {
      return;
    }

    runtimeDependencyBatchTimer = setTimeout(() => {
      runtimeDependencyBatchTimer = null;
      void flushRuntimeDependencyBatch();
    }, LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS);
  }

  async function flushRuntimeDependencyBatch(): Promise<void> {
    const batch = pendingRuntimeDependencies.splice(0, LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES);
    for (const request of batch) {
      pendingRuntimeDependencyByKey.delete(request.key);
    }

    if (pendingRuntimeDependencies.length > 0) {
      scheduleRuntimeDependencyFlush();
    }
    if (batch.length === 0) {
      return;
    }

    try {
      const batchResponse = (await sendMessage({
        action: RUNTIME_DEPENDENCY_ACTIONS.allowLocalBatch,
        entries: batch.map((request) => request.input),
      })) as LocalRuntimeDependencyBatchResponse;

      if (isBatchUnsupported(batchResponse)) {
        await Promise.all(
          batch.map(async (request) => {
            try {
              request.resolve(await sendSingleLocalRuntimeDependency(request.input));
            } catch (error) {
              request.reject(error);
            }
          })
        );
        return;
      }

      batch.forEach((request, index) => {
        const response = findBatchResult(batchResponse, request.input, index);
        cacheRuntimeDependencySuccess(request.input, response);
        request.resolve(response);
      });
    } catch (error) {
      batch.forEach((request) => {
        request.reject(error);
      });
    }
  }

  async function allowLocalRuntimeDependency(
    input: LocalRuntimeDependencyInput
  ): Promise<NativeResponse> {
    const cachedResponse = getCachedRuntimeDependency(input);
    if (cachedResponse) {
      return cachedResponse;
    }
    const queuedDedupeResponse = getQueuedRuntimeDependencyDedupe(input);
    if (queuedDedupeResponse) {
      return queuedDedupeResponse;
    }

    const pendingKey = createRuntimeDependencyPendingKey(input);
    const existingRequest = pendingRuntimeDependencyByKey.get(pendingKey);
    if (existingRequest) {
      return existingRequest;
    }

    const pendingRequest = new Promise<NativeResponse>((resolve, reject) => {
      pendingRuntimeDependencies.push({
        input,
        key: pendingKey,
        resolve,
        reject,
      });
    });
    pendingRuntimeDependencyByKey.set(pendingKey, pendingRequest);

    if (pendingRuntimeDependencies.length >= LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES) {
      if (runtimeDependencyBatchTimer !== null) {
        clearTimeout(runtimeDependencyBatchTimer);
        runtimeDependencyBatchTimer = null;
      }
      void flushRuntimeDependencyBatch();
    } else {
      scheduleRuntimeDependencyFlush();
    }

    return pendingRequest;
  }

  return {
    allowLocalRuntimeDependency,
    checkDomains,
    connect,
    isAvailable,
    recoverCaptivePortalNavigation,
    requestLocalWhitelistUpdate,
    sendMessage,
  };
}
