import type { Browser, Runtime } from 'webextension-polyfill';

import { t } from './i18n.js';
import { getErrorMessage, logger as defaultLogger } from './logger.js';
import type { NativeResponse } from './native-response.types.js';
import {
  LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS,
  LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_STALE_TTL_MS,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS,
  LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS,
  RUNTIME_DEPENDENCY_ACTIONS,
  createRuntimeDependencyCacheKey,
  createRuntimeDependencyPendingKey,
  isReadyRuntimeDependencyCheckResponse,
  resolveRuntimeDependencyReadiness,
  type LocalRuntimeDependencyInput,
} from './runtime-dependency-protocol.js';

export type { NativeResponse } from './native-response.types.js';

declare const browser: Browser;

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
  policy_decision?: 'allowed' | 'blocked' | 'unknown';
  policy_reason?: string;
  policy_version?: string;
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
  policyDecision?: 'allowed' | 'blocked' | 'unknown';
  policyReason?: string;
  policyVersion?: string;
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
  portalRecoveryHosts?: string[];
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

interface LocalRuntimeDependencyCheckResponse extends NativeResponse {
  action?: typeof RUNTIME_DEPENDENCY_ACTIONS.checkLocal;
  ready?: boolean;
  runtimeDependencyState?: string;
  /** Advisory overlay expiry supplied by the agent; not consumed for release decisions yet. */
  expiresAt?: number | string;
}

interface RuntimeDependencyCacheEntry {
  /** After this instant the entry must be confirmed before being treated as ready. */
  freshUntil: number;
  /** After this instant the entry is evicted and the normal allow flow runs. */
  expiresAt: number;
}

interface PendingLocalRuntimeDependency {
  input: LocalRuntimeDependencyInput;
  key: string;
  resolve: (response: NativeResponse) => void;
  reject: (error: unknown) => void;
  settled?: boolean;
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
  warmUp: () => Promise<void>;
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
  const runtimeDependencyCache = new Map<string, RuntimeDependencyCacheEntry>();
  const queuedRuntimeDependencyDedupeCache = new Map<
    string,
    { expiresAt: number; response: NativeResponse }
  >();
  const pendingRuntimeDependencies: PendingLocalRuntimeDependency[] = [];
  const pendingRuntimeDependencyByKey = new Map<string, Promise<NativeResponse>>();
  const pendingRuntimeDependencyConfirmationByKey = new Map<
    string,
    Promise<NativeResponse | null>
  >();
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
          // Do NOT auto-reconnect here: a host that is absent disconnects immediately on every
          // connectNative, which would turn this into a 1/sec reconnect-and-log storm. sendMessage
          // reconnects lazily when a check is actually needed, and warmUp() re-warms on demand.
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
        if (result.policy_decision !== undefined) {
          mapped.policyDecision = result.policy_decision;
        }
        if (result.policy_reason !== undefined) {
          mapped.policyReason = result.policy_reason;
        }
        if (result.policy_version !== undefined) {
          mapped.policyVersion = result.policy_version;
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
      ...(input.portalRecoveryHosts && input.portalRecoveryHosts.length > 0
        ? { portalRecoveryHosts: input.portalRecoveryHosts }
        : {}),
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

  function createReadyRuntimeDependencyResponse(
    input: LocalRuntimeDependencyInput,
    extra: Record<string, unknown> = {}
  ): NativeResponse {
    return {
      success: true,
      action: RUNTIME_DEPENDENCY_ACTIONS.allowLocal,
      anchorHost: input.anchorHost,
      dependencyHost: input.dependencyHost,
      runtimeDependencyState: 'ready',
      ...extra,
    };
  }

  function getFreshCachedRuntimeDependency(
    input: LocalRuntimeDependencyInput
  ): NativeResponse | null {
    const now = Date.now();
    pruneExpiredRuntimeDependencyEntries(runtimeDependencyCache, now);
    const entry = runtimeDependencyCache.get(createRuntimeDependencyCacheKey(input));
    if (entry === undefined || entry.freshUntil <= now) {
      return null;
    }

    return createReadyRuntimeDependencyResponse(input, { cached: true });
  }

  function hasStaleCachedRuntimeDependency(input: LocalRuntimeDependencyInput): boolean {
    const now = Date.now();
    pruneExpiredRuntimeDependencyEntries(runtimeDependencyCache, now);
    const entry = runtimeDependencyCache.get(createRuntimeDependencyCacheKey(input));
    return entry !== undefined && entry.freshUntil <= now;
  }

  async function confirmCachedRuntimeDependency(
    input: LocalRuntimeDependencyInput
  ): Promise<NativeResponse | null> {
    const cacheKey = createRuntimeDependencyCacheKey(input);
    const existingConfirmation = pendingRuntimeDependencyConfirmationByKey.get(cacheKey);
    if (existingConfirmation) {
      return existingConfirmation;
    }

    const confirmation = (async (): Promise<NativeResponse | null> => {
      try {
        const response = (await sendMessage({
          action: RUNTIME_DEPENDENCY_ACTIONS.checkLocal,
          anchorHost: input.anchorHost,
          dependencyHost: input.dependencyHost,
        })) as LocalRuntimeDependencyCheckResponse;
        if (isReadyRuntimeDependencyCheckResponse(response)) {
          cacheReadyRuntimeDependency(input);
          return createReadyRuntimeDependencyResponse(input, { confirmed: true });
        }
      } catch (error) {
        logger.error('[Monitor] Error confirmando dependencia runtime local', {
          error: getErrorMessage(error),
        });
      }

      // The agent could not confirm readiness (not applied yet, unsupported
      // action on an older host, or messaging failure): drop the entry and
      // re-run the normal allow flow instead of assuming the domain is ready.
      runtimeDependencyCache.delete(cacheKey);
      return null;
    })().finally(() => {
      pendingRuntimeDependencyConfirmationByKey.delete(cacheKey);
    });

    pendingRuntimeDependencyConfirmationByKey.set(cacheKey, confirmation);
    return confirmation;
  }

  function cacheReadyRuntimeDependency(input: LocalRuntimeDependencyInput): void {
    const now = Date.now();
    pruneExpiredRuntimeDependencyEntries(runtimeDependencyCache, now);
    runtimeDependencyCache.set(createRuntimeDependencyCacheKey(input), {
      freshUntil: now + LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS,
      expiresAt: now + LOCAL_RUNTIME_DEPENDENCY_CACHE_STALE_TTL_MS,
    });
    trimOldestRuntimeDependencyEntries(runtimeDependencyCache);
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
    switch (resolveRuntimeDependencyReadiness(response)) {
      case 'ready':
        cacheReadyRuntimeDependency(input);
        return;
      case 'pending': {
        const now = Date.now();
        pruneExpiredRuntimeDependencyEntries(queuedRuntimeDependencyDedupeCache, now);
        queuedRuntimeDependencyDedupeCache.set(createRuntimeDependencyPendingKey(input), {
          expiresAt: now + LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS,
          response,
        });
        trimOldestRuntimeDependencyEntries(queuedRuntimeDependencyDedupeCache);
        return;
      }
      default:
        return;
    }
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

  function settleRuntimeDependencyRequest(
    request: PendingLocalRuntimeDependency,
    response: NativeResponse
  ): void {
    if (request.settled) {
      return;
    }
    request.settled = true;
    pendingRuntimeDependencyByKey.delete(request.key);
    request.resolve(response);
  }

  function rejectRuntimeDependencyRequest(
    request: PendingLocalRuntimeDependency,
    error: unknown
  ): void {
    if (request.settled) {
      return;
    }
    request.settled = true;
    pendingRuntimeDependencyByKey.delete(request.key);
    request.reject(error);
  }

  async function flushRuntimeDependencyBatch(): Promise<void> {
    const batch = pendingRuntimeDependencies.splice(0, LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES);
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
              settleRuntimeDependencyRequest(
                request,
                await sendSingleLocalRuntimeDependency(request.input)
              );
            } catch (error) {
              rejectRuntimeDependencyRequest(request, error);
            }
          })
        );
        return;
      }

      batch.forEach((request, index) => {
        const response = findBatchResult(batchResponse, request.input, index);
        cacheRuntimeDependencySuccess(request.input, response);
        settleRuntimeDependencyRequest(request, response);
      });
    } catch (error) {
      batch.forEach((request) => {
        rejectRuntimeDependencyRequest(request, error);
      });
    }
  }

  async function allowLocalRuntimeDependency(
    input: LocalRuntimeDependencyInput
  ): Promise<NativeResponse> {
    const cachedResponse = getFreshCachedRuntimeDependency(input);
    if (cachedResponse) {
      return cachedResponse;
    }

    if (hasStaleCachedRuntimeDependency(input)) {
      const confirmedResponse = await confirmCachedRuntimeDependency(input);
      if (confirmedResponse) {
        return confirmedResponse;
      }
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

  async function warmUp(): Promise<void> {
    if (nativePort !== null) {
      return;
    }
    try {
      await connect();
    } catch {
      // best-effort pre-warm; errors are intentionally swallowed
    }
  }

  return {
    allowLocalRuntimeDependency,
    checkDomains,
    connect,
    isAvailable,
    recoverCaptivePortalNavigation,
    requestLocalWhitelistUpdate,
    sendMessage,
    warmUp,
  };
}
