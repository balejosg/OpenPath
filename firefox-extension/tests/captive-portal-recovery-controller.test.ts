import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createCaptivePortalRecoveryController } from '../src/lib/captive-portal-recovery-controller.js';
import type { CaptivePortalRecoveryInput } from '../src/lib/native-messaging-client.js';

void test('captive portal recovery retries current locked-portal navigations once per rate window', async () => {
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
    sleep: () => Promise.resolve(),
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

void test('captive portal recovery forwards bounded portal recovery hosts to native open', async () => {
  const recoveryInputs: CaptivePortalRecoveryInput[] = [];
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('locked_portal'),
    recoverCaptivePortalNavigation: (input) => {
      recoveryInputs.push(input);
      return Promise.resolve({ success: true });
    },
    retryNavigation: () => Promise.resolve(),
    sleep: () => Promise.resolve(),
  });

  assert.equal(
    await controller.recoverNavigation({
      tabId: 7,
      hostname: 'login.wedu.example',
      portalRecoveryHosts: [
        'nce.wedu.comunidad.madrid',
        'login.wedu.example',
        'assets.wedu.example',
      ],
      url: 'https://login.wedu.example/login?token=secret',
    }),
    true
  );

  assert.deepEqual(recoveryInputs, [
    {
      portalRecoveryHosts: [
        'nce.wedu.comunidad.madrid',
        'login.wedu.example',
        'assets.wedu.example',
      ],
      portalState: 'locked_portal',
      tabId: 7,
      triggerHost: 'login.wedu.example',
    },
  ]);
});

void test('captive portal recovery allows enriched portal hosts inside the rate window', async () => {
  let now = 10_000;
  const recoveryInputs: CaptivePortalRecoveryInput[] = [];
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('locked_portal'),
    now: () => now,
    recoverCaptivePortalNavigation: (input) => {
      recoveryInputs.push(input);
      return Promise.resolve({ success: true });
    },
    retryNavigation: () => Promise.resolve(),
    sleep: () => Promise.resolve(),
  });
  const navigation = {
    tabId: 7,
    hostname: 'login.wedu.example',
    url: 'https://login.wedu.example/login',
  };

  assert.equal(
    await controller.recoverNavigation({
      ...navigation,
      portalRecoveryHosts: ['login.wedu.example'],
    }),
    true
  );
  assert.equal(
    await controller.recoverNavigation({
      ...navigation,
      portalRecoveryHosts: ['login.wedu.example'],
    }),
    false
  );
  assert.equal(
    await controller.recoverNavigation({
      ...navigation,
      portalRecoveryHosts: ['login.wedu.example', 'assets.wedu.example'],
    }),
    true
  );
  now += 1_000;
  assert.equal(
    await controller.recoverNavigation({
      ...navigation,
      portalRecoveryHosts: ['login.wedu.example', 'assets.wedu.example'],
    }),
    false
  );

  assert.deepEqual(
    recoveryInputs.map((input) => input.portalRecoveryHosts),
    [['login.wedu.example'], ['login.wedu.example', 'assets.wedu.example']]
  );
});

void test('captive portal recovery waits before retrying and revalidates current navigation', async () => {
  const events: string[] = [];
  let currentNavigation = true;
  let releaseSleep!: () => void;
  const sleepReleased = new Promise<void>((resolve) => {
    releaseSleep = resolve;
  });
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('locked_portal'),
    recoverCaptivePortalNavigation: () => {
      events.push('native-recovery');
      return Promise.resolve({ success: true });
    },
    retryNavigation: () => {
      events.push('retry');
      return Promise.resolve();
    },
    sleep: (milliseconds) => {
      events.push(`sleep:${milliseconds.toString()}`);
      return sleepReleased;
    },
  });

  assert.equal(
    await controller.recoverNavigation(
      {
        tabId: 7,
        hostname: 'portal.example',
        url: 'http://portal.example/start',
      },
      {
        isCurrentNavigation: () => currentNavigation,
      }
    ),
    true
  );
  assert.deepEqual(events, ['native-recovery', 'sleep:750']);
  currentNavigation = false;
  releaseSleep();
  await sleepReleased;
  await new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
  assert.deepEqual(events, ['native-recovery', 'sleep:750']);
});

void test('captive portal recovery retries only after the configured delay resolves', async () => {
  const events: string[] = [];
  let releaseSleep!: () => void;
  const sleepReleased = new Promise<void>((resolve) => {
    releaseSleep = resolve;
  });
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('locked_portal'),
    recoverCaptivePortalNavigation: () => Promise.resolve({ success: true }),
    retryNavigation: (tabId, url) => {
      events.push(`retry:${tabId.toString()}:${url}`);
      return Promise.resolve();
    },
    sleep: (milliseconds) => {
      events.push(`sleep:${milliseconds.toString()}`);
      return sleepReleased;
    },
  });

  assert.equal(
    await controller.recoverNavigation({
      tabId: 8,
      hostname: 'portal.example',
      url: 'http://portal.example/start',
    }),
    true
  );
  assert.deepEqual(events, ['sleep:750']);

  releaseSleep();
  await sleepReleased;
  await new Promise((resolve) => {
    setTimeout(resolve, 0);
  });

  assert.deepEqual(events, ['sleep:750', 'retry:8:http://portal.example/start']);
});

void test('captive portal recovery clears per-tab limiter on dispose', async () => {
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('locked_portal'),
    now: () => 5_000,
    recoverCaptivePortalNavigation: () => Promise.resolve({ success: true }),
    retryNavigation: () => Promise.resolve(),
    sleep: () => Promise.resolve(),
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

void test('captive portal recovery allows unknown Firefox state only with native portal eligibility', async () => {
  const recoveryInputs: CaptivePortalRecoveryInput[] = [];
  const retries: { tabId: number; url: string }[] = [];
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('unknown'),
    isNativePortalRecoveryEligible: ({ hostname }: { hostname: string }) =>
      Promise.resolve(hostname === 'portal.example'),
    recoverCaptivePortalNavigation: (input) => {
      recoveryInputs.push(input);
      return Promise.resolve({ success: true });
    },
    retryNavigation: (tabId, url) => {
      retries.push({ tabId, url });
      return Promise.resolve();
    },
    sleep: () => Promise.resolve(),
  } as Parameters<typeof createCaptivePortalRecoveryController>[0] & {
    isNativePortalRecoveryEligible: (context: { hostname: string }) => Promise<boolean>;
  });

  assert.equal(
    await controller.recoverNavigation({
      tabId: 11,
      hostname: 'portal.example',
      url: 'https://portal.example/login',
    }),
    true
  );

  assert.deepEqual(
    recoveryInputs.map((input) => input.triggerHost),
    ['portal.example']
  );
  assert.deepEqual(retries, [{ tabId: 11, url: 'https://portal.example/login' }]);
});

void test('captive portal recovery reconciles only unlocked portal state changes', async () => {
  const operations: CaptivePortalRecoveryInput[] = [];
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('not_locked'),
    recoverCaptivePortalNavigation: (input) => {
      operations.push(input);
      return Promise.resolve({ success: true });
    },
    retryNavigation: () => Promise.resolve(),
    sleep: () => Promise.resolve(),
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

void test('captive portal recovery uses explicit reconcile operations for Firefox post-login signals', async () => {
  const operations: CaptivePortalRecoveryInput[] = [];
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve('not_locked'),
    recoverCaptivePortalNavigation: (input) => {
      operations.push(input);
      return Promise.resolve({ success: true });
    },
    retryNavigation: () => Promise.resolve(),
    sleep: () => Promise.resolve(),
  });

  await controller.handlePortalStateChanged('unlocked_portal');
  await controller.handleConnectivityAvailable();

  assert.deepEqual(
    operations.map((input) => ({
      operation: input.operation,
      portalState: input.portalState,
      source: input.source,
      triggerHost: input.triggerHost ?? '',
    })),
    [
      {
        operation: 'reconcile',
        portalState: 'unlocked_portal',
        source: 'firefox-captivePortal:state-changed',
        triggerHost: '',
      },
      {
        operation: 'reconcile',
        portalState: 'Unknown',
        source: 'firefox-captivePortal:connectivity-available',
        triggerHost: '',
      },
    ]
  );
});
