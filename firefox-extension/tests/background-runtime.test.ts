import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Browser } from 'webextension-polyfill';

import {
  createBackgroundRuntime,
  isNativePolicyBlockedResult,
} from '../src/lib/background-runtime.js';

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
  webRequestBeforeRequestListener: ((details: unknown) => unknown) | null;
  webRequestErrorListener: ((details: unknown) => unknown) | null;
} {
  return createRuntimeHarnessWithOptions({});
}

function createRuntimeHarnessWithOptions(options: {
  blockedPaths?: string[];
  nativeMessageResponder?: (message: unknown) => unknown;
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
  };
}

void test('native policy confirmation ignores fail-open or inactive policy results', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'portal.fixture.test',
      inWhitelist: false,
      policyActive: false,
      resolves: false,
    }),
    false
  );
});

void test('native policy confirmation treats missing policy state as unknown, not inactive', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'legacy-native-host.example',
      inWhitelist: false,
      resolves: false,
    }),
    true
  );
});

void test('native policy confirmation ignores errored native check results', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'broken-native-host.example',
      error: 'OpenPath whitelist command not found',
      inWhitelist: false,
      policyActive: true,
      resolves: false,
    }),
    false
  );
});

void test('native policy confirmation requires a denied domain that does not resolve publicly', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'blocked.example',
      inWhitelist: false,
      policyActive: true,
      resolves: false,
    }),
    true
  );
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'allowed.example',
      inWhitelist: false,
      policyActive: true,
      resolves: true,
    }),
    false
  );
});

void test('native policy confirmation treats null resolvedIp as unresolved', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'legacy-null-ip.example',
      inWhitelist: false,
      policyActive: true,
      resolvedIp: null,
    } as unknown as Parameters<typeof isNativePolicyBlockedResult>[0]),
    true
  );
});

void test('background runtime skips captive portal retry when recovery resolves after a newer navigation error', async () => {
  let resolveOldRecovery!: (value: unknown) => void;
  const oldRecovery = new Promise<unknown>((resolve) => {
    resolveOldRecovery = resolve;
  });
  const harness = createRuntimeHarnessWithOptions({
    nativeMessageResponder: (message) => {
      if ((message as { action?: string }).action !== 'recover-captive-portal-navigation') {
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
