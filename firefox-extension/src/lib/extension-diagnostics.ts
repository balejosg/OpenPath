/**
 * Phase 2E E1: always-on, bounded, sanitized extension diagnostics buffer.
 *
 * The buffer records the extension's own decision points (background start,
 * transport transitions, navigation identity, held requests and their outcome,
 * and every auto-reload decision with its reason). It never records URLs, page
 * content, query strings or tokens: only hosts, ids, types, reasons and
 * timings. The reporter (`extension-diagnostics-reporter.ts`) drains it in
 * batches over the persistent native port and both native hosts write one
 * `stage=extension-diagnostic` JSON line per event to the user's
 * native-host.log.
 *
 * The module is intentionally dependency-free so it can be imported from the
 * transport, the auto-reload controller and the background listeners without
 * cycles.
 */

export type ExtensionDiagnosticKind =
  | 'background-start'
  | 'transport'
  | 'navigation'
  | 'hold'
  | 'hold-outcome'
  | 'reload-decision';

export interface ExtensionDiagnosticEventInput {
  /** Epoch milliseconds at recording time (defaults to Date.now()). */
  ts?: number;
  kind: ExtensionDiagnosticKind;
  /** Hosts only (never full URLs). */
  anchorHost?: string;
  dependencyHost?: string;
  host?: string;
  /** Request/navigation shape. */
  frameId?: number;
  type?: string;
  tabId?: number;
  /** Navigation identity. */
  navigationId?: number;
  methodKnown?: boolean;
  source?: string;
  committed?: boolean;
  /** Transport state at the decision point. */
  transport?: string;
  /** Transport transition endpoints (kind=transport). */
  from?: string;
  to?: string;
  /** Outcome + timing for held requests. */
  outcome?: string;
  ms?: number;
  /** Reload decision reason (every path, including the ones that used to be silent). */
  reason?: string;
}

export interface ExtensionDiagnosticEvent extends ExtensionDiagnosticEventInput {
  /** Epoch milliseconds at recording time. */
  ts: number;
}

export interface ExtensionDiagnosticsConfig {
  enabled: boolean;
  maxEvents: number;
}

export interface ExtensionDiagnosticsSnapshot {
  enabled: boolean;
  recorded: number;
  dropped: number;
  pending: number;
}

const DEFAULT_MAX_EVENTS = 400;

let config: ExtensionDiagnosticsConfig = { enabled: true, maxEvents: DEFAULT_MAX_EVENTS };
let events: ExtensionDiagnosticEvent[] = [];
let recorded = 0;
let dropped = 0;
let listeners: (() => void)[] = [];

function normalizeMaxEvents(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? Math.max(1, Math.trunc(value))
    : DEFAULT_MAX_EVENTS;
}

function sanitizeString(value: unknown, maxLength = 120): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  // Defense in depth: never let a URL-shaped value into a diagnostic event.
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
    return undefined;
  }
  return trimmed.length > maxLength ? trimmed.slice(0, maxLength) : trimmed;
}

function sanitizeNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? Math.trunc(value) : undefined;
}

function sanitizeEvent(input: ExtensionDiagnosticEventInput): ExtensionDiagnosticEvent {
  const event: ExtensionDiagnosticEvent = {
    ts:
      typeof input.ts === 'number' && Number.isFinite(input.ts) ? Math.trunc(input.ts) : Date.now(),
    kind: input.kind,
  };
  const anchorHost = sanitizeString(input.anchorHost);
  const dependencyHost = sanitizeString(input.dependencyHost);
  const host = sanitizeString(input.host);
  const type = sanitizeString(input.type, 40);
  const source = sanitizeString(input.source, 60);
  const transport = sanitizeString(input.transport, 20);
  const outcome = sanitizeString(input.outcome, 30);
  const reason = sanitizeString(input.reason, 80);
  if (anchorHost) event.anchorHost = anchorHost;
  if (dependencyHost) event.dependencyHost = dependencyHost;
  if (host) event.host = host;
  if (type) event.type = type;
  if (source) event.source = source;
  if (transport) event.transport = transport;
  if (outcome) event.outcome = outcome;
  if (reason) event.reason = reason;
  const frameId = sanitizeNumber(input.frameId);
  const tabId = sanitizeNumber(input.tabId);
  const navigationId = sanitizeNumber(input.navigationId);
  const ms = sanitizeNumber(input.ms);
  if (frameId !== undefined) event.frameId = frameId;
  if (tabId !== undefined) event.tabId = tabId;
  if (navigationId !== undefined) event.navigationId = navigationId;
  if (ms !== undefined) event.ms = ms;
  if (typeof input.methodKnown === 'boolean') event.methodKnown = input.methodKnown;
  if (typeof input.committed === 'boolean') event.committed = input.committed;
  return event;
}

export function recordExtensionDiagnostic(input: ExtensionDiagnosticEventInput): void {
  if (!config.enabled) {
    return;
  }
  try {
    events.push(sanitizeEvent(input));
    if (events.length > config.maxEvents) {
      events.splice(0, events.length - config.maxEvents);
      dropped += 1;
    }
    recorded += 1;
    for (const listener of listeners) {
      try {
        listener();
      } catch {
        // A broken listener must never break the recorder.
      }
    }
  } catch {
    // Recording must never break the extension.
  }
}

/** Drains up to `max` events (FIFO). */
export function drainExtensionDiagnostics(max: number): ExtensionDiagnosticEvent[] {
  const count = Math.max(0, Math.min(Math.trunc(max), events.length));
  const drained = events.slice(0, count);
  events = events.slice(count);
  return drained;
}

/**
 * Phase 3A: puts a failed batch back at the front of the buffer so a host-side
 * failure does not silently drop diagnostics. Bounded by the same capacity.
 */
export function prependExtensionDiagnostics(incoming: ExtensionDiagnosticEvent[]): void {
  if (incoming.length === 0) {
    return;
  }
  events = [...incoming, ...events];
  if (events.length > config.maxEvents) {
    events = events.slice(0, config.maxEvents);
  }
}

/** Number of buffered (not yet drained) events. */
export function pendingExtensionDiagnostics(): number {
  return events.length;
}

export function getExtensionDiagnosticsSnapshot(): ExtensionDiagnosticsSnapshot {
  return { enabled: config.enabled, recorded, dropped, pending: events.length };
}

export function configureExtensionDiagnostics(next: Partial<ExtensionDiagnosticsConfig>): void {
  config = {
    enabled: next.enabled ?? config.enabled,
    maxEvents: next.maxEvents !== undefined ? normalizeMaxEvents(next.maxEvents) : config.maxEvents,
  };
  if (events.length > config.maxEvents) {
    events.splice(0, events.length - config.maxEvents);
  }
}

/** Subscribes a reporter to "new event recorded" notifications. */
export function onExtensionDiagnostic(listener: () => void): () => void {
  listeners = [...listeners, listener];
  return () => {
    listeners = listeners.filter((candidate) => candidate !== listener);
  };
}

/** Test helper: clears the buffer and counters. */
export function resetExtensionDiagnosticsForTests(): void {
  config = { enabled: true, maxEvents: DEFAULT_MAX_EVENTS };
  events = [];
  recorded = 0;
  dropped = 0;
  listeners = [];
}
