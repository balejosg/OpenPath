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

  await test('retries while the port is not ready and sends when it becomes capable', async () => {
    const pending: Partial<ExtensionDiagnosticEvent>[] = [{ ts: 1, kind: 'hold' as const }];
    const sent: unknown[] = [];
    let capable = false;
    const timers: { handler: () => void; at: number }[] = [];
    let currentNow = 1_000_000;
    const reporter = createExtensionDiagnosticsReporter({
      drain: (max) => pending.splice(0, max) as ExtensionDiagnosticEvent[],
      requeue: (events) => {
        pending.unshift(...events);
      },
      pendingCount: () => pending.length,
      send: (events) => {
        sent.push(events);
        return Promise.resolve({ success: true });
      },
      isCapable: () => capable,
      intervalMs: 2_000,
      now: () => currentNow,
      setTimeoutFn: (handler, timeout) => {
        const timer = { handler, at: currentNow + timeout };
        timers.push(timer);
        return timer as unknown as ReturnType<typeof setTimeout>;
      },
      clearTimeoutFn: () => undefined,
    });

    reporter.notify();
    const fire = (): void => {
      const timer = timers.shift();
      if (!timer) {
        return;
      }
      currentNow = timer.at;
      timer.handler();
    };

    fire();
    await Promise.resolve();
    assert.equal(sent.length, 0, 'not capable yet: nothing is sent');
    assert.equal(
      timers.length,
      1,
      'the reporter reschedules itself instead of waiting for a new event'
    );
    assert.equal(timers[0]?.at, currentNow + 2_000);

    capable = true;
    fire();
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(sent.length, 1);
    assert.equal(pending.length, 0);
  });

  await test('requeues a batch the host rejected and retries once', async () => {
    let pending: Partial<ExtensionDiagnosticEvent>[] = [{ ts: 1, kind: 'hold' as const }];
    const responses: { success: boolean }[] = [{ success: false }, { success: true }];
    const attempts: unknown[][] = [];
    const timers: (() => void)[] = [];
    const reporter = createExtensionDiagnosticsReporter({
      drain: (max) => pending.splice(0, max) as ExtensionDiagnosticEvent[],
      requeue: (events) => {
        pending = [...(events as Partial<ExtensionDiagnosticEvent>[]), ...pending];
      },
      pendingCount: () => pending.length,
      send: (events) => {
        attempts.push(events);
        return Promise.resolve(responses.shift() ?? { success: true });
      },
      isCapable: () => true,
      intervalMs: 0,
      setTimeoutFn: (handler) => {
        timers.push(handler);
        return {} as unknown as ReturnType<typeof setTimeout>;
      },
      clearTimeoutFn: () => undefined,
    });

    reporter.notify();
    timers.shift()?.();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(attempts.length, 1);
    assert.equal(reporter.getStats().failed, 1);
    assert.equal(reporter.getStats().requeued, 1);
    assert.equal(pending.length, 1, 'a rejected batch goes back to the buffer');
    assert.equal(timers.length, 1, 'a retry is scheduled');

    timers.shift()?.();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(attempts.length, 2);
    assert.equal(pending.length, 0);
    assert.equal(reporter.getStats().sent, 1);
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
