import type { Browser, Runtime } from 'webextension-polyfill';

import { getErrorMessage } from './logger.js';
import {
  NATIVE_HOST_PROTOCOL_VERSION,
  NATIVE_TRANSPORT_PROBE_TIMEOUT_MS,
  NATIVE_TRANSPORT_RECONNECT_BASE_DELAY_MS,
  NATIVE_TRANSPORT_RECONNECT_MAX_DELAY_MS,
  NATIVE_TRANSPORT_REQUEST_TIMEOUT_MS,
} from './runtime-dependency-protocol.js';

export interface PersistentNativeTransportLogger {
  error: (message: string, context?: Record<string, unknown>) => void;
  info: (message: string, context?: Record<string, unknown>) => void;
}

export interface PersistentNativeTransportOptions {
  browserApi: Browser;
  hostName: string;
  logger: PersistentNativeTransportLogger;
  /** Capability probe timeout after connectNative (covers a cold host start). */
  probeTimeoutMs?: number;
  /** Default per-request timeout; a timeout tears the port down with backoff. */
  requestTimeoutMs?: number;
  reconnectBaseDelayMs?: number;
  reconnectMaxDelayMs?: number;
  now?: () => number;
}

export type PersistentNativeTransportState =
  | 'idle'
  /** Port opening / capability probe in flight. */
  | 'connecting'
  /** Port open and the host announced capabilities. */
  | 'ready'
  /** Port open but the host is an older agent without capabilities. */
  | 'legacy'
  /** Port dropped or unhealthy; reconnect is throttled by exponential backoff. */
  | 'backoff';

export interface PersistentNativeTransport {
  /** Opens the port when idle (or when the backoff window has elapsed) and probes capabilities. */
  ensureConnected: () => Promise<boolean>;
  /** True while the port/capability probe is in flight (decision not known yet). */
  isConnecting: () => boolean;
  /** Waits for an in-flight connection for at most `timeoutMs`; true only when ready. */
  waitUntilReady: (timeoutMs: number) => Promise<boolean>;
  isReady: () => boolean;
  supports: (capability: string) => boolean;
  getProtocolVersion: () => number;
  getCapabilities: () => ReadonlySet<string>;
  /** Sends an id-correlated message over the port; rejects when the port is unusable. */
  call: (message: Record<string, unknown>, options?: { timeoutMs?: number }) => Promise<unknown>;
  /** Forces a reconnect; used when a caller detects a broken exchange. */
  markUnhealthy: (reason: string) => void;
  shutdown: () => void;
}

interface PendingCall {
  reject: (error: unknown) => void;
  resolve: (response: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}

function resolveResponseId(response: unknown): number | null {
  if (!response || typeof response !== 'object') {
    return null;
  }
  const id = (response as { id?: unknown }).id;
  return typeof id === 'number' && Number.isFinite(id) ? id : null;
}

function extractResponseCapabilities(response: unknown): {
  capabilities: Set<string>;
  protocolVersion: number;
  success: boolean;
} {
  if (!response || typeof response !== 'object') {
    return { capabilities: new Set(), protocolVersion: 0, success: false };
  }
  const candidate = response as {
    success?: unknown;
    protocolVersion?: unknown;
    capabilities?: unknown;
  };
  const protocolVersion =
    typeof candidate.protocolVersion === 'number' && Number.isFinite(candidate.protocolVersion)
      ? candidate.protocolVersion
      : 0;
  const capabilities = new Set<string>();
  if (Array.isArray(candidate.capabilities)) {
    for (const capability of candidate.capabilities) {
      if (typeof capability === 'string' && capability.length > 0) {
        capabilities.add(capability);
      }
    }
  }
  return { capabilities, protocolVersion, success: candidate.success === true };
}

export function createPersistentNativeTransport(
  options: PersistentNativeTransportOptions
): PersistentNativeTransport {
  const browserApi = options.browserApi;
  const logger = options.logger;
  const probeTimeoutMs = options.probeTimeoutMs ?? NATIVE_TRANSPORT_PROBE_TIMEOUT_MS;
  const requestTimeoutMs = options.requestTimeoutMs ?? NATIVE_TRANSPORT_REQUEST_TIMEOUT_MS;
  const reconnectBaseDelayMs =
    options.reconnectBaseDelayMs ?? NATIVE_TRANSPORT_RECONNECT_BASE_DELAY_MS;
  const reconnectMaxDelayMs =
    options.reconnectMaxDelayMs ?? NATIVE_TRANSPORT_RECONNECT_MAX_DELAY_MS;
  const now = options.now ?? ((): number => Date.now());

  let state: PersistentNativeTransportState = 'idle';
  let port: Runtime.Port | null = null;
  let capabilities = new Set<string>();
  let protocolVersion = 0;
  let nextRequestId = 1;
  let connectPromise: Promise<boolean> | null = null;
  let reconnectAttempts = 0;
  let nextReconnectAt = 0;
  let stopped = false;
  const pendingCalls = new Map<number, PendingCall>();

  function rejectAllPendingCalls(reason: string): void {
    for (const [requestId, pending] of pendingCalls) {
      clearTimeout(pending.timer);
      pending.reject(
        new Error(`native transport call ${requestId.toString()} rejected: ${reason}`)
      );
    }
    pendingCalls.clear();
  }

  function scheduleReconnect(): void {
    const delay = Math.min(
      reconnectMaxDelayMs,
      reconnectBaseDelayMs * Math.pow(2, Math.max(0, reconnectAttempts))
    );
    reconnectAttempts += 1;
    nextReconnectAt = now() + delay;
  }

  function markBackoff(reason: string): void {
    const activePort = port;
    port = null;
    if (activePort) {
      try {
        activePort.disconnect();
      } catch {
        // already disconnected
      }
    }
    if (state !== 'backoff') {
      state = 'backoff';
      scheduleReconnect();
    }
    rejectAllPendingCalls(reason);
  }

  function handleDisconnect(target: Runtime.Port): void {
    if (port !== target) {
      // Stale listener from a port we already replaced/tore down.
      return;
    }
    port = null;
    capabilities = new Set();
    protocolVersion = 0;
    state = 'backoff';
    scheduleReconnect();
    rejectAllPendingCalls('native port disconnected');
    logger.info('[Monitor] Native host port disconnected');
  }

  function handleMessage(target: Runtime.Port, message: unknown): void {
    if (port !== target) {
      return;
    }

    const responseId = resolveResponseId(message);
    if (responseId !== null) {
      const pending = pendingCalls.get(responseId);
      if (pending) {
        pendingCalls.delete(responseId);
        clearTimeout(pending.timer);
        pending.resolve(message);
        return;
      }
      logger.info('[Monitor] Native port response without a matching call', { responseId });
      return;
    }

    // A legacy host does not echo ids; when exactly one call is outstanding the
    // response can only belong to it (the capability probe is the only such call).
    if (pendingCalls.size === 1) {
      const onlyCall = pendingCalls.entries().next().value;
      if (onlyCall) {
        const [requestId, pending] = onlyCall;
        pendingCalls.delete(requestId);
        clearTimeout(pending.timer);
        pending.resolve(message);
        return;
      }
    }

    logger.info('[Monitor] Native port response without an id while multiple calls are in flight');
  }

  function attachPort(newPort: Runtime.Port): void {
    port = newPort;
    newPort.onDisconnect.addListener(() => {
      handleDisconnect(newPort);
    });
    newPort.onMessage.addListener((message: unknown) => {
      handleMessage(newPort, message);
    });
  }

  function callOnPort(message: Record<string, unknown>, timeoutMs: number): Promise<unknown> {
    if (!port) {
      return Promise.reject(new Error('native transport port is not open'));
    }
    const target = port;
    const requestId = nextRequestId;
    nextRequestId += 1;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pendingCalls.delete(requestId);
        reject(new Error(`native transport call ${requestId.toString()} timed out`));
        markBackoff(`call ${requestId.toString()} timed out`);
      }, timeoutMs);
      pendingCalls.set(requestId, { reject, resolve, timer });
      try {
        target.postMessage({ ...message, id: requestId });
      } catch (error) {
        clearTimeout(timer);
        pendingCalls.delete(requestId);
        reject(error instanceof Error ? error : new Error(String(error)));
        markBackoff('postMessage failed');
      }
    });
  }

  function connectionUnusable(): boolean {
    if (state === 'backoff' && now() < nextReconnectAt) {
      return true;
    }
    return false;
  }

  function connectOnce(): Promise<boolean> {
    if (connectPromise) {
      return connectPromise;
    }
    if (stopped) {
      return Promise.resolve(false);
    }
    state = 'connecting';
    capabilities = new Set();
    protocolVersion = 0;
    connectPromise = (async (): Promise<boolean> => {
      try {
        const newPort = browserApi.runtime.connectNative(options.hostName);
        attachPort(newPort);
        const probeResponse = await callOnPort({ action: 'ping' }, probeTimeoutMs);
        const parsed = extractResponseCapabilities(probeResponse);
        if (!parsed.success) {
          logger.error('[Monitor] Native host capability probe failed', {
            error: getErrorMessage((probeResponse as { error?: unknown }).error),
          });
          markBackoff('capability probe failed');
          return false;
        }
        capabilities = parsed.capabilities;
        protocolVersion = parsed.protocolVersion;
        reconnectAttempts = 0;
        nextReconnectAt = 0;
        state = capabilities.size > 0 ? 'ready' : 'legacy';
        logger.info('[Monitor] Native host capabilities probed', {
          protocolVersion,
          capabilities: [...capabilities],
          persistent: state === 'ready',
        });
        return true;
      } catch (error) {
        logger.error('[Monitor] Error connecting persistent native transport', {
          error: getErrorMessage(error),
        });
        markBackoff('connect failed');
        return false;
      } finally {
        connectPromise = null;
      }
    })();
    return connectPromise;
  }

  async function ensureConnected(): Promise<boolean> {
    if (stopped) {
      return false;
    }
    if (state === 'ready' || state === 'legacy') {
      return true;
    }
    if (state === 'connecting' && connectPromise) {
      return connectPromise;
    }
    if (connectionUnusable()) {
      return false;
    }
    return connectOnce();
  }

  function waitForSettledConnection(timeoutMs: number): Promise<boolean> {
    const active = connectPromise;
    if (!active) {
      return Promise.resolve(state === 'ready');
    }
    return new Promise((resolve) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(false);
      }, timeoutMs);
      void active.then(
        (connected) => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          resolve(connected && state === 'ready');
        },
        () => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          resolve(false);
        }
      );
    });
  }

  async function waitUntilReady(timeoutMs: number): Promise<boolean> {
    if (stopped) {
      return false;
    }
    if (state === 'ready') {
      return true;
    }
    if (state === 'legacy') {
      return false;
    }
    if (state === 'connecting') {
      return waitForSettledConnection(timeoutMs);
    }
    if (state === 'backoff' && connectionUnusable()) {
      return false;
    }
    const started = connectOnce();
    void started;
    return waitForSettledConnection(timeoutMs);
  }

  function call(
    message: Record<string, unknown>,
    callOptions?: { timeoutMs?: number }
  ): Promise<unknown> {
    if (stopped) {
      return Promise.reject(new Error('native transport is shut down'));
    }
    if (!port || (state !== 'ready' && state !== 'connecting')) {
      return Promise.reject(new Error('native transport is not ready'));
    }
    return callOnPort(message, callOptions?.timeoutMs ?? requestTimeoutMs);
  }

  return {
    ensureConnected,
    waitUntilReady,
    isConnecting: (): boolean => state === 'connecting',
    isReady: (): boolean => state === 'ready',
    supports: (capability: string): boolean => state === 'ready' && capabilities.has(capability),
    getProtocolVersion: (): number => protocolVersion,
    getCapabilities: (): ReadonlySet<string> => capabilities,
    call,
    markUnhealthy: (reason: string): void => {
      markBackoff(reason);
    },
    shutdown: (): void => {
      stopped = true;
      rejectAllPendingCalls('transport shut down');
      const activePort = port;
      port = null;
      if (activePort) {
        try {
          activePort.disconnect();
        } catch {
          // already disconnected
        }
      }
      state = 'idle';
    },
  };
}

export function isProtocolVersionSupported(protocolVersion: number): boolean {
  return protocolVersion >= NATIVE_HOST_PROTOCOL_VERSION;
}
