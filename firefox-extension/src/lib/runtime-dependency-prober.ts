import type { NativeResponse } from './native-response.types.js';
import {
  createRuntimeDependencyPendingKey,
  LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_PROBE_INTERVAL_MS,
  LOCAL_RUNTIME_DEPENDENCY_PROBE_MAX_ENTRY_AGE_MS,
  resolveRuntimeDependencyReadiness,
  type LocalRuntimeDependencyInput,
} from './runtime-dependency-protocol.js';

export interface RuntimeDependencyProberCheckResponse extends NativeResponse {
  results?: NativeResponse[];
}

export interface RuntimeDependencyProberOptions {
  checkBatch: (
    inputs: LocalRuntimeDependencyInput[]
  ) => RuntimeDependencyProberCheckResponse | Promise<RuntimeDependencyProberCheckResponse>;
  intervalMs?: number;
  maxBatchSize?: number;
  maxEntryAgeMs?: number;
  now?: () => number;
}

interface ProberEntry {
  input: LocalRuntimeDependencyInput;
  key: string;
  onSettled: (response: NativeResponse) => void;
  registeredAt: number;
  settled: boolean;
}

export interface RuntimeDependencyProber {
  register: (
    input: LocalRuntimeDependencyInput,
    onSettled: (response: NativeResponse) => void
  ) => void;
  has: (input: LocalRuntimeDependencyInput) => boolean;
  size: () => number;
  stop: () => void;
}

function findResultForInput(
  results: NativeResponse[],
  input: LocalRuntimeDependencyInput
): NativeResponse | null {
  const normalizedDependency = input.dependencyHost.toLowerCase();
  for (const result of results) {
    const candidate = result as { dependencyHost?: unknown };
    if (
      typeof candidate.dependencyHost === 'string' &&
      candidate.dependencyHost.toLowerCase() === normalizedDependency
    ) {
      return result;
    }
  }
  return null;
}

export function createRuntimeDependencyProber(
  options: RuntimeDependencyProberOptions
): RuntimeDependencyProber {
  const intervalMs = options.intervalMs ?? LOCAL_RUNTIME_DEPENDENCY_PROBE_INTERVAL_MS;
  const maxBatchSize = options.maxBatchSize ?? LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES;
  const maxEntryAgeMs = options.maxEntryAgeMs ?? LOCAL_RUNTIME_DEPENDENCY_PROBE_MAX_ENTRY_AGE_MS;
  const now = options.now ?? ((): number => Date.now());

  const entries = new Map<string, ProberEntry>();
  let pollTimer: ReturnType<typeof setTimeout> | null = null;
  let inFlight = false;
  let stopped = false;

  const isStopped = (): boolean => stopped;

  function settleEntry(entry: ProberEntry, response: NativeResponse): void {
    if (entry.settled) {
      return;
    }
    entry.settled = true;
    entries.delete(entry.key);
    entry.onSettled(response);
  }

  function schedulePoll(): void {
    if (stopped || pollTimer !== null || entries.size === 0 || inFlight) {
      return;
    }
    pollTimer = setTimeout(() => {
      pollTimer = null;
      void poll();
    }, intervalMs);
  }

  function settleAgedEntries(): void {
    const cutoff = now() - maxEntryAgeMs;
    for (const entry of [...entries.values()]) {
      if (entry.registeredAt <= cutoff) {
        settleEntry(entry, { success: false, runtimeDependencyState: 'error', aged: true });
      }
    }
  }

  async function poll(): Promise<void> {
    if (stopped || inFlight || entries.size === 0) {
      return;
    }
    inFlight = true;
    const batch = [...entries.values()].slice(0, maxBatchSize);
    try {
      const response = await options.checkBatch(batch.map((entry) => entry.input));
      const results = Array.isArray(response.results) ? response.results : [];
      for (const entry of batch) {
        const result = findResultForInput(results, entry.input);
        if (!result) {
          continue;
        }
        if (resolveRuntimeDependencyReadiness(result) === 'pending') {
          continue;
        }
        settleEntry(entry, result);
      }
      settleAgedEntries();
    } catch {
      // The caller's budget still bounds the request; keep polling until the
      // entry settles or ages out.
    } finally {
      inFlight = false;
      if (entries.size > 0 && !isStopped()) {
        schedulePoll();
      }
    }
  }

  return {
    register: (
      input: LocalRuntimeDependencyInput,
      onSettled: (response: NativeResponse) => void
    ): void => {
      const key = createRuntimeDependencyPendingKey(input);
      const existing = entries.get(key);
      if (existing) {
        return;
      }
      entries.set(key, {
        input,
        key,
        onSettled,
        registeredAt: now(),
        settled: false,
      });
      schedulePoll();
    },
    has: (input: LocalRuntimeDependencyInput): boolean => {
      const key = createRuntimeDependencyPendingKey(input);
      return entries.has(key);
    },
    size: (): number => entries.size,
    stop: (): void => {
      stopped = true;
      if (pollTimer !== null) {
        clearTimeout(pollTimer);
        pollTimer = null;
      }
    },
  };
}
