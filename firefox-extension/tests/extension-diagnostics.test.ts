import assert from 'node:assert/strict';
import { beforeEach, describe, test } from 'node:test';

import type { ExtensionDiagnosticEvent } from '../src/lib/extension-diagnostics.js';

import {
  configureExtensionDiagnostics,
  drainExtensionDiagnostics,
  getExtensionDiagnosticsSnapshot,
  onExtensionDiagnostic,
  pendingExtensionDiagnostics,
  prependExtensionDiagnostics,
  recordExtensionDiagnostic,
  resetExtensionDiagnosticsForTests,
} from '../src/lib/extension-diagnostics.js';

await describe('extension diagnostics buffer (Phase 2E E1)', async () => {
  beforeEach(() => {
    resetExtensionDiagnosticsForTests();
  });

  await test('records sanitized events and drains them in FIFO order', () => {
    recordExtensionDiagnostic({
      kind: 'hold',
      tabId: 4,
      frameId: 0,
      type: 'stylesheet',
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      transport: 'ready',
    });
    recordExtensionDiagnostic({ kind: 'hold-outcome', outcome: 'ready', ms: 1234 });

    const drained = drainExtensionDiagnostics(10);
    assert.equal(drained.length, 2);
    const [first, second] = drained;
    assert.ok(first && second);
    assert.equal(first.kind, 'hold');
    assert.equal(first.dependencyHost, 'www.redditstatic.com');
    assert.equal(second.outcome, 'ready');
    assert.equal(second.ms, 1234);
    assert.equal(getExtensionDiagnosticsSnapshot().pending, 0);
  });

  await test('never records URL-shaped values (hosts and reasons only)', () => {
    recordExtensionDiagnostic({
      kind: 'hold',
      anchorHost: 'https://www.reddit.com/r/secret?token=abc',
      dependencyHost: 'cdn.example',
      reason: 'https://tracker.example/pixel?id=1',
    });
    const [event] = drainExtensionDiagnostics(10);
    assert.ok(event);
    assert.equal(event.anchorHost, undefined);
    assert.equal(event.reason, undefined);
    assert.equal(event.dependencyHost, 'cdn.example');
  });

  await test('is bounded by maxEvents and counts drops', () => {
    configureExtensionDiagnostics({ maxEvents: 3 });
    for (let index = 0; index < 5; index += 1) {
      recordExtensionDiagnostic({ kind: 'transport', from: 'idle', to: 'ready', ms: index });
    }
    const snapshot = getExtensionDiagnosticsSnapshot();
    assert.equal(snapshot.pending, 3);
    assert.equal(snapshot.dropped, 2);
    const drained = drainExtensionDiagnostics(10);
    assert.equal(drained.length, 3);
    assert.equal(drained[0]?.ms, 2);
  });

  await test('requeues failed batches at the front and reports the pending count', () => {
    recordExtensionDiagnostic({ kind: 'hold', ts: 1 });
    const drained = drainExtensionDiagnostics(10);
    assert.equal(drained.length, 1);
    assert.equal(pendingExtensionDiagnostics(), 0);

    prependExtensionDiagnostics(drained);
    assert.equal(pendingExtensionDiagnostics(), 1);
    recordExtensionDiagnostic({ kind: 'transport', ts: 2 });
    const drainedAgain = drainExtensionDiagnostics(10);
    assert.equal(drainedAgain[0]?.ts, 1, 'the requeued event keeps its position at the front');
    assert.equal(drainedAgain[1]?.ts, 2);

    // Capacity stays bounded: the oldest requeued events are dropped.
    configureExtensionDiagnostics({ maxEvents: 2 });
    prependExtensionDiagnostics([
      { ts: 10, kind: 'hold' },
      { ts: 11, kind: 'hold' },
      { ts: 12, kind: 'hold' },
    ] as ExtensionDiagnosticEvent[]);
    assert.equal(pendingExtensionDiagnostics(), 2);
  });

  await test('stops recording when disabled and notifies subscribers', () => {
    let notifications = 0;
    onExtensionDiagnostic(() => {
      notifications += 1;
    });
    recordExtensionDiagnostic({ kind: 'background-start' });
    configureExtensionDiagnostics({ enabled: false });
    recordExtensionDiagnostic({ kind: 'background-start' });
    assert.equal(notifications, 1);
    assert.equal(drainExtensionDiagnostics(10).length, 1);
  });
});
