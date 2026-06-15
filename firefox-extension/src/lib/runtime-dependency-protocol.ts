import type { NativeResponse } from './native-response.types.js';

export interface LocalRuntimeDependencyInput {
  anchorHost: string;
  dependencyHost: string;
  requestType: string;
}

export const RUNTIME_DEPENDENCY_ACTIONS = {
  allowLocal: 'allow-local-runtime-dependency',
  allowLocalBatch: 'allow-local-runtime-dependency-batch',
} as const;

export const LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS = 150;
export const LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES = 20;
export const LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS = 30 * 60 * 1000;
export const LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS = 5 * 1000;
export const LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES = 100;
export const LOCAL_RUNTIME_DEPENDENCY_QUEUE_VERSION = 1;
export const LOCAL_RUNTIME_DEPENDENCY_OVERLAY_VERSION = 1;
export const LOCAL_RUNTIME_DEPENDENCY_QUEUE_SOURCE = 'firefox-webrequest-local';

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
