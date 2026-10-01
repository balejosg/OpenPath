import type { ExtensionDiagnosticEvent } from './extension-diagnostics.js';

/**
 * Phase 2E E1: rate-limited batched sender for the extension diagnostics.
 *
 * Contract: at most one `report-extension-diagnostics` message every
 * `intervalMs` (2 s) and at most `batchSize` (50) events per message, and only
 * while the persistent host announced the `extension-diagnostics` capability.
 * The reporter is best-effort: diagnostics must never affect browsing.
 */

export interface ExtensionDiagnosticsReporterOptions {
  drain: (max: number) => ExtensionDiagnosticEvent[];
  send: (events: ExtensionDiagnosticEvent[]) => Promise<unknown>;
  isCapable: () => boolean;
  intervalMs?: number;
  batchSize?: number;
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
  getStats: () => { sent: number; failed: number; batches: number };
}

const DEFAULT_INTERVAL_MS = 2_000;
const DEFAULT_BATCH_SIZE = 50;

export function createExtensionDiagnosticsReporter(
  options: ExtensionDiagnosticsReporterOptions
): ExtensionDiagnosticsReporter {
  const intervalMs = options.intervalMs ?? DEFAULT_INTERVAL_MS;
  const batchSize = options.batchSize ?? DEFAULT_BATCH_SIZE;
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
  const stats = { sent: 0, failed: 0, batches: 0 };

  function schedule(): void {
    if (stopped || timer !== null) {
      return;
    }
    const delay = Math.max(0, lastSentAt + intervalMs - now());
    timer = setTimeoutFn(() => {
      timer = null;
      void flush();
    }, delay);
  }

  async function flush(): Promise<void> {
    if (stopped || !options.isCapable()) {
      return;
    }
    const events = options.drain(batchSize);
    if (events.length === 0) {
      return;
    }
    lastSentAt = now();
    stats.batches += 1;
    try {
      await options.send(events);
      stats.sent += events.length;
    } catch (error) {
      stats.failed += events.length;
      options.onError?.(error);
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
