import assert from 'node:assert/strict';
import { describe, mock, test } from 'node:test';

import { createRuntimeDependencyProber } from '../src/lib/runtime-dependency-prober.js';
import type { LocalRuntimeDependencyInput } from '../src/lib/runtime-dependency-protocol.js';

function input(dependencyHost: string, requestType = 'script'): LocalRuntimeDependencyInput {
  return { anchorHost: 'www.reddit.com', dependencyHost, requestType };
}

async function flushMicrotasks(): Promise<void> {
  for (let i = 0; i < 5; i += 1) {
    await Promise.resolve();
  }
}

await describe('runtime dependency prober', async () => {
  await test('polls registered entries and settles them when the host reports ready', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      const checks: LocalRuntimeDependencyInput[][] = [];
      const settled: unknown[] = [];
      const prober = createRuntimeDependencyProber({
        checkBatch: (inputs) => {
          checks.push(inputs);
          if (checks.length === 1) {
            return { success: true, results: [{ success: true, ...inputs[0], ready: false }] };
          }
          return {
            success: true,
            results: [
              { success: true, ...inputs[0], ready: true, runtimeDependencyState: 'ready' },
            ],
          };
        },
        intervalMs: 150,
      });

      prober.register(input('cdn.example'), (response) => {
        settled.push(response);
      });
      assert.equal(prober.size(), 1);

      mock.timers.tick(150);
      await flushMicrotasks();
      assert.equal(settled.length, 0);
      assert.equal(prober.size(), 1);

      mock.timers.tick(150);
      await flushMicrotasks();
      assert.equal(settled.length, 1);
      assert.equal(prober.size(), 0);
      assert.deepEqual(checks[0], [input('cdn.example')]);
    } finally {
      mock.timers.reset();
    }
  });

  await test('checks every pending entry in one batch and keeps polling only the pending ones', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      const settled: string[] = [];
      let round = 0;
      const prober = createRuntimeDependencyProber({
        checkBatch: (inputs) => {
          round += 1;
          return {
            success: true,
            results: inputs.map((entry) =>
              entry.dependencyHost === 'cdn-ready.example' || round > 1
                ? { success: true, ...entry, ready: true, runtimeDependencyState: 'ready' }
                : { success: true, ...entry, ready: false, runtimeDependencyState: 'pending' }
            ),
          };
        },
        intervalMs: 150,
      });

      prober.register(input('cdn-ready.example'), () => {
        settled.push('cdn-ready.example');
      });
      prober.register(input('cdn-slow.example'), () => {
        settled.push('cdn-slow.example');
      });

      mock.timers.tick(150);
      await flushMicrotasks();
      assert.deepEqual(settled, ['cdn-ready.example']);
      assert.equal(prober.size(), 1);

      mock.timers.tick(150);
      await flushMicrotasks();
      assert.deepEqual(settled, ['cdn-ready.example', 'cdn-slow.example']);
      assert.equal(prober.size(), 0);
    } finally {
      mock.timers.reset();
    }
  });

  await test('settles terminal responses without further polling', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      let checks = 0;
      const settled: unknown[] = [];
      const prober = createRuntimeDependencyProber({
        checkBatch: (inputs) => {
          checks += 1;
          return {
            success: false,
            results: [{ success: false, ...inputs[0], runtimeDependencyState: 'error' }],
          };
        },
        intervalMs: 150,
      });

      prober.register(input('cdn.example'), (response) => {
        settled.push(response);
      });
      mock.timers.tick(150);
      await flushMicrotasks();

      assert.equal(settled.length, 1);
      assert.equal(prober.size(), 0);
      mock.timers.tick(1000);
      await flushMicrotasks();
      assert.equal(checks, 1);
    } finally {
      mock.timers.reset();
    }
  });

  await test('keeps polling after a failed check and after an unmatched result', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      let checks = 0;
      const settled: unknown[] = [];
      const prober = createRuntimeDependencyProber({
        checkBatch: (inputs) => {
          checks += 1;
          if (checks === 1) {
            throw new Error('port unavailable');
          }
          if (checks === 2) {
            return { success: true, results: [] };
          }
          return {
            success: true,
            results: [
              { success: true, ...inputs[0], ready: true, runtimeDependencyState: 'ready' },
            ],
          };
        },
        intervalMs: 150,
      });

      prober.register(input('cdn.example'), (response) => {
        settled.push(response);
      });

      mock.timers.tick(150);
      await flushMicrotasks();
      assert.equal(checks, 1);
      assert.equal(settled.length, 0);

      mock.timers.tick(150);
      await flushMicrotasks();
      assert.equal(checks, 2);
      assert.equal(settled.length, 0);

      mock.timers.tick(150);
      await flushMicrotasks();
      assert.equal(settled.length, 1);
      assert.equal(prober.size(), 0);
    } finally {
      mock.timers.reset();
    }
  });

  await test('settles entries as terminal once they age out instead of polling forever', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      let currentNow = 1_000_000;
      const settled: { aged?: unknown }[] = [];
      const prober = createRuntimeDependencyProber({
        checkBatch: (inputs) => ({
          success: true,
          results: inputs.map((entry) => ({ success: true, ...entry, ready: false })),
        }),
        intervalMs: 150,
        maxEntryAgeMs: 400,
        now: () => currentNow,
      });

      prober.register(input('cdn.example'), (response) => {
        settled.push(response as { aged?: unknown });
      });

      mock.timers.tick(150);
      await flushMicrotasks();
      assert.equal(settled.length, 0);

      currentNow += 500;
      mock.timers.tick(150);
      await flushMicrotasks();
      assert.equal(settled.length, 1);
      assert.equal(settled[0]?.aged, true);
      assert.equal(prober.size(), 0);
    } finally {
      mock.timers.reset();
    }
  });

  await test('does not schedule polls without entries and stops on demand', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      let checks = 0;
      const prober = createRuntimeDependencyProber({
        checkBatch: () => {
          checks += 1;
          return { success: true, results: [] };
        },
        intervalMs: 150,
      });

      mock.timers.tick(1000);
      await flushMicrotasks();
      assert.equal(checks, 0);

      prober.register(input('cdn.example'), () => undefined);
      prober.stop();
      mock.timers.tick(1000);
      await flushMicrotasks();
      assert.equal(checks, 0);
    } finally {
      mock.timers.reset();
    }
  });

  await test('has() reports whether an entry is still pending', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      const prober = createRuntimeDependencyProber({
        checkBatch: (inputs) => ({
          success: true,
          results: inputs.map((entry) => ({
            success: true,
            ...entry,
            runtimeDependencyState: 'ready',
          })),
        }),
        intervalMs: 150,
      });
      prober.register(input('cdn.example'), () => undefined);
      assert.equal(prober.has(input('cdn.example')), true);
      assert.equal(prober.has(input('cdn-other.example')), false);

      mock.timers.tick(150);
      await flushMicrotasks();
      assert.equal(prober.has(input('cdn.example')), false);
    } finally {
      mock.timers.reset();
    }
  });
});
