import type { NativeResponse } from './native-response.types.js';

export interface LocalRuntimeDependencyInput {
  anchorHost: string;
  dependencyHost: string;
  requestType: string;
}

export const RUNTIME_DEPENDENCY_ACTIONS = {
  allowLocal: 'allow-local-runtime-dependency',
  allowLocalBatch: 'allow-local-runtime-dependency-batch',
  checkLocal: 'check-local-runtime-dependency',
  reportExtensionDiagnostics: 'report-extension-diagnostics',
} as const;

/** Phase 2E E1: diagnostics batching limits (also enforced by the hosts). */
export const EXTENSION_DIAGNOSTICS_INTERVAL_MS = 2_000;
export const EXTENSION_DIAGNOSTICS_BATCH_MAX = 50;
export const EXTENSION_DIAGNOSTICS_HOST_TIMEOUT_MS = 5_000;

/**
 * Coalescing window for new runtime dependencies. Short enough that a single
 * dependency request does not burn a meaningful slice of its soft wait, long
 * enough that a first-party fan-out still produces one native message per
 * burst instead of one per dependency.
 */
export const LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS = 25;
export const LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES = 20;
/**
 * Fresh window for a dependency whose readiness was proven by the native host.
 * Requests inside this window are released without native IPC.
 */
export const LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS = 60 * 1000;
/**
 * Maximum age of a ready cache entry before eviction. Between
 * `..._CACHE_TTL_MS` and this bound the entry is stale-but-confirmable: the
 * extension must re-check readiness with `check-local-runtime-dependency`
 * before treating it as ready again.
 */
export const LOCAL_RUNTIME_DEPENDENCY_CACHE_STALE_TTL_MS = 30 * 60 * 1000;
export const LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS = 5 * 1000;
export const LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES = 100;
export const LOCAL_RUNTIME_DEPENDENCY_QUEUE_VERSION = 1;
export const LOCAL_RUNTIME_DEPENDENCY_OVERLAY_VERSION = 1;
export const LOCAL_RUNTIME_DEPENDENCY_QUEUE_SOURCE = 'firefox-webrequest-local';

/**
 * Persistent native transport (Phase 2C).
 *
 * Hosts that announce this protocol version answer `ping` with a capability
 * list and keep serving messages over a long-lived `connectNative` port, which
 * removes the per-message native host cold start (1.2-2.5 s per message in the
 * Phase 2B Windows lab, up to 7 s for the first one after login).
 */
export const NATIVE_HOST_PROTOCOL_VERSION = 2;

export const NATIVE_HOST_CAPABILITIES = {
  enqueue: 'runtime-dependency-enqueue',
  checkBatch: 'runtime-dependency-check-batch',
  idEcho: 'message-id-echo',
  autoReload: 'runtime-dependency-auto-reload',
  extensionDiagnostics: 'extension-diagnostics',
} as const;

export type NativeHostCapability =
  (typeof NATIVE_HOST_CAPABILITIES)[keyof typeof NATIVE_HOST_CAPABILITIES];

/** Timeout for the capability probe after `connectNative` (covers a cold host start). */
export const NATIVE_TRANSPORT_PROBE_TIMEOUT_MS = 10_000;
/**
 * Default per-request timeout over the port for calls that do not pass an
 * action-specific timeout. Phase 2D: a request timeout no longer tears the
 * port down; it only rejects the call and lets the liveness probe decide.
 */
export const NATIVE_TRANSPORT_REQUEST_TIMEOUT_MS = 10_000;
/**
 * Per-action port timeouts (Phase 2D D1). Writing the queue and nudging the
 * resident worker is slower than a read, and the native host can brief
 * non-responses while it is busy; the timeout must not be so tight that a slow
 * host is mistaken for a dead one.
 */
export const NATIVE_TRANSPORT_ENQUEUE_TIMEOUT_MS = 10_000;
export const NATIVE_TRANSPORT_CHECK_TIMEOUT_MS = 5_000;
export const NATIVE_TRANSPORT_CHEAP_READ_TIMEOUT_MS = 5_000;
/**
 * Liveness rule (Phase 2D D1): a timed-out call only marks the port dead when
 * the host has been completely silent for this long and a probe ping also
 * times out.
 */
export const NATIVE_TRANSPORT_LIVENESS_STALE_MS = 15_000;
export const NATIVE_TRANSPORT_LIVENESS_PING_TIMEOUT_MS = 5_000;
/** Reconnect backoff for a dropped/unhealthy port: base delay and ceiling. */
export const NATIVE_TRANSPORT_RECONNECT_BASE_DELAY_MS = 1_000;
export const NATIVE_TRANSPORT_RECONNECT_MAX_DELAY_MS = 30_000;
/**
 * How long a dependency request waits for the persistent port before taking
 * the legacy one-shot path. The first dependency of a page may wait through a
 * cold port connect (the browser can take several seconds to spawn the host
 * under a cold Firefox load, so the first window covers the full capability
 * probe); later ones get a shorter window because a healthy port is either
 * already open or known to be unavailable.
 */
export const LOCAL_RUNTIME_DEPENDENCY_PORT_WAIT_FIRST_MS = 10_000;
export const LOCAL_RUNTIME_DEPENDENCY_PORT_WAIT_MS = 3_000;
/** Poll cadence for pending dependencies over the persistent port. */
export const LOCAL_RUNTIME_DEPENDENCY_PROBE_INTERVAL_MS = 150;
/** Pending entries older than this are dropped instead of polled forever. */
export const LOCAL_RUNTIME_DEPENDENCY_PROBE_MAX_ENTRY_AGE_MS = 120_000;

/**
 * Soft-wait budgets while the persistent transport is active. They only bound
 * the cancel decision (and the legacy release); a proven-ready entry is
 * released much earlier by the prober.
 */
export const LOCAL_RUNTIME_DEPENDENCY_PERSISTENT_SOFT_TIMEOUT_BY_TYPE_MS = new Map<string, number>([
  ['fetch', 8_000],
  ['xmlhttprequest', 8_000],
  ['image', 8_000],
  ['imageset', 8_000],
  ['script', 10_000],
  ['stylesheet', 10_000],
  ['font', 10_000],
]);
export const DEFAULT_LOCAL_RUNTIME_DEPENDENCY_PERSISTENT_SOFT_TIMEOUT_MS = 8_000;

/** Once an auto-reload fires, the tab is not auto-reloaded again for this long. */
export const RUNTIME_DEPENDENCY_AUTO_RELOAD_TAB_COOLDOWN_MS = 30_000;
/** Wave coalescing before the single auto-reload is issued. */
export const RUNTIME_DEPENDENCY_AUTO_RELOAD_COALESCE_MS = 400;
/** A dependency cancelled in frame 0 of a navigation may only be repaired by an
 *  auto-reload while the navigation is at most this old. */
export const RUNTIME_DEPENDENCY_AUTO_RELOAD_MAX_NAVIGATION_AGE_MS = 30_000;

/**
 * Readiness of a local runtime dependency as observed by the extension.
 *
 * - `ready`: the native host proved the dependency is operative in the local
 *   DNS path; the request may be released.
 * - `pending`: accepted (or legacy-acknowledged) but not yet applied; keep
 *   waiting until the soft timeout.
 * - `terminal`: the dependency will not be applied; release immediately so the
 *   request fails fast instead of burning the soft-wait budget.
 */
export type RuntimeDependencyReadiness = 'ready' | 'pending' | 'terminal';

export function createRuntimeDependencyCacheKey(
  input: Pick<LocalRuntimeDependencyInput, 'anchorHost' | 'dependencyHost'>
): string {
  return `${input.anchorHost.toLowerCase()}|${input.dependencyHost.toLowerCase()}`;
}

export function createRuntimeDependencyPendingKey(input: LocalRuntimeDependencyInput): string {
  return `${createRuntimeDependencyCacheKey(input)}|${input.requestType.toLowerCase()}`;
}

export function isQueuedRuntimeDependencyResponse(response: NativeResponse): boolean {
  return response.runtimeDependencyState === 'queued' || response.queued === true;
}

export function resolveRuntimeDependencyReadiness(response: unknown): RuntimeDependencyReadiness {
  if (!response || typeof response !== 'object') {
    return 'terminal';
  }

  const candidate = response as {
    queued?: unknown;
    runtimeDependencyState?: unknown;
    success?: unknown;
  };

  if (candidate.runtimeDependencyState === 'ready') {
    return 'ready';
  }
  if (
    candidate.runtimeDependencyState === 'pending' ||
    candidate.runtimeDependencyState === 'queued'
  ) {
    return 'pending';
  }
  if (
    candidate.runtimeDependencyState === 'denied' ||
    candidate.runtimeDependencyState === 'error'
  ) {
    return 'terminal';
  }
  if (candidate.queued === true) {
    return 'pending';
  }
  if (candidate.success === false) {
    return 'terminal';
  }

  // A success without an explicit readiness state is a legacy acknowledgement:
  // accepted for processing, but it does not prove the DNS exception is
  // operative yet, so it must not release the request early.
  return 'pending';
}

export function isReadyRuntimeDependencyResponse(response: unknown): boolean {
  return resolveRuntimeDependencyReadiness(response) === 'ready';
}

export function isPendingRuntimeDependencyResponse(response: unknown): boolean {
  return resolveRuntimeDependencyReadiness(response) === 'pending';
}

export function isReadyRuntimeDependencyCheckResponse(response: unknown): boolean {
  if (!response || typeof response !== 'object') {
    return false;
  }

  const candidate = response as { ready?: unknown; runtimeDependencyState?: unknown };
  return candidate.ready === true || candidate.runtimeDependencyState === 'ready';
}
