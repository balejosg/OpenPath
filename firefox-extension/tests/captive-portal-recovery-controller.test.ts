import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createCaptivePortalRecoveryController } from '../src/lib/captive-portal-recovery-controller.js';
import type { CaptivePortalRecoveryInput } from '../src/lib/native-messaging-client.js';

test('captive portal recovery retries current locked-portal navigations once per rate window', async () => {
  let now = 1_000;
  const recoveryInputs: CaptivePortalRecoveryInput[] = [];
  const retries: { tabId: number; url: string }[] = [];
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('locked_portal'),
    now: () => now,
    recoverCaptivePortalNavigation: (input) => {
      recoveryInputs.push(input);
      return Promise.resolve({ success: true });
    },
    retryNavigation: (tabId, url) => {
      retries.push({ tabId, url });
      return Promise.resolve();
    },
  });

  assert.equal(
    await controller.recoverNavigation({
      tabId: 7,
      hostname: 'Portal.EXAMPLE',
      url: 'http://portal.example/start',
    }),
    true
  );
  assert.equal(
    await controller.recoverNavigation({
      tabId: 7,
      hostname: 'portal.example',
      url: 'http://portal.example/start',
    }),
    false
  );

  now += 30_000;
  assert.equal(
    await controller.recoverNavigation({
      tabId: 7,
      hostname: 'portal.example',
      url: 'http://portal.example/start',
    }),
    true
  );

  assert.deepEqual(
    recoveryInputs.map((input) => input.triggerHost),
    ['Portal.EXAMPLE', 'portal.example']
  );
  assert.equal(retries.length, 2);
});

test('captive portal recovery clears per-tab limiter on dispose', async () => {
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('locked_portal'),
    now: () => 5_000,
    recoverCaptivePortalNavigation: () => Promise.resolve({ success: true }),
    retryNavigation: () => Promise.resolve(),
  });
  const navigation = {
    tabId: 9,
    hostname: 'portal.example',
    url: 'http://portal.example/start',
  };

  assert.equal(await controller.recoverNavigation(navigation), true);
  assert.equal(await controller.recoverNavigation(navigation), false);

  controller.disposeTab(9);

  assert.equal(await controller.recoverNavigation(navigation), true);
});

test('captive portal recovery reconciles only unlocked portal state changes', async () => {
  const operations: CaptivePortalRecoveryInput[] = [];
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('not_locked'),
    recoverCaptivePortalNavigation: (input) => {
      operations.push(input);
      return Promise.resolve({ success: true });
    },
    retryNavigation: () => Promise.resolve(),
  });

  assert.equal(
    await controller.recoverNavigation({
      tabId: 3,
      hostname: 'portal.example',
      url: 'http://portal.example/start',
    }),
    false
  );
  await controller.handlePortalStateChanged('unlocked_portal');
  await controller.handlePortalStateChanged('locked_portal');
  await controller.handleConnectivityAvailable();

  assert.deepEqual(
    operations.map((input) => input.source),
    ['firefox-captivePortal:state-changed', 'firefox-captivePortal:connectivity-available']
  );
});
