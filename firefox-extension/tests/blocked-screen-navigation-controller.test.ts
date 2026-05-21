import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { WebRequest } from 'webextension-polyfill';

import { createBlockedScreenNavigationController } from '../src/lib/blocked-screen-navigation-controller.js';

interface BlockedScreenContext {
  tabId: number;
  hostname: string;
  error: string;
  origin: string | null;
}

void describe('blocked screen navigation controller', () => {
  void test('native policy preflight records and redirects only after confirmation succeeds', async () => {
    const addedBlocks: BlockedScreenContext[] = [];
    const redirects: BlockedScreenContext[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: (tabId, hostname, error, origin) => {
        addedBlocks.push({ tabId, hostname, error, origin: origin ?? null });
      },
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://blocked.example/lesson'),
      now: () => 1000,
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleNativePolicyNavigationPreflight({
      frameId: 0,
      tabId: 4,
      url: 'https://blocked.example/lesson',
    });
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(addedBlocks, [
      {
        tabId: 4,
        hostname: 'blocked.example',
        error: 'OPENPATH_NATIVE_POLICY_BLOCKED',
        origin: null,
      },
    ]);
    assert.deepEqual(redirects, [
      {
        tabId: 4,
        hostname: 'blocked.example',
        error: 'OPENPATH_NATIVE_POLICY_BLOCKED',
        origin: null,
      },
    ]);
  });

  void test('duplicate redirect window suppresses late duplicate errors', async () => {
    const redirects: BlockedScreenContext[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://late.example/lesson'),
      now: () => 2000,
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleNativePolicyNavigationPreflight({
      frameId: 0,
      tabId: 8,
      url: 'https://late.example/lesson',
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_NET_TIMEOUT',
        tabId: 8,
        type: 'main_frame',
        url: 'https://late.example/lesson',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(redirects, [
      {
        tabId: 8,
        hostname: 'late.example',
        error: 'OPENPATH_NATIVE_POLICY_BLOCKED',
        origin: null,
      },
    ]);
  });

  void test('already-on-blocked-screen tabs do not reload', async () => {
    const redirects: BlockedScreenContext[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () =>
        Promise.resolve('moz-extension://unit-test/blocked/blocked.html?domain=blocked.example'),
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_NET_TIMEOUT',
        tabId: 9,
        type: 'main_frame',
        url: 'https://blocked.example/favicon.ico',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(redirects, []);
  });

  void test('captive portal recovery success suppresses unknown-host blocked page', async () => {
    const redirects: BlockedScreenContext[] = [];
    const recoveryCalls: unknown[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://nce.wedu.comunidad.madrid/login'),
      recoverCaptivePortalNavigation: (context) => {
        recoveryCalls.push(context);
        return Promise.resolve(true);
      },
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_UNKNOWN_HOST',
        tabId: 11,
        type: 'main_frame',
        url: 'https://nce.wedu.comunidad.madrid/login',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(recoveryCalls, [
      {
        tabId: 11,
        hostname: 'nce.wedu.comunidad.madrid',
        error: 'NS_ERROR_UNKNOWN_HOST',
        origin: null,
        url: 'https://nce.wedu.comunidad.madrid/login',
      },
    ]);
    assert.deepEqual(redirects, []);
  });

  void test('captive portal recovery failure keeps unknown-host blocked page behavior', async () => {
    const redirects: BlockedScreenContext[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://missing.example/lesson'),
      recoverCaptivePortalNavigation: () => Promise.resolve(false),
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_UNKNOWN_HOST',
        tabId: 12,
        type: 'main_frame',
        url: 'https://missing.example/lesson',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(redirects, [
      {
        tabId: 12,
        hostname: 'missing.example',
        error: 'NS_ERROR_UNKNOWN_HOST',
        origin: null,
      },
    ]);
  });

  void test('captive portal recovery can suppress timeout when native confirmation does not prove a block', async () => {
    const redirects: BlockedScreenContext[] = [];
    const recoveryCalls: unknown[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      confirmBlockedScreenNavigation: () => Promise.resolve(false),
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://nce.wedu.comunidad.madrid/login'),
      recoverCaptivePortalNavigation: (context) => {
        recoveryCalls.push(context);
        return Promise.resolve(true);
      },
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_NET_TIMEOUT',
        tabId: 13,
        type: 'main_frame',
        url: 'https://nce.wedu.comunidad.madrid/login',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(recoveryCalls, [
      {
        tabId: 13,
        hostname: 'nce.wedu.comunidad.madrid',
        error: 'NS_ERROR_NET_TIMEOUT',
        origin: null,
        url: 'https://nce.wedu.comunidad.madrid/login',
      },
    ]);
    assert.deepEqual(redirects, []);
  });

  void test('stale native-confirmation fallback only handles the latest tab URL', async () => {
    const redirects: BlockedScreenContext[] = [];
    const recoveryCalls: unknown[] = [];
    let confirmations = 0;
    let resolveFirstConfirmation: ((confirmed: boolean) => void) | undefined;
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      confirmBlockedScreenNavigation: () => {
        confirmations += 1;
        if (confirmations === 1) {
          return new Promise<boolean>((resolve) => {
            resolveFirstConfirmation = resolve;
          });
        }
        return Promise.resolve(true);
      },
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://allowed.example/next'),
      recoverCaptivePortalNavigation: (context) => {
        recoveryCalls.push(context);
        return Promise.resolve(true);
      },
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_NET_TIMEOUT',
        type: 'main_frame',
        tabId: 16,
        url: 'https://portal.example/login',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_NET_TIMEOUT',
        type: 'main_frame',
        tabId: 16,
        url: 'https://allowed.example/next',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.ok(resolveFirstConfirmation);
    resolveFirstConfirmation(false);
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(recoveryCalls, []);
    assert.deepEqual(redirects, [
      {
        tabId: 16,
        hostname: 'allowed.example',
        error: 'NS_ERROR_NET_TIMEOUT',
        origin: null,
      },
    ]);
  });

  void test('stale immediate blocked-screen navigation only handles the latest tab URL', async () => {
    const redirects: BlockedScreenContext[] = [];
    const recoveryCalls: unknown[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://allowed.example/next'),
      recoverCaptivePortalNavigation: (context) => {
        recoveryCalls.push(context);
        return Promise.resolve(false);
      },
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_UNKNOWN_HOST',
        type: 'main_frame',
        tabId: 17,
        url: 'https://portal.example/login',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_UNKNOWN_HOST',
        type: 'main_frame',
        tabId: 17,
        url: 'https://allowed.example/next',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(recoveryCalls, [
      {
        tabId: 17,
        hostname: 'allowed.example',
        error: 'NS_ERROR_UNKNOWN_HOST',
        origin: null,
        url: 'https://allowed.example/next',
      },
    ]);
    assert.deepEqual(redirects, [
      {
        tabId: 17,
        hostname: 'allowed.example',
        error: 'NS_ERROR_UNKNOWN_HOST',
        origin: null,
      },
    ]);
  });

  void test('stale native preflight does not redirect', async () => {
    const redirects: BlockedScreenContext[] = [];
    let confirmations = 0;
    let resolveFirstConfirmation: ((confirmed: boolean) => void) | undefined;
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      confirmBlockedScreenNavigation: () => {
        confirmations += 1;
        if (confirmations === 1) {
          return new Promise<boolean>((resolve) => {
            resolveFirstConfirmation = resolve;
          });
        }
        return Promise.resolve(true);
      },
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://allowed.example/next'),
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleNativePolicyNavigationPreflight({
      frameId: 0,
      tabId: 16,
      url: 'https://portal.example/login',
    });
    await new Promise((resolve) => setTimeout(resolve, 0));

    controller.handleNativePolicyNavigationPreflight({
      frameId: 0,
      tabId: 16,
      url: 'https://allowed.example/next',
    });
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.ok(resolveFirstConfirmation);
    resolveFirstConfirmation(false);
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(redirects, [
      {
        tabId: 16,
        hostname: 'allowed.example',
        error: 'OPENPATH_NATIVE_POLICY_BLOCKED',
        origin: null,
      },
    ]);
  });

  void test('captive portal recovery failure keeps unconfirmed refused connections off blocked screen', async () => {
    const redirects: BlockedScreenContext[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      confirmBlockedScreenNavigation: () => Promise.resolve(false),
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://portal.example/login'),
      recoverCaptivePortalNavigation: () => Promise.resolve(false),
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_CONNECTION_REFUSED',
        tabId: 14,
        type: 'main_frame',
        url: 'https://portal.example/login',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(redirects, []);
  });

  void test('native-confirmed timeout blocks without captive portal recovery', async () => {
    const redirects: BlockedScreenContext[] = [];
    const recoveryCalls: unknown[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://blocked.example/lesson'),
      recoverCaptivePortalNavigation: (context) => {
        recoveryCalls.push(context);
        return Promise.resolve(true);
      },
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_NET_TIMEOUT',
        tabId: 15,
        type: 'main_frame',
        url: 'https://blocked.example/lesson',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'main_frame' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(recoveryCalls, []);
    assert.deepEqual(redirects, [
      {
        tabId: 15,
        hostname: 'blocked.example',
        error: 'NS_ERROR_NET_TIMEOUT',
        origin: null,
      },
    ]);
  });

  void test('subresource errors never trigger blocked-screen redirects', async () => {
    const redirects: BlockedScreenContext[] = [];
    const recoveryCalls: unknown[] = [];
    const controller = createBlockedScreenNavigationController({
      addBlockedDomain: () => undefined,
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
      getBlockedScreenUrl: () => 'moz-extension://unit-test/blocked/blocked.html',
      getCurrentTabUrl: () => Promise.resolve('https://allowed.example/app'),
      recoverCaptivePortalNavigation: (context) => {
        recoveryCalls.push(context);
        return Promise.resolve(true);
      },
      redirectToBlockedScreen: (context) => {
        redirects.push(context);
        return Promise.resolve();
      },
    });

    controller.handleBlockedScreenNavigationError(
      {
        error: 'NS_ERROR_NET_TIMEOUT',
        originUrl: 'https://allowed.example/app',
        tabId: 3,
        type: 'xmlhttprequest',
        url: 'https://api.blocked.example/data.json',
      } as WebRequest.OnErrorOccurredDetailsType,
      { recordBlockedDomain: true, requestType: 'xmlhttprequest' }
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(redirects, []);
    assert.deepEqual(recoveryCalls, []);
  });
});
