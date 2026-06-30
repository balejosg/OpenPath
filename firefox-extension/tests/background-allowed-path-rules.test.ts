import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { createBackgroundAllowedPathRulesController } from '../src/lib/background-allowed-path-rules.js';

void describe('background allowed-path rules controller', () => {
  void it('refreshes from the native host and blocks a non-matching main_frame', async () => {
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
});
