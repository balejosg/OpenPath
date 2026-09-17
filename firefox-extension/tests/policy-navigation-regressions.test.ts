import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Tabs } from 'webextension-polyfill';

import { createBackgroundTabReconciliationController } from '../src/lib/background-tab-reconciliation.js';
import { createBlockedScreenNavigationController } from '../src/lib/blocked-screen-navigation-controller.js';
import type { VerifyResponse } from '../src/lib/native-messaging-client.js';

const BLOCKED_URL = 'https://blocked.example/lesson';
const ALLOWED_404_URL = 'https://allowed.example/missing-page';
const BLOCKED_SCREEN = 'moz-extension://unit-test/blocked/blocked.html';

function tick(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

function navigationHarness(
  confirm: NonNullable<
    Parameters<typeof createBlockedScreenNavigationController>[0]['confirmBlockedScreenNavigation']
  >
): {
  controller: ReturnType<typeof createBlockedScreenNavigationController>;
  redirects: string[];
  navigate: (url: string) => void;
  error: (url: string) => void;
} {
  let currentUrl = BLOCKED_URL;
  const redirects: string[] = [];
  const controller = createBlockedScreenNavigationController({
    addBlockedDomain: () => undefined,
    confirmBlockedScreenNavigation: confirm,
    getBlockedScreenUrl: () => BLOCKED_SCREEN,
    getCurrentTabUrl: () => Promise.resolve(currentUrl),
    redirectToBlockedScreen: ({ hostname }) => {
      redirects.push(currentUrl);
      currentUrl = `${BLOCKED_SCREEN}?domain=${hostname}`;
      return Promise.resolve();
    },
  });

  return {
    controller,
    redirects,
    navigate(url: string): void {
      currentUrl = url;
      void controller.handleNativePolicyNavigationPreflight({ frameId: 0, tabId: 1, url });
    },
    error(url: string): void {
      void controller.handleBlockedScreenNavigationError(
        {
          error: 'NS_ERROR_UNKNOWN_HOST',
          frameId: 0,
          tabId: 1,
          type: 'main_frame',
          url,
        },
        { recordBlockedDomain: true, requestType: 'main_frame' }
      );
    },
  };
}

void test('REG-01: a repeated blocked URL gets one notice per navigation', async () => {
  const harness = navigationHarness((context) =>
    Promise.resolve(context.hostname === 'blocked.example')
  );
  harness.navigate(BLOCKED_URL);
  await tick();
  harness.navigate(ALLOWED_404_URL);
  await tick();
  harness.navigate(BLOCKED_URL);
  await tick();
  assert.equal(harness.redirects.length, 2);
});

void test('REG-02: an old confirmation cannot replace a newer allowed navigation', async () => {
  const old = deferred<boolean>();
  const harness = navigationHarness((context) =>
    context.error === 'OPENPATH_NATIVE_POLICY_BLOCKED' ? Promise.resolve(false) : old.promise
  );
  harness.error(BLOCKED_URL);
  await tick();
  harness.navigate(ALLOWED_404_URL);
  await tick();
  old.resolve(true);
  await tick();
  assert.equal(harness.redirects.length, 0);
});

void test('REG-03: an old error event cannot replace the current navigation', async () => {
  const harness = navigationHarness((context) =>
    Promise.resolve(context.hostname === 'blocked.example')
  );
  harness.navigate(ALLOWED_404_URL);
  await tick();
  harness.error(BLOCKED_URL);
  await tick();
  assert.equal(harness.redirects.length, 0);
});

void test('REG-04: preflight and error share a single redirect reservation', async () => {
  const pending: ReturnType<typeof deferred<boolean>>[] = [];
  const harness = navigationHarness(() => {
    const item = deferred<boolean>();
    pending.push(item);
    return item.promise;
  });
  harness.navigate(BLOCKED_URL);
  harness.error(BLOCKED_URL);
  await tick();
  assert.equal(pending.length, 1);
  pending[0]?.resolve(true);
  await tick();
  assert.equal(harness.redirects.length, 1);
});

void test('a failed redirect propagates and releases its navigation reservation', async () => {
  let attempts = 0;
  const controller = createBlockedScreenNavigationController({
    addBlockedDomain: () => undefined,
    confirmBlockedScreenNavigation: () => Promise.resolve(true),
    getCurrentTabUrl: () => Promise.resolve(BLOCKED_URL),
    redirectToBlockedScreen: () => {
      attempts += 1;
      return attempts === 1 ? Promise.reject(new Error('tabs.update failed')) : Promise.resolve();
    },
  });
  const details = { frameId: 0, tabId: 7, url: BLOCKED_URL };

  await assert.rejects(
    controller.handleNativePolicyNavigationPreflight(details),
    /tabs\.update failed/
  );
  await controller.handleBlockedScreenNavigationError(
    { ...details, error: 'NS_ERROR_UNKNOWN_HOST', type: 'main_frame' },
    { recordBlockedDomain: true, requestType: 'main_frame' }
  );

  assert.equal(attempts, 2);
});

function reconciliationHarness(checkDomains: () => Promise<VerifyResponse>): {
  controller: ReturnType<typeof createBackgroundTabReconciliationController>;
  redirects: string[];
  setUrl: (url: string) => void;
} {
  let currentUrl = BLOCKED_URL;
  const redirects: string[] = [];
  const controller = createBackgroundTabReconciliationController({
    getPolicyVersion: () => Promise.resolve({ success: true, version: 'policy-v1' }),
    checkDomains,
    queryTabs: () => Promise.resolve([{ id: 1, url: currentUrl } as Tabs.Tab]),
    getCurrentTabUrl: () => Promise.resolve(currentUrl),
    redirectToBlockedScreen: () => {
      redirects.push(currentUrl);
      currentUrl = `${BLOCKED_SCREEN}?domain=blocked.example`;
      return Promise.resolve();
    },
  });
  return {
    controller,
    redirects,
    setUrl: (url: string): void => {
      currentUrl = url;
    },
  };
}

void test('REG-05: reconciliation ignores an inactive policy', async () => {
  const harness = reconciliationHarness(() =>
    Promise.resolve({
      success: true,
      results: [
        {
          domain: 'blocked.example',
          inWhitelist: false,
          policyActive: false,
          policyDecision: 'blocked',
          policyReason: 'default-deny',
          policyVersion: 'policy-v1',
        },
      ],
    })
  );
  await harness.controller.refresh(true);
  assert.equal(harness.redirects.length, 0);
});

void test('REG-06: reconciliation ignores a per-domain verification error', async () => {
  const harness = reconciliationHarness(() =>
    Promise.resolve({
      success: true,
      results: [
        {
          domain: 'blocked.example',
          inWhitelist: false,
          policyActive: true,
          policyDecision: 'blocked',
          policyReason: 'default-deny',
          policyVersion: 'policy-v1',
          error: 'policy-read-failed',
        },
      ],
    })
  );
  await harness.controller.refresh(true);
  assert.equal(harness.redirects.length, 0);
});

void test('REG-07: reconciliation revalidates a tab after the native check', async () => {
  const response = deferred<VerifyResponse>();
  const harness = reconciliationHarness(() => response.promise);
  const refresh = harness.controller.refresh(true);
  await tick();
  harness.setUrl(ALLOWED_404_URL);
  response.resolve({
    success: true,
    results: [
      {
        domain: 'blocked.example',
        inWhitelist: false,
        policyActive: true,
        policyDecision: 'blocked',
        policyReason: 'default-deny',
        policyVersion: 'policy-v1',
      },
    ],
  });
  await refresh;
  assert.equal(harness.redirects.length, 0);
});
