import type { Browser } from 'webextension-polyfill';

import { t } from './i18n.js';
import { getErrorMessage, logger as defaultLogger } from './logger.js';
import type { NativeResponse } from './native-response.types.js';
import {
  createPersistentNativeTransport,
  isProtocolVersionSupported,
  type PersistentNativeTransport,
  type PersistentNativeTransportOptions,
} from './persistent-native-transport.js';
import {
  createRuntimeDependencyProber,
  type RuntimeDependencyProber,
} from './runtime-dependency-prober.js';
import {
  LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS,
  LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_STALE_TTL_MS,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS,
  LOCAL_RUNTIME_DEPENDENCY_PORT_WAIT_FIRST_MS,
  LOCAL_RUNTIME_DEPENDENCY_PORT_WAIT_MS,
  LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS,
  NATIVE_HOST_CAPABILITIES,
  RUNTIME_DEPENDENCY_ACTIONS,
  createRuntimeDependencyCacheKey,
  createRuntimeDependencyPendingKey,
  isReadyRuntimeDependencyCheckResponse,
  isReadyRuntimeDependencyResponse,
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
  /** True when the host announced and the port serves the enqueue protocol. */
  isPersistentTransportReady: () => boolean;
  /** True when a cancelled pending dependency may be repaired by one auto-reload. */
  isAutoReloadCapable: () => boolean;
  /**
   * True when the port is ready or a connect/probe is still in flight, i.e. the
   * persistent budget family should apply (the decision is not known yet).
   */
  isPersistentTransportPending: () => boolean;
  /** Subscribes to pending dependencies becoming ready after a cancellation. */
  onRuntimeDependencyApplied: (
    listener: (input: LocalRuntimeDependencyInput) => void
  ) => () => void;
  recoverCaptivePortalNavigation: (
    input: CaptivePortalRecoveryInput
  ) => Promise<CaptivePortalRecoveryResponse>;
  requestLocalWhitelistUpdate: (domains?: string[]) => Promise<boolean>;
  /** Cheap periodic reads (policy version, blocked subdomains, allowed paths). */
  sendCheapRead: (message: unknown) => Promise<unknown>;
  sendMessage: (message: unknown) => Promise<unknown>;
  warmUp: () => Promise<void>;
}

export function createNativeMessagingClient(options: {
  browserApi?: Browser;
  hostName: string;
  logger?: Pick<typeof defaultLogger, 'error' | 'info'>;
  persistentTransport?: PersistentNativeTransport;
  persistentTransportOptions?: Partial<
    Omit<PersistentNativeTransportOptions, 'browserApi' | 'hostName' | 'logger'>
  >;
  runtimeDependencyCacheMaxEntries?: number;
  runtimeDependencyProber?: RuntimeDependencyProber;
}): NativeMessagingClient {
  const browserApi = options.browserApi ?? browser;
  const logger = options.logger ?? defaultLogger;
  const runtimeDependencyCacheMaxEntries =
    options.runtimeDependencyCacheMaxEntries ?? LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES;
  const transport =
    options.persistentTransport ??
    createPersistentNativeTransport({
      browserApi,
      hostName: options.hostName,
      logger,
      ...options.persistentTransportOptions,
    });
  let persistentPortWaitUsed = false;
  const runtimeDependencyAppliedListeners = new Set<(input: LocalRuntimeDependencyInput) => void>();
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
  const runtimeDependencyProber =
    options.runtimeDependencyProber ??
    createRuntimeDependencyProber({
      checkBatch: (inputs) => checkRuntimeDependencyBatch(inputs),
    });

  function isPersistentTransportReady(): boolean {
    return (
      transport.isReady() &&
      transport.supports(NATIVE_HOST_CAPABILITIES.enqueue) &&
      transport.supports(NATIVE_HOST_CAPABILITIES.idEcho)
    );
  }

  function isAutoReloadCapable(): boolean {
    return isPersistentTransportReady() && transport.supports(NATIVE_HOST_CAPABILITIES.autoReload);
  }

  function isPersistentTransportPending(): boolean {
    return transport.isReady() || transport.isConnecting();
  }

  function supportsCheapReads(): boolean {
    return transport.isReady() && isProtocolVersionSupported(transport.getProtocolVersion());
  }

  async function sendCheapRead(message: unknown): Promise<unknown> {
    if (!supportsCheapReads()) {
      return await sendMessage(message);
    }
    try {
      return await transport.call(message as Record<string, unknown>);
    } catch (error) {
      logger.info('[Monitor] Persistent native read failed; using one-shot host', {
        error: getErrorMessage(error),
      });
      return await sendMessage(message);
    }
  }

  function onRuntimeDependencyApplied(
    listener: (input: LocalRuntimeDependencyInput) => void
  ): () => void {
    runtimeDependencyAppliedListeners.add(listener);
    return () => {
      runtimeDependencyAppliedListeners.delete(listener);
    };
  }

  function notifyRuntimeDependencyApplied(input: LocalRuntimeDependencyInput): void {
    for (const listener of [...runtimeDependencyAppliedListeners]) {
      try {
        listener(input);
      } catch (error) {
        logger.error('[Monitor] Error notificando dependencia aplicada', {
          error: getErrorMessage(error),
        });
      }
    }
  }

  function isCheckBatchUnsupported(response: unknown): boolean {
    if (!response || typeof response !== 'object') {
      return true;
    }
    const candidate = response as { success?: unknown; error?: unknown };
    if (candidate.success === true) {
      return false;
    }
    const error = typeof candidate.error === 'string' ? candidate.error.toLowerCase() : '';
    return error.includes('unknown action') || error.includes('unsupported');
  }

  async function checkRuntimeDependencyBatch(
    inputs: LocalRuntimeDependencyInput[]
  ): Promise<{ success: boolean; results?: NativeResponse[]; error?: string }> {
    if (transport.isReady() && transport.supports(NATIVE_HOST_CAPABILITIES.checkBatch)) {
      const response = (await transport.call({
        action: RUNTIME_DEPENDENCY_ACTIONS.checkLocal,
        entries: inputs.map((input) => ({
          anchorHost: input.anchorHost,
          dependencyHost: input.dependencyHost,
        })),
      })) as { success?: unknown; results?: unknown };
      if (!isCheckBatchUnsupported(response) && Array.isArray(response.results)) {
        return { success: true, results: response.results as NativeResponse[] };
      }
    }

    const results: NativeResponse[] = [];
    for (const input of inputs) {
      try {
        const response = (await sendMessage({
          action: RUNTIME_DEPENDENCY_ACTIONS.checkLocal,
          anchorHost: input.anchorHost,
          dependencyHost: input.dependencyHost,
        })) as NativeResponse;
        results.push(response);
      } catch (error) {
        results.push({
          success: false,
          error: getErrorMessage(error),
          runtimeDependencyState: 'error',
        });
      }
    }
    return { success: results.length > 0, results };
  }

  async function checkRuntimeDependency(
    input: LocalRuntimeDependencyInput
  ): Promise<NativeResponse> {
    const batch = await checkRuntimeDependencyBatch([input]);
    const results = batch.results ?? [];
    const normalized = input.dependencyHost.toLowerCase();
    const match = results.find((candidate) => {
      const host = (candidate as { dependencyHost?: unknown }).dependencyHost;
      return typeof host === 'string' && host.toLowerCase() === normalized;
    });
    return match ?? results[0] ?? { success: false, runtimeDependencyState: 'error' };
  }

  function resolvePersistentPortWaitMs(): number {
    if (!persistentPortWaitUsed) {
      persistentPortWaitUsed = true;
      return LOCAL_RUNTIME_DEPENDENCY_PORT_WAIT_FIRST_MS;
    }
    return LOCAL_RUNTIME_DEPENDENCY_PORT_WAIT_MS;
  }

  async function ensurePersistentTransportForBatch(): Promise<boolean> {
    if (isPersistentTransportReady()) {
      return true;
    }
    if (!transport.isReady()) {
      await transport.waitUntilReady(resolvePersistentPortWaitMs());
    }
    return isPersistentTransportReady();
  }

  async function connect(): Promise<boolean> {
    return await transport.ensureConnected();
  }

  async function sendMessage(message: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const attempt = async (): Promise<void> => {
        try {
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
        const response = (await checkRuntimeDependency(
          input
        )) as LocalRuntimeDependencyCheckResponse;
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

    if (await ensurePersistentTransportForBatch()) {
      try {
        const persistentBatchResponse = (await transport.call({
          action: RUNTIME_DEPENDENCY_ACTIONS.allowLocalBatch,
          mode: 'enqueue',
          entries: batch.map((request) => request.input),
        })) as LocalRuntimeDependencyBatchResponse;

        if (!isBatchUnsupported(persistentBatchResponse)) {
          batch.forEach((request, index) => {
            const response = findBatchResult(persistentBatchResponse, request.input, index);
            if (resolveRuntimeDependencyReadiness(response) !== 'pending') {
              cacheRuntimeDependencySuccess(request.input, response);
              settleRuntimeDependencyRequest(request, response);
              return;
            }

            // The host accepted the entry but has not proven it yet. Keep the
            // request promise open so the prober can release it on `ready`
            // (or the caller's budget can cancel it), and let the auto-reload
            // module observe the eventual application.
            cacheRuntimeDependencySuccess(request.input, response);
            runtimeDependencyProber.register(request.input, (finalResponse) => {
              if (isReadyRuntimeDependencyResponse(finalResponse)) {
                cacheReadyRuntimeDependency(request.input);
              }
              settleRuntimeDependencyRequest(request, finalResponse);
              if (isReadyRuntimeDependencyResponse(finalResponse)) {
                notifyRuntimeDependencyApplied(request.input);
              }
            });
          });
          return;
        }
      } catch (error) {
        logger.info('[Monitor] Persistent dependency enqueue failed; using the one-shot path', {
          error: getErrorMessage(error),
        });
        transport.markUnhealthy('dependency enqueue failed');
      }
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

    const pendingKey = createRuntimeDependencyPendingKey(input);
    // An in-flight operation owns the settled state of the entry: a queued
    // dependency registered with the prober must share the same promise so it
    // is released by `ready` instead of its soft budget.
    const existingRequest = pendingRuntimeDependencyByKey.get(pendingKey);
    if (existingRequest) {
      return existingRequest;
    }

    const queuedDedupeResponse = getQueuedRuntimeDependencyDedupe(input);
    if (queuedDedupeResponse) {
      return queuedDedupeResponse;
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

  function warmUp(): Promise<void> {
    // Fire-and-forget pre-warm: opening the port (and probing capabilities) here
    // keeps the first blocked dependency from paying the native host cold start.
    try {
      void transport.ensureConnected();
    } catch {
      // best-effort pre-warm; errors are intentionally swallowed
    }
    return Promise.resolve();
  }

  return {
    allowLocalRuntimeDependency,
    checkDomains,
    connect,
    isAvailable,
    isAutoReloadCapable,
    isPersistentTransportPending,
    isPersistentTransportReady,
    onRuntimeDependencyApplied,
    recoverCaptivePortalNavigation,
    requestLocalWhitelistUpdate,
    sendCheapRead,
    sendMessage,
    warmUp,
  };
}
