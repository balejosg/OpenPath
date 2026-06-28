import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Browser } from 'webextension-polyfill';

import { createBackgroundRuntime } from '../src/lib/background-runtime.js';
import { createCaptivePortalRecoveryController } from '../src/lib/captive-portal-recovery-controller.js';

type RuntimeMessageListener = (
  message: unknown,
  sender: unknown,
  sendResponse: (response: unknown) => void
) => unknown;

function waitForAsyncRuntime(): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
}

function waitForCaptivePortalRecoveryRetry(): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, 800);
  });
}

function createRuntimeHarness(): {
  browser: Browser;
  fetchBodies: unknown[];
  nativeMessages: unknown[];
  pathRuleRefreshes: number;
  subdomainRuleRefreshes: number;
  responses: unknown[];
  restoreGlobals: () => void;
  runtimeMessage: RuntimeMessageListener | null;
  tabRemovedListener: ((tabId: number) => void) | null;
  captivePortalConnectivityListener: (() => void) | null;
  captivePortalStateChangedListener: ((details: { state: string }) => void) | null;
  webRequestBeforeRequestListener: ((details: unknown) => unknown) | null;
  webRequestErrorListener: ((details: unknown) => unknown) | null;
} {
  return createRuntimeHarnessWithOptions({});
}

function createRuntimeHarnessWithOptions(options: {
  blockedPaths?: string[];
  captivePortalState?: string;
  nativeMessageResponder?: (message: unknown) => unknown;
  openTabs?: { id: number; url: string }[];
}): {
  browser: Browser;
  fetchBodies: unknown[];
  nativeMessages: unknown[];
  pathRuleRefreshes: number;
  subdomainRuleRefreshes: number;
  tabUpdates: { tabId: number; update: { url?: string } }[];
  responses: unknown[];
  restoreGlobals: () => void;
  runtimeMessage: RuntimeMessageListener | null;
  tabRemovedListener: ((tabId: number) => void) | null;
  captivePortalConnectivityListener: (() => void) | null;
  captivePortalStateChangedListener: ((details: { state: string }) => void) | null;
  webRequestBeforeRequestListener: ((details: unknown) => unknown) | null;
  webRequestErrorListener: ((details: unknown) => unknown) | null;
} {
  const nativeMessages: unknown[] = [];
  const fetchBodies: unknown[] = [];
  const responses: unknown[] = [];
  const tabUpdates: { tabId: number; update: { url?: string } }[] = [];
  let runtimeMessage: RuntimeMessageListener | null = null;
  let tabRemovedListener: ((tabId: number) => void) | null = null;
  let webRequestBeforeRequestListener: ((details: unknown) => unknown) | null = null;
  let webRequestErrorListener: ((details: unknown) => unknown) | null = null;
  let captivePortalConnectivityListener: (() => void) | null = null;
  let captivePortalStateChangedListener: ((details: { state: string }) => void) | null = null;
  let pathRuleRefreshes = 0;
  let subdomainRuleRefreshes = 0;
  const originalBrowser = (globalThis as { browser?: Browser }).browser;
  const originalFetch = globalThis.fetch;
  const originalSetInterval = globalThis.setInterval;
  const browser = {
    action: {
      setBadgeBackgroundColor: () => Promise.resolve(),
      setBadgeText: () => Promise.resolve(),
    },
    captivePortal: {
      getState: () => Promise.resolve(options.captivePortalState ?? 'locked_portal'),
      onConnectivityAvailable: {
        addListener: (listener: () => void) => {
          captivePortalConnectivityListener = listener;
        },
      },
      onStateChanged: {
        addListener: (listener: (details: { state: string }) => void) => {
          captivePortalStateChangedListener = listener;
        },
      },
    },
    runtime: {
      connectNative: () =>
        ({
          onDisconnect: {
            addListener: () => undefined,
          },
        }) as never,
      getManifest: () => ({ version: '2.0.0-test' }),
      getURL: (path: string) => `moz-extension://unit-test/${path.replace(/^\/+/, '')}`,
      lastError: undefined,
      onMessage: {
        addListener: (listener: RuntimeMessageListener) => {
          runtimeMessage = listener;
        },
      },
      sendNativeMessage: (_hostName: string, message: unknown) => {
        nativeMessages.push(message);
        const customResponse = options.nativeMessageResponder?.(message);
        if (customResponse !== undefined) {
          return Promise.resolve(customResponse);
        }
        const action = (message as { action?: string }).action;
        if (action === 'get-config') {
          return Promise.resolve({
            success: true,
            requestApiUrl: 'https://api.example',
            fallbackApiUrls: [],
          });
        }
        if (action === 'get-blocked-paths') {
          pathRuleRefreshes += 1;
          return Promise.resolve({
            success: true,
            paths: options.blockedPaths ?? [],
            count: 0,
            hash: '',
            mtime: pathRuleRefreshes,
          });
        }
        if (action === 'get-blocked-subdomains') {
          subdomainRuleRefreshes += 1;
          return Promise.resolve({
            success: true,
            subdomains: [],
            count: 0,
            hash: '',
            mtime: subdomainRuleRefreshes,
          });
        }
        if (action === 'get-hostname') {
          return Promise.resolve({ success: true, hostname: 'lab-pc-01' });
        }
        if (action === 'get-machine-token') {
          return Promise.resolve({ success: true, token: 'machine-token' });
        }
        if (action === 'update-whitelist') {
          return Promise.resolve({ success: true, action: 'update-whitelist' });
        }
        if (action === 'ping') {
          return Promise.resolve({ success: true });
        }
        if (action === 'check') {
          return Promise.resolve({
            success: true,
            results: ((message as { domains?: string[] }).domains ?? []).map((domain) => ({
              domain,
              in_whitelist: false,
              policy_active: true,
              resolves: true,
            })),
          });
        }
        if (action === 'get-policy-version') {
          return Promise.resolve({ success: true, version: 'policy-v1' });
        }

        return Promise.resolve({ success: true });
      },
    },
    storage: {
      local: {
        get: () => Promise.resolve({}),
        set: () => Promise.resolve(),
      },
      sync: {
        get: () => Promise.resolve({}),
      },
    },
    tabs: {
      get: () => Promise.resolve({ id: 5, url: 'http://portal.example/app' }),
      query: () => Promise.resolve(options.openTabs ?? []),
      onRemoved: {
        addListener: (listener: (tabId: number) => void) => {
          tabRemovedListener = listener;
        },
      },
      update: (tabId: number, update: { url?: string }) => {
        tabUpdates.push({ tabId, update });
        return Promise.resolve({});
      },
    },
    webNavigation: {
      onBeforeNavigate: {
        addListener: () => undefined,
      },
      onErrorOccurred: {
        addListener: (listener: (details: unknown) => unknown) => {
          webRequestErrorListener = listener;
        },
      },
    },
    webRequest: {
      onBeforeRequest: {
        addListener: (listener: (details: unknown) => unknown) => {
          webRequestBeforeRequestListener = listener;
        },
      },
      onErrorOccurred: {
        addListener: () => undefined,
      },
    },
  } as unknown as Browser;

  Object.assign(globalThis, {
    browser,
    fetch: (_url: string, init?: RequestInit) => {
      const body: unknown = typeof init?.body === 'string' ? JSON.parse(init.body) : {};
      fetchBodies.push(body);
      return Promise.resolve(
        new Response(JSON.stringify({ success: true, status: 'approved' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      );
    },
    setInterval: (() => 0) as unknown as typeof setInterval,
  });

  return {
    browser,
    fetchBodies,
    nativeMessages,
    get pathRuleRefreshes(): number {
      return pathRuleRefreshes;
    },
    get subdomainRuleRefreshes(): number {
      return subdomainRuleRefreshes;
    },
    tabUpdates,
    responses,
    restoreGlobals: (): void => {
      Object.assign(globalThis, {
        browser: originalBrowser,
        fetch: originalFetch,
        setInterval: originalSetInterval,
      });
    },
    get runtimeMessage(): RuntimeMessageListener | null {
      return runtimeMessage;
    },
    get tabRemovedListener(): ((tabId: number) => void) | null {
      return tabRemovedListener;
    },
    get webRequestBeforeRequestListener(): ((details: unknown) => unknown) | null {
      return webRequestBeforeRequestListener;
    },
    get webRequestErrorListener(): ((details: unknown) => unknown) | null {
      return webRequestErrorListener;
    },
    get captivePortalConnectivityListener(): (() => void) | null {
      return captivePortalConnectivityListener;
    },
    get captivePortalStateChangedListener(): ((details: { state: string }) => void) | null {
      return captivePortalStateChangedListener;
    },
  };
}

void test('background runtime skips captive portal retry when recovery resolves after a newer navigation error', async () => {
  let resolveOldRecovery!: (value: unknown) => void;
  const oldRecovery = new Promise<unknown>((resolve) => {
    resolveOldRecovery = resolve;
  });
  const harness = createRuntimeHarnessWithOptions({
    nativeMessageResponder: (message) => {
      const action = (message as { action?: string }).action;
      if (action === 'check') {
        return {
          success: true,
          results: ((message as { domains?: string[] }).domains ?? []).map((domain) => ({
            domain,
            in_whitelist: false,
            policy_active: true,
            portal_recovery_eligible: true,
            resolves: false,
          })),
        };
      }
      if (action !== 'recover-captive-portal-navigation') {
        return undefined;
      }
      return (message as { triggerHost?: string }).triggerHost === 'old.example'
        ? oldRecovery
        : { success: false };
    },
  });
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.webRequestErrorListener);

    harness.webRequestErrorListener({
      error: 'NS_ERROR_UNKNOWN_HOST',
      frameId: 0,
      requestId: 'old-request',
      tabId: 5,
      type: 'main_frame',
      url: 'https://old.example/login',
    });
    await waitForAsyncRuntime();
    harness.webRequestErrorListener({
      error: 'NS_ERROR_UNKNOWN_HOST',
      frameId: 0,
      requestId: 'new-request',
      tabId: 5,
      type: 'main_frame',
      url: 'https://new.example/login',
    });
    await waitForAsyncRuntime();

    resolveOldRecovery({ success: true });
    await waitForAsyncRuntime();

    assert.equal(
      harness.tabUpdates.some((update) => update.update.url === 'https://old.example/login'),
      false
    );
    assert.deepEqual(harness.tabUpdates, [
      {
        tabId: 5,
        update: {
          url: 'moz-extension://unit-test/blocked/blocked.html?domain=new.example&error=NS_ERROR_UNKNOWN_HOST',
        },
      },
    ]);
  } finally {
    harness.restoreGlobals();
  }
});

void test('captive portal recovery controller gates native open on locked portal and resets limiter on state changes', async () => {
  let now = 10_000;
  let portalState = 'locked_portal';
  const recoveries: unknown[] = [];
  const reconciles: unknown[] = [];
  const tabUpdates: unknown[] = [];
  const controller = createCaptivePortalRecoveryController({
    getPortalState: () => Promise.resolve(portalState),
    logger: { info: () => undefined },
    now: () => now,
    recoverCaptivePortalNavigation: (input) => {
      if (input.operation === 'reconcile') {
        reconciles.push(input);
      } else {
        recoveries.push(input);
      }
      return Promise.resolve({ success: true });
    },
    retryNavigation: (tabId, url) => {
      tabUpdates.push({ tabId, url });
      return Promise.resolve();
    },
    sleep: () => Promise.resolve(),
  });

  assert.equal(
    await controller.recoverNavigation({
      tabId: 5,
      hostname: 'portal.example',
      url: 'https://portal.example/login',
    }),
    true
  );
  assert.equal(
    await controller.recoverNavigation({
      tabId: 5,
      hostname: 'portal.example',
      url: 'https://portal.example/login',
    }),
    false
  );

  portalState = 'not_captive';
  await controller.handlePortalStateChanged('not_captive');
  now += 1;
  portalState = 'locked_portal';

  assert.equal(
    await controller.recoverNavigation({
      tabId: 5,
      hostname: 'portal.example',
      url: 'https://portal.example/login',
    }),
    true
  );

  assert.deepEqual(recoveries, [
    { portalState: 'locked_portal', triggerHost: 'portal.example', tabId: 5 },
    { portalState: 'locked_portal', triggerHost: 'portal.example', tabId: 5 },
  ]);
  assert.deepEqual(reconciles, [
    {
      operation: 'reconcile',
      portalState: 'not_captive',
      source: 'firefox-captivePortal:state-changed',
    },
  ]);
  assert.deepEqual(tabUpdates, [
    { tabId: 5, url: 'https://portal.example/login' },
    { tabId: 5, url: 'https://portal.example/login' },
  ]);
});

void test('background runtime leaves allowed unknown-host navigations on the browser network page', async () => {
  const harness = createRuntimeHarnessWithOptions({
    captivePortalState: 'not_captive_portal',
    nativeMessageResponder: (message) => {
      if ((message as { action?: string }).action !== 'check') {
        return undefined;
      }
      return {
        success: true,
        results: ((message as { domains?: string[] }).domains ?? []).map((domain) => ({
          domain,
          in_whitelist: true,
          policy_active: true,
          portal_recovery_eligible: false,
          resolves: false,
        })),
      };
    },
  });
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.webRequestErrorListener);

    harness.webRequestErrorListener({
      error: 'NS_ERROR_UNKNOWN_HOST',
      frameId: 0,
      requestId: 'allowed-request',
      tabId: 5,
      type: 'main_frame',
      url: 'https://allowed.example/lesson',
    });
    await waitForAsyncRuntime();

    assert.deepEqual(harness.tabUpdates, []);
    assert.ok(
      harness.nativeMessages.some(
        (message) =>
          (message as { action?: string; domains?: string[] }).action === 'check' &&
          (message as { domains?: string[] }).domains?.includes('allowed.example') === true
      )
    );
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime gates portal-eligible recovery on locked portal state', async () => {
  const harness = createRuntimeHarnessWithOptions({
    captivePortalState: 'not_captive',
    nativeMessageResponder: (message) => {
      if ((message as { action?: string }).action === 'check') {
        return {
          success: true,
          results: [
            {
              domain: 'portal.example',
              in_whitelist: false,
              policy_active: true,
              portal_recovery_eligible: true,
              resolves: false,
            },
          ],
        };
      }
      return undefined;
    },
  });
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.webRequestErrorListener);

    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'portal-request',
      tabId: 5,
      type: 'main_frame',
      url: 'https://portal.example/login',
    });
    await waitForAsyncRuntime();

    assert.equal(
      harness.nativeMessages.some(
        (message) => (message as { action?: string }).action === 'recover-captive-portal-navigation'
      ),
      false
    );
    assert.deepEqual(harness.tabUpdates, [
      {
        tabId: 5,
        update: {
          url: 'moz-extension://unit-test/blocked/blocked.html?domain=portal.example&error=NS_ERROR_NET_TIMEOUT',
        },
      },
    ]);
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime recovers portal-eligible native-confirmed blocks before redirect', async () => {
  const harness = createRuntimeHarnessWithOptions({
    captivePortalState: 'locked_portal',
    nativeMessageResponder: (message) => {
      if ((message as { action?: string }).action === 'check') {
        return {
          success: true,
          results: [
            {
              domain: 'portal.example',
              in_whitelist: false,
              policy_active: true,
              portal_recovery_eligible: true,
              resolves: false,
            },
          ],
        };
      }
      return undefined;
    },
  });
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.webRequestErrorListener);

    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'portal-request',
      tabId: 5,
      type: 'main_frame',
      url: 'https://portal.example/login',
    });
    await waitForAsyncRuntime();
    await waitForCaptivePortalRecoveryRetry();

    assert.ok(
      harness.nativeMessages.some(
        (message) =>
          (message as { action?: string; triggerHost?: string }).action ===
            'recover-captive-portal-navigation' &&
          (message as { triggerHost?: string }).triggerHost === 'portal.example'
      )
    );
    assert.deepEqual(harness.tabUpdates, [
      {
        tabId: 5,
        update: { url: 'https://portal.example/login' },
      },
    ]);
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime reconciles native recovery on captive portal connectivity events', async () => {
  const harness = createRuntimeHarnessWithOptions({});
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.captivePortalConnectivityListener);
    assert.ok(harness.captivePortalStateChangedListener);

    harness.captivePortalConnectivityListener();
    harness.captivePortalStateChangedListener({ state: 'not_captive' });
    await waitForAsyncRuntime();

    assert.deepEqual(
      harness.nativeMessages.filter(
        (message) => (message as { operation?: string }).operation === 'reconcile'
      ),
      [
        {
          action: 'recover-captive-portal-navigation',
          operation: 'reconcile',
          portalState: 'Unknown',
          source: 'firefox-captivePortal:connectivity-available',
        },
        {
          action: 'recover-captive-portal-navigation',
          operation: 'reconcile',
          portalState: 'not_captive',
          source: 'firefox-captivePortal:state-changed',
        },
      ]
    );
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime resets captive portal retry limiter on portal state changes', async () => {
  let captivePortalState = 'locked_portal';
  const harness = createRuntimeHarnessWithOptions({
    nativeMessageResponder: (message) => {
      if ((message as { action?: string }).action === 'check') {
        return {
          success: true,
          results: [
            {
              domain: 'portal.example',
              in_whitelist: false,
              policy_active: true,
              portal_recovery_eligible: true,
              resolves: false,
            },
          ],
        };
      }
      return undefined;
    },
  });
  (
    harness.browser as unknown as { captivePortal: { getState: () => Promise<string> } }
  ).captivePortal.getState = (): Promise<string> => Promise.resolve(captivePortalState);
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.webRequestErrorListener);
    assert.ok(harness.captivePortalStateChangedListener);

    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'first',
      tabId: 5,
      type: 'main_frame',
      url: 'https://portal.example/login',
    });
    await waitForAsyncRuntime();
    captivePortalState = 'unknown';
    harness.captivePortalStateChangedListener({ state: 'unknown' });
    captivePortalState = 'locked_portal';
    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'third',
      tabId: 5,
      type: 'main_frame',
      url: 'https://portal.example/login',
    });
    await waitForAsyncRuntime();

    assert.equal(
      harness.nativeMessages.filter(
        (message) =>
          (message as { action?: string; operation?: string }).action ===
            'recover-captive-portal-navigation' &&
          (message as { operation?: string }).operation === 'open'
      ).length,
      2
    );
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime keeps manual local update retry through native whitelist updates', async () => {
  const harness = createRuntimeHarness();
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.runtimeMessage);

    harness.runtimeMessage(
      {
        action: 'retryLocalUpdate',
        hostname: 'api.portal-cdn.example',
        tabId: 5,
      },
      { tab: { id: 5, url: 'http://portal.example/fallback' } },
      (response) => {
        harness.responses.push(response);
      }
    );
    await waitForAsyncRuntime();

    assert.deepEqual(harness.responses, [{ success: true }]);
    assert.equal(harness.fetchBodies.length, 0);
    assert.ok(
      harness.nativeMessages.some(
        (message) =>
          (message as { action?: string }).action === 'update-whitelist' &&
          ((message as { domains?: string[] }).domains ?? []).includes('api.portal-cdn.example')
      )
    );
    assert.equal(harness.pathRuleRefreshes >= 2, true);
    assert.equal(harness.subdomainRuleRefreshes >= 2, true);
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime exposes native diagnostics through runtime messages', async () => {
  const harness = createRuntimeHarness();
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.runtimeMessage);

    harness.runtimeMessage(
      {
        action: 'getOpenPathDiagnostics',
        domains: [' Example.COM ', ''],
      },
      { tab: { id: 5 } },
      (response) => {
        harness.responses.push(response);
      }
    );
    await waitForAsyncRuntime();

    const diagnostics = harness.responses[0] as {
      extensionOrigin?: string;
      manifestVersion?: string;
      nativeAvailable?: boolean;
      nativeBlockedPaths?: { success?: boolean };
      nativeBlockedSubdomains?: { success?: boolean };
      nativeCheck?: { results?: { domain?: string; resolves?: boolean }[] };
      nativeRequestConfig?: {
        enabled?: boolean;
        endpointCount?: number;
        nativeEndpointCount?: number;
        valid?: boolean;
      };
      pathRules?: { count?: number; success?: boolean };
      subdomainRules?: { count?: number; success?: boolean };
      success?: boolean;
    };
    assert.equal(diagnostics.success, true);
    assert.equal(diagnostics.extensionOrigin, 'moz-extension://unit-test/');
    assert.equal(diagnostics.manifestVersion, '2.0.0-test');
    assert.equal(diagnostics.nativeAvailable, true);
    assert.deepEqual(diagnostics.nativeCheck?.results, [
      {
        domain: 'example.com',
        inWhitelist: false,
        policyActive: true,
        resolves: true,
      },
    ]);
    assert.equal(diagnostics.nativeBlockedPaths?.success, true);
    assert.equal(diagnostics.nativeBlockedSubdomains?.success, true);
    assert.deepEqual(diagnostics.nativeRequestConfig, {
      nativeEndpointCount: 1,
      endpointCount: 1,
      enabled: true,
      valid: true,
    });
    assert.equal(diagnostics.pathRules?.success, true);
    assert.equal(diagnostics.pathRules.count, 0);
    assert.equal(diagnostics.subdomainRules?.success, true);
    assert.equal(diagnostics.subdomainRules.count, 0);
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime refreshes path rules after manual native whitelist updates', async () => {
  const harness = createRuntimeHarness();
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.runtimeMessage);

    harness.runtimeMessage(
      { action: 'triggerWhitelistUpdate', domains: ['wikipedia.org'] },
      { tab: { id: 5 } },
      (response) => {
        harness.responses.push(response);
      }
    );
    await waitForAsyncRuntime();

    assert.deepEqual(harness.responses, [{ success: true, action: 'update-whitelist' }]);
    assert.ok(
      harness.nativeMessages.some(
        (message) =>
          (message as { action?: string; domains?: string[] }).action === 'update-whitelist' &&
          (message as { domains?: string[] }).domains?.[0] === 'wikipedia.org'
      )
    );
    assert.equal(harness.pathRuleRefreshes >= 2, true);
    assert.equal(harness.subdomainRuleRefreshes >= 2, true);
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime submits blocked-domain requests through native config', async () => {
  const harness = createRuntimeHarness();
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.runtimeMessage);

    harness.runtimeMessage(
      {
        action: 'submitBlockedDomainRequest',
        domain: 'blocked.example',
        reason: 'Teacher approved lesson resource',
        origin: 'https://classroom.example/activity',
        error: 'BLOCKED_PATH_POLICY:blocked.example/private',
      },
      { tab: { id: 5 } },
      (response) => {
        harness.responses.push(response);
      }
    );
    await waitForAsyncRuntime();

    assert.deepEqual(harness.responses, [{ success: true, status: 'approved' }]);
    assert.equal(harness.fetchBodies.length, 1);
    assert.deepEqual(harness.fetchBodies[0], {
      client_version: '2.0.0-test',
      domain: 'blocked.example',
      error_type: 'BLOCKED_PATH_POLICY:blocked.example/private',
      hostname: 'lab-pc-01',
      origin_host: 'https://classroom.example/activity',
      reason: 'Teacher approved lesson resource',
      token: 'machine-token',
    });
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime preserves blocked original URLs in background state', async () => {
  const harness = createRuntimeHarnessWithOptions({
    blockedPaths: ['blocked.example/private'],
  });
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.runtimeMessage);
    assert.ok(harness.webRequestBeforeRequestListener);

    const outcome = harness.webRequestBeforeRequestListener({
      documentUrl: 'https://classroom.example/activity',
      frameId: 0,
      originUrl: 'https://classroom.example/activity',
      requestId: 'request-1',
      tabId: 5,
      type: 'main_frame',
      url: 'https://blocked.example/private/page?student=1',
    });
    assert.ok(outcome && typeof outcome === 'object' && 'redirectUrl' in outcome);
    const redirectUrl = new URL((outcome as { redirectUrl: string }).redirectUrl);
    assert.equal(redirectUrl.searchParams.get('domain'), 'blocked.example');
    assert.equal(redirectUrl.searchParams.has('url'), false);

    harness.runtimeMessage(
      { action: 'getBlockedPageContext', domain: 'blocked.example' },
      { tab: { id: 5 } },
      (response) => {
        harness.responses.push(response);
      }
    );
    await waitForAsyncRuntime();
    assert.deepEqual(harness.responses[0], {
      success: true,
      context: {
        domain: 'blocked.example',
        originalUrl: 'https://blocked.example/private/page?student=1',
      },
    });

    assert.ok(harness.tabRemovedListener);
    harness.tabRemovedListener(5);
  } finally {
    harness.restoreGlobals();
  }
});

// A native responder that confirms `blocked.example` (and any checked domain) as a policy block:
// not whitelisted, policy active, does not resolve to a real IP.
function respondWithConfirmedBlock(message: unknown): unknown {
  if ((message as { action?: string }).action !== 'check') {
    return undefined;
  }
  return {
    success: true,
    results: ((message as { domains?: string[] }).domains ?? []).map((domain) => ({
      domain,
      in_whitelist: false,
      policy_active: true,
      resolves: false,
    })),
  };
}

function countNativeChecks(nativeMessages: unknown[], domain: string): number {
  return nativeMessages.filter(
    (message) =>
      (message as { action?: string }).action === 'check' &&
      ((message as { domains?: string[] }).domains ?? []).includes(domain)
  ).length;
}

void test('background runtime serves a repeat blocked navigation from the decision cache without a second native check', async () => {
  const harness = createRuntimeHarnessWithOptions({
    captivePortalState: 'not_captive_portal',
    nativeMessageResponder: respondWithConfirmedBlock,
  });
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.webRequestErrorListener);

    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'first',
      tabId: 5,
      type: 'main_frame',
      url: 'https://blocked.example/a',
    });
    await waitForAsyncRuntime();

    assert.equal(countNativeChecks(harness.nativeMessages, 'blocked.example'), 1);
    assert.equal(harness.tabUpdates.length, 1);

    // Different tab and URL (so the per-tab redirect dedup does not apply), same host.
    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'second',
      tabId: 6,
      type: 'main_frame',
      url: 'https://blocked.example/b',
    });
    await waitForAsyncRuntime();

    // Still redirects to the blocked screen, but reuses the cached decision — no extra native check.
    assert.equal(countNativeChecks(harness.nativeMessages, 'blocked.example'), 1);
    assert.equal(harness.tabUpdates.length, 2);
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime re-checks a blocked host after the decision cache TTL expires', async () => {
  let currentNow = 1000;
  const harness = createRuntimeHarnessWithOptions({
    captivePortalState: 'not_captive_portal',
    nativeMessageResponder: respondWithConfirmedBlock,
  });
  try {
    const runtime = createBackgroundRuntime(harness.browser, { now: () => currentNow });
    await runtime.init();
    assert.ok(harness.webRequestErrorListener);

    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'first',
      tabId: 5,
      type: 'main_frame',
      url: 'https://blocked.example/a',
    });
    await waitForAsyncRuntime();
    assert.equal(countNativeChecks(harness.nativeMessages, 'blocked.example'), 1);

    // Advance past the 5s decision TTL.
    currentNow = 1000 + 6000;

    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'second',
      tabId: 6,
      type: 'main_frame',
      url: 'https://blocked.example/b',
    });
    await waitForAsyncRuntime();
    assert.equal(countNativeChecks(harness.nativeMessages, 'blocked.example'), 2);
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime drops cached block decisions after a whitelist update', async () => {
  const harness = createRuntimeHarnessWithOptions({
    captivePortalState: 'not_captive_portal',
    nativeMessageResponder: respondWithConfirmedBlock,
  });
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    assert.ok(harness.webRequestErrorListener);
    assert.ok(harness.runtimeMessage);

    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'first',
      tabId: 5,
      type: 'main_frame',
      url: 'https://blocked.example/a',
    });
    await waitForAsyncRuntime();
    assert.equal(countNativeChecks(harness.nativeMessages, 'blocked.example'), 1);

    harness.runtimeMessage(
      { action: 'triggerWhitelistUpdate', domains: ['blocked.example'] },
      { tab: { id: 5 } },
      (response) => {
        harness.responses.push(response);
      }
    );
    await waitForAsyncRuntime();

    // The cache was invalidated by the whitelist update, so the host is confirmed again.
    harness.webRequestErrorListener({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      requestId: 'second',
      tabId: 6,
      type: 'main_frame',
      url: 'https://blocked.example/b',
    });
    await waitForAsyncRuntime();
    assert.equal(countNativeChecks(harness.nativeMessages, 'blocked.example'), 2);
  } finally {
    harness.restoreGlobals();
  }
});

void test('background runtime redirects already-open tabs when policy removes their host', async () => {
  const harness = createRuntimeHarnessWithOptions({
    openTabs: [{ id: 7, url: 'http://blocked.example/page' }],
  });
  try {
    const runtime = createBackgroundRuntime(harness.browser);
    await runtime.init();
    await waitForAsyncRuntime();

    assert.deepEqual(
      harness.tabUpdates.filter((update) => update.tabId === 7),
      [
        {
          tabId: 7,
          update: {
            url: 'moz-extension://unit-test/blocked/blocked.html?domain=blocked.example&error=POLICY_BLOCKED',
          },
        },
      ]
    );
  } finally {
    harness.restoreGlobals();
  }
});
