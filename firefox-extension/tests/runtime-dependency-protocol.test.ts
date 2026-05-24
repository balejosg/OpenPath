import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS,
  LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS,
  LOCAL_RUNTIME_DEPENDENCY_OVERLAY_VERSION,
  LOCAL_RUNTIME_DEPENDENCY_QUEUE_SOURCE,
  LOCAL_RUNTIME_DEPENDENCY_QUEUE_VERSION,
  LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS,
  RUNTIME_DEPENDENCY_ACTIONS,
  createRuntimeDependencyCacheKey,
  createRuntimeDependencyPendingKey,
  isQueuedRuntimeDependencyResponse,
} from '../src/lib/runtime-dependency-protocol.js';

void test('runtime dependency protocol exports stable native-host constants', () => {
  assert.deepEqual(RUNTIME_DEPENDENCY_ACTIONS, {
    allowLocal: 'allow-local-runtime-dependency',
    allowLocalBatch: 'allow-local-runtime-dependency-batch',
  });
  assert.equal(LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS, 150);
  assert.equal(LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES, 20);
  assert.equal(LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS, 30 * 60 * 1000);
  assert.equal(LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS, 5 * 1000);
  assert.equal(LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES, 100);
  assert.equal(LOCAL_RUNTIME_DEPENDENCY_QUEUE_VERSION, 1);
  assert.equal(LOCAL_RUNTIME_DEPENDENCY_OVERLAY_VERSION, 1);
  assert.equal(LOCAL_RUNTIME_DEPENDENCY_QUEUE_SOURCE, 'firefox-webrequest-local');
});

void test('runtime dependency protocol normalizes cache and pending keys', () => {
  assert.equal(
    createRuntimeDependencyCacheKey({
      anchorHost: 'Allowed.EXAMPLE',
      dependencyHost: 'CDN.EXAMPLE',
    }),
    'allowed.example|cdn.example'
  );
  assert.equal(
    createRuntimeDependencyPendingKey({
      anchorHost: 'Allowed.EXAMPLE',
      dependencyHost: 'CDN.EXAMPLE',
      requestType: 'Script',
    }),
    'allowed.example|cdn.example|script'
  );
});

void test('runtime dependency protocol accepts both queued response shapes', () => {
  assert.equal(isQueuedRuntimeDependencyResponse({ success: true, queued: true }), true);
  assert.equal(
    isQueuedRuntimeDependencyResponse({ success: true, runtimeDependencyState: 'queued' }),
    true
  );
  assert.equal(isQueuedRuntimeDependencyResponse({ success: true }), false);
});
