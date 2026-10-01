import type { ExtensionDiagnosticEvent } from './extension-diagnostics.js';

/**
 * Phase 2E E1 / Phase 3A G0: rate-limited batched sender for the extension
 * diagnostics.
 *
 * Contract: at most one `report-extension-diagnostics` message every
 * `intervalMs` (2 s) and at most `batchSize` (50) events per message, and only
 * while the persistent host announced the `extension-diagnostics` capability.
 * The reporter is best-effort: diagnostics must never affect browsing.
 *
 * Phase 3A: a flush that cannot send (port still connecting, or the host
 * answered `success:false`) reschedules itself within a bounded retry budget and
 * requeues the failed batch, so a silent host-side drop can no longer make the
 * diagnostics disappear without a trace.
 */

export interface ExtensionDiagnosticsReporterOptions {
  drain: (max: number) => ExtensionDiagnosticEvent[];
  /** Puts a failed batch back into the buffer (Phase 3A). */
  requeue?: (events: ExtensionDiagnosticEvent[]) => void;
  /** Buffered event count, used to decide whether a retry is worthwhile. */
  pendingCount?: () => number;
  send: (events: ExtensionDiagnosticEvent[]) => Promise<unknown>;
  isCapable: () => boolean;
  intervalMs?: number;
  batchSize?: number;
  maxRetries?: number;
  now?: () => number;
  setTimeoutFn?: (handler: () => void, timeout: number) => ReturnType<typeof setTimeout>;
  clearTimeoutFn?: (handle: ReturnType<typeof setTimeout>) => void;
  onError?: (error: unknown) => void;
}

export interface ExtensionDiagnosticsReporter {
  /** Called whenever a new event is recorded (cheap no-op while throttled). */
  notify: () => void;
  /** Forces a flush (tests / shutdown). */
  flushNow: () => Promise<void>;
  stop: () => void;
  getStats: () => { sent: number; failed: number; batches: number; requeued: number };
}

const DEFAULT_INTERVAL_MS = 2_000;
const DEFAULT_BATCH_SIZE = 50;
const DEFAULT_MAX_RETRIES = 5;

function batchFailedResponse(response: unknown): boolean {
  return (
    typeof response === 'object' &&
    response !== null &&
    (response as { success?: unknown }).success === false
  );
}

export function createExtensionDiagnosticsReporter(
  options: ExtensionDiagnosticsReporterOptions
): ExtensionDiagnosticsReporter {
  const intervalMs = options.intervalMs ?? DEFAULT_INTERVAL_MS;
  const batchSize = options.batchSize ?? DEFAULT_BATCH_SIZE;
  const maxRetries = options.maxRetries ?? DEFAULT_MAX_RETRIES;
  const now = options.now ?? ((): number => Date.now());
  const setTimeoutFn =
    options.setTimeoutFn ??
    ((handler: () => void, timeout: number): ReturnType<typeof setTimeout> =>
      setTimeout(handler, timeout));
  const clearTimeoutFn =
    options.clearTimeoutFn ??
    ((handle: ReturnType<typeof setTimeout>): void => {
      clearTimeout(handle);
    });

  let timer: ReturnType<typeof setTimeout> | null = null;
  let lastSentAt = Number.NEGATIVE_INFINITY;
  let stopped = false;
  let retryBudget = maxRetries;
  const stats = { sent: 0, failed: 0, batches: 0, requeued: 0 };

  function schedule(delayMs?: number): void {
    if (stopped || timer !== null) {
      return;
    }
    const delay = delayMs ?? Math.max(0, lastSentAt + intervalMs - now());
    timer = setTimeoutFn(() => {
      timer = null;
      void flush();
    }, delay);
  }

  async function flush(): Promise<void> {
    if (stopped) {
      return;
    }
    if (!options.isCapable()) {
      // Phase 3A: the port may still be connecting. Keep the buffered events
      // and retry within the budget instead of waiting for the next notify.
      if ((options.pendingCount?.() ?? 0) > 0 && retryBudget > 0) {
        retryBudget -= 1;
        schedule(intervalMs);
      }
      return;
    }
    const events = options.drain(batchSize);
    if (events.length === 0) {
      return;
    }
    lastSentAt = now();
    stats.batches += 1;
    let failed = false;
    try {
      const response = await options.send(events);
      if (batchFailedResponse(response)) {
        throw new Error('native host rejected the diagnostics batch');
      }
      stats.sent += events.length;
      retryBudget = maxRetries;
    } catch (error) {
      failed = true;
      stats.failed += events.length;
      options.requeue?.(events);
      stats.requeued += events.length;
      options.onError?.(error);
    }
    if (failed) {
      if (retryBudget > 0) {
        retryBudget -= 1;
        schedule(intervalMs);
      }
      return;
    }
    if (events.length >= batchSize) {
      // A full batch usually means more events are still pending; keep draining
      // at the throttled cadence. Events recorded meanwhile also re-schedule
      // through notify().
      schedule();
    }
  }

  return {
    notify: (): void => {
      retryBudget = maxRetries;
      schedule();
    },
    flushNow: async (): Promise<void> => {
      if (timer !== null) {
        clearTimeoutFn(timer);
        timer = null;
      }
      await flush();
    },
    stop: (): void => {
      stopped = true;
      if (timer !== null) {
        clearTimeoutFn(timer);
        timer = null;
      }
    },
    getStats: () => ({ ...stats }),
  };
}
