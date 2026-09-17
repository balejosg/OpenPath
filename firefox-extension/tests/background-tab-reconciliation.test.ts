import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Tabs } from 'webextension-polyfill';

import {
  createBackgroundTabReconciliationController,
  WHITELIST_POLICY_REMOVED_REASON,
} from '../src/lib/background-tab-reconciliation.js';
import { createNavigationState } from '../src/lib/navigation-state.js';

function tab(id: number, url: string): Tabs.Tab {
  return { id, url } as unknown as Tabs.Tab;
}

function verify(results: { domain: string; inWhitelist: boolean }[]): Promise<{
  success: true;
  results: {
    domain: string;
    inWhitelist: boolean;
    policyActive: true;
    policyDecision: 'allowed' | 'blocked';
    policyReason: string;
    policyVersion: string;
  }[];
}> {
  return Promise.resolve({
    success: true as const,
    results: results.map((result) => ({
      ...result,
      policyActive: true as const,
      policyDecision: result.inWhitelist ? ('allowed' as const) : ('blocked' as const),
      policyReason: result.inWhitelist ? 'whitelist-domain' : 'default-deny',
      policyVersion: 'v1',
    })),
  });
}

void test('does not reconcile when policy version is unchanged', async () => {
  let queries = 0;
  const redirects: unknown[] = [];
  const controller = createBackgroundTabReconciliationController({
    getPolicyVersion: () => Promise.resolve({ success: true, version: 'v1' }),
    checkDomains: (domains) => verify(domains.map((d) => ({ domain: d, inWhitelist: false }))),
    queryTabs: () => {
      queries += 1;
      return Promise.resolve([tab(1, 'http://a.test/')]);
    },
    redirectToBlockedScreen: (r) => {
      redirects.push(r);
      return Promise.resolve();
    },
  });

  assert.strictEqual(await controller.refresh(true), true);
  const queriesAfterFirst = queries;
  assert.strictEqual(await controller.refresh(false), true);
  assert.strictEqual(queries, queriesAfterFirst);
});

void test('redirects open tabs whose host is no longer whitelisted', async () => {
  const redirects: unknown[] = [];
  const controller = createBackgroundTabReconciliationController({
    getPolicyVersion: () => Promise.resolve({ success: true, version: 'v1' }),
    checkDomains: (domains) =>
      verify(domains.map((d) => ({ domain: d, inWhitelist: d !== 'blocked.test' }))),
    queryTabs: () =>
      Promise.resolve([tab(11, 'https://blocked.test/page'), tab(12, 'https://allowed.test/ok')]),
    redirectToBlockedScreen: (r) => {
      redirects.push(r);
      return Promise.resolve();
    },
  });

  assert.strictEqual(await controller.refresh(true), true);
  assert.deepStrictEqual(redirects, [
    { tabId: 11, hostname: 'blocked.test', error: WHITELIST_POLICY_REMOVED_REASON },
  ]);
});

void test('does not redirect when all open hosts remain whitelisted', async () => {
  const redirects: unknown[] = [];
  const controller = createBackgroundTabReconciliationController({
    getPolicyVersion: () => Promise.resolve({ success: true, version: 'v1' }),
    checkDomains: (domains) => verify(domains.map((d) => ({ domain: d, inWhitelist: true }))),
    queryTabs: () => Promise.resolve([tab(21, 'https://allowed.test/')]),
    redirectToBlockedScreen: (r) => {
      redirects.push(r);
      return Promise.resolve();
    },
  });

  assert.strictEqual(await controller.refresh(true), true);
  assert.deepStrictEqual(redirects, []);
});

void test('skips reconciliation when policy version cannot be read', async () => {
  let checks = 0;
  const redirects: unknown[] = [];
  const controller = createBackgroundTabReconciliationController({
    getPolicyVersion: () => Promise.resolve({ success: false, error: 'native unavailable' }),
    checkDomains: () => {
      checks += 1;
      return verify([]);
    },
    queryTabs: () => Promise.resolve([tab(31, 'https://x.test/')]),
    redirectToBlockedScreen: (r) => {
      redirects.push(r);
      return Promise.resolve();
    },
  });

  assert.strictEqual(await controller.refresh(true), false);
  assert.strictEqual(checks, 0);
  assert.deepStrictEqual(redirects, []);
});

void test('does not advance version when host check fails', async () => {
  let checks = 0;
  const redirects: unknown[] = [];
  const controller = createBackgroundTabReconciliationController({
    getPolicyVersion: () => Promise.resolve({ success: true, version: 'v1' }),
    checkDomains: () => {
      checks += 1;
      return Promise.resolve({ success: false, results: [], error: 'native down' });
    },
    queryTabs: () => Promise.resolve([tab(41, 'https://y.test/')]),
    redirectToBlockedScreen: (r) => {
      redirects.push(r);
      return Promise.resolve();
    },
  });

  assert.strictEqual(await controller.refresh(false), false);
  assert.deepStrictEqual(redirects, []);
  assert.strictEqual(await controller.refresh(false), false);
  assert.strictEqual(checks, 2);
});

void test('ignores extension and non-http tabs', async () => {
  let checkedDomains: string[] | null = null;
  const redirects: unknown[] = [];
  const controller = createBackgroundTabReconciliationController({
    getPolicyVersion: () => Promise.resolve({ success: true, version: 'v1' }),
    checkDomains: (domains) => {
      checkedDomains = domains;
      return verify(domains.map((d) => ({ domain: d, inWhitelist: false })));
    },
    queryTabs: () =>
      Promise.resolve([
        tab(51, 'moz-extension://abc/blocked/blocked.html?domain=z.test'),
        tab(52, 'about:blank'),
        tab(53, 'https://real.test/page'),
      ]),
    redirectToBlockedScreen: (r) => {
      redirects.push(r);
      return Promise.resolve();
    },
  });

  assert.strictEqual(await controller.refresh(true), true);
  assert.deepStrictEqual(checkedDomains, ['real.test']);
  assert.deepStrictEqual(redirects, [
    { tabId: 53, hostname: 'real.test', error: WHITELIST_POLICY_REMOVED_REASON },
  ]);
});

void test('does not revive reconciliation after a same-URL navigation gets a new generation', async () => {
  const navigationState = createNavigationState();
  let resolveCheck!: (value: Awaited<ReturnType<typeof verify>>) => void;
  const pendingCheck = new Promise<Awaited<ReturnType<typeof verify>>>((resolve) => {
    resolveCheck = resolve;
  });
  const redirects: unknown[] = [];
  const url = 'https://blocked.test/repeated';
  const controller = createBackgroundTabReconciliationController({
    getPolicyVersion: () => Promise.resolve({ success: true, version: 'v1' }),
    checkDomains: () => pendingCheck,
    navigationState,
    queryTabs: () => Promise.resolve([tab(61, url)]),
    redirectToBlockedScreen: (redirect) => {
      redirects.push(redirect);
      return Promise.resolve();
    },
  });

  const refresh = controller.refresh(true);
  await new Promise<void>((resolve) => setImmediate(resolve));
  navigationState.begin(61, url, 'preflight');
  resolveCheck(await verify([{ domain: 'blocked.test', inWhitelist: false }]));

  assert.strictEqual(await refresh, true);
  assert.deepStrictEqual(redirects, []);
});

void test('shares redirect reservation with the active navigation coordinator', async () => {
  const navigationState = createNavigationState();
  const url = 'https://blocked.test/page';
  const identity = navigationState.begin(62, url, 'preflight');
  assert.strictEqual(navigationState.reserveRedirect(identity), true);
  const redirects: unknown[] = [];
  const controller = createBackgroundTabReconciliationController({
    getPolicyVersion: () => Promise.resolve({ success: true, version: 'v1' }),
    checkDomains: () => verify([{ domain: 'blocked.test', inWhitelist: false }]),
    navigationState,
    queryTabs: () => Promise.resolve([tab(62, url)]),
    redirectToBlockedScreen: (redirect) => {
      redirects.push(redirect);
      return Promise.resolve();
    },
  });

  assert.strictEqual(await controller.refresh(true), true);
  assert.deepStrictEqual(redirects, []);
});
