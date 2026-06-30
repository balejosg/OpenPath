import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { createBackgroundAllowedPathRulesController } from '../src/lib/background-allowed-path-rules.js';

void describe('background allowed-path rules controller', () => {
  void test('refreshes from the native host and blocks a non-matching main_frame', async () => {
    const controller = createBackgroundAllowedPathRulesController({
      extensionOrigin: 'moz-extension://abc/',
      getAllowedPaths: () =>
        Promise.resolve({
          success: true,
          paths: ['youtube.com/watch?v=abc'],
          hash: 'h1',
        }),
    });
    await controller.init();
    assert.equal(
      controller.evaluateRequest({
        type: 'main_frame',
        url: 'https://www.youtube.com/watch?v=abc',
      } as never),
      null
    );
    const blocked = controller.evaluateRequest({
      type: 'main_frame',
      url: 'https://www.youtube.com/watch?v=zzz',
    } as never);
    assert.ok(blocked?.redirectUrl);
  });

  void test('refresh(true) populates getDebugState fields', async () => {
    const controller = createBackgroundAllowedPathRulesController({
      extensionOrigin: 'moz-extension://unit-test/',
      getAllowedPaths: () =>
        Promise.resolve({
          success: true,
          paths: ['youtube.com/watch?v=abc'],
          hash: 'policy-v1',
        }),
    });

    assert.strictEqual(await controller.refresh(true), true);
    const debug = controller.getDebugState();
    assert.strictEqual(debug.success, true);
    assert.strictEqual(debug.version, 'policy-v1');
    assert.strictEqual(debug.count, 1);
    assert.ok(Array.isArray(debug.managedHosts));
    assert.ok(debug.managedHosts.includes('youtube.com'));
    assert.ok(Array.isArray(debug.rawRules));
    assert.deepStrictEqual(debug.rawRules, ['youtube.com/watch?v=abc']);
    assert.ok(Array.isArray(debug.compiledPatterns));
    assert.ok(debug.compiledPatterns.length > 0);
  });

  void test('refresh(false) with unchanged version returns true without re-compiling', async () => {
    const controller = createBackgroundAllowedPathRulesController({
      extensionOrigin: 'moz-extension://unit-test/',
      getAllowedPaths: () =>
        Promise.resolve({
          success: true,
          paths: ['example.com/allowed'],
          hash: 'stable-hash',
        }),
    });

    assert.strictEqual(await controller.refresh(true), true);
    // Second call with force=false, same version hash — should hit the version-skip early return
    assert.strictEqual(await controller.refresh(false), true);
    assert.strictEqual(controller.getDebugState().version, 'stable-hash');
  });

  void test('native response with success:false causes refresh to return false and forceRefresh to report error with unchanged debug state', async () => {
    const controller = createBackgroundAllowedPathRulesController({
      extensionOrigin: 'moz-extension://unit-test/',
      getAllowedPaths: () =>
        Promise.resolve({
          success: false,
          error: 'native unavailable',
        }),
    });

    assert.strictEqual(await controller.refresh(true), false);
    const result = await controller.forceRefresh();
    assert.strictEqual(result.success, false);
    assert.ok(typeof result.error === 'string' && result.error.length > 0);
    // debug state must remain at defaults (empty rules)
    const debug = controller.getDebugState();
    assert.strictEqual(debug.version, '');
    assert.strictEqual(debug.count, 0);
    assert.deepStrictEqual(debug.managedHosts, []);
    assert.deepStrictEqual(debug.rawRules, []);
  });

  void test('getAllowedPaths that throws causes refresh to return false (caught)', async () => {
    const controller = createBackgroundAllowedPathRulesController({
      extensionOrigin: 'moz-extension://unit-test/',
      getAllowedPaths: () => Promise.reject(new Error('native crashed')),
    });

    assert.strictEqual(await controller.refresh(true), false);
  });

  void test('replaces an existing refresh loop timer', () => {
    const originalSetInterval = globalThis.setInterval;
    const originalClearInterval = globalThis.clearInterval;
    const intervals: (() => void)[] = [];
    const cleared: unknown[] = [];

    globalThis.setInterval = ((handler: TimerHandler) => {
      intervals.push(handler as () => void);
      return intervals.length as never;
    }) as unknown as typeof setInterval;
    globalThis.clearInterval = ((timer: unknown) => {
      cleared.push(timer);
    }) as unknown as typeof clearInterval;

    try {
      const controller = createBackgroundAllowedPathRulesController({
        extensionOrigin: 'moz-extension://unit-test/',
        getAllowedPaths: () =>
          Promise.resolve({
            success: true,
            paths: [],
            hash: 'policy-v1',
          }),
      });

      controller.startRefreshLoop();
      controller.startRefreshLoop();

      assert.strictEqual(intervals.length, 2);
      assert.deepStrictEqual(cleared, [1]);
    } finally {
      globalThis.setInterval = originalSetInterval;
      globalThis.clearInterval = originalClearInterval;
    }
  });
});
