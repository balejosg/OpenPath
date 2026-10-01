import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import type { ExtensionDiagnosticEvent } from '../src/lib/extension-diagnostics.js';
import { createExtensionDiagnosticsReporter } from '../src/lib/extension-diagnostics-reporter.js';

await describe('extension diagnostics reporter (Phase 2E E1)', async () => {
  await test('batches at most 50 events per message and throttles to one per interval', async () => {
    const pending: Partial<ExtensionDiagnosticEvent>[] = Array.from(
      { length: 120 },
      (_, index) => ({
        ts: index,
        kind: 'hold' as const,
      })
    );
    const sentBatches: unknown[][] = [];
    let currentNow = 1_000_000;
    const timers: { handler: () => void; at: number }[] = [];
    const reporter = createExtensionDiagnosticsReporter({
      drain: (max) => pending.splice(0, max) as ExtensionDiagnosticEvent[],
      send: (events) => {
        sentBatches.push(events);
        return Promise.resolve({ success: true });
      },
      isCapable: () => true,
      intervalMs: 2_000,
      batchSize: 50,
      now: () => currentNow,
      setTimeoutFn: (handler, timeout) => {
        const timer = { handler, at: currentNow + timeout };
        timers.push(timer);
        return timer as unknown as ReturnType<typeof setTimeout>;
      },
      clearTimeoutFn: () => undefined,
    });

    reporter.notify();
    assert.equal(timers.length, 1);
    const firstTimer = timers[0];
    assert.ok(firstTimer);
    assert.equal(firstTimer.at, currentNow); // first flush is not delayed

    const fire = async (): Promise<void> => {
      const timer = timers.shift();
      if (!timer) {
        return;
      }
      currentNow = timer.at;
      timer.handler();
      await Promise.resolve();
      await Promise.resolve();
    };

    await fire();
    assert.equal(sentBatches.length, 1);
    assert.equal(sentBatches[0]?.length, 50);

    // A full batch re-schedules at the throttled cadence (2 s later).
    assert.equal(timers.length, 1);
    const secondTimer = timers[0];
    assert.ok(secondTimer);
    assert.equal(secondTimer.at, currentNow + 2_000);
    await fire();
    assert.equal(sentBatches[1]?.length, 50);

    await fire();
    assert.equal(sentBatches[2]?.length, 20);
  });

  await test('does not send while the host lacks the capability', async () => {
    const pending: Partial<ExtensionDiagnosticEvent>[] = [{ ts: 1, kind: 'hold' as const }];
    const sent: unknown[] = [];
    let capable = false;
    const reporter = createExtensionDiagnosticsReporter({
      drain: (max) => pending.splice(0, max) as ExtensionDiagnosticEvent[],
      send: (events) => {
        sent.push(events);
        return Promise.resolve({ success: true });
      },
      isCapable: () => capable,
      intervalMs: 0,
    });
    reporter.notify();
    await reporter.flushNow();
    assert.equal(sent.length, 0);
    assert.equal(pending.length, 1);

    capable = true;
    reporter.notify();
    await reporter.flushNow();
    assert.equal(sent.length, 1);
    assert.equal(pending.length, 0);
  });

  await test('counts failed batches without throwing', async () => {
    const pending: Partial<ExtensionDiagnosticEvent>[] = [{ ts: 1, kind: 'hold' as const }];
    const errors: unknown[] = [];
    const reporter = createExtensionDiagnosticsReporter({
      drain: (max) => pending.splice(0, max) as ExtensionDiagnosticEvent[],
      send: () => Promise.reject(new Error('port gone')),
      isCapable: () => true,
      intervalMs: 0,
      onError: (error) => {
        errors.push(error);
      },
    });
    await reporter.flushNow();
    assert.equal(errors.length, 1);
    assert.equal(reporter.getStats().failed, 1);
  });
});
