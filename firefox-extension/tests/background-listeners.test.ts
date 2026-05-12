import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import type { Browser, WebRequest } from 'webextension-polyfill';

import { registerBackgroundListeners } from '../src/lib/background-listeners.js';

interface BlockedScreenContext {
  tabId: number;
  hostname: string;
  error: string;
  origin: string | null;
}

interface ConfirmBlockedScreenContext extends BlockedScreenContext {
  url: string;
}

type WebRequestErrorListener = (details: WebRequest.OnErrorOccurredDetailsType) => void;
type WebRequestBeforeListener = (details: WebRequest.OnBeforeRequestDetailsType) => unknown;
type EvaluateBlockedPath = Parameters<typeof registerBackgroundListeners>[0]['evaluateBlockedPath'];
type EvaluateBlockedSubdomain = Parameters<
  typeof registerBackgroundListeners
>[0]['evaluateBlockedSubdomain'];
type WebNavigationBeforeListener = (details: {
  frameId: number;
  tabId: number;
  url: string;
}) => void;
type WebNavigationErrorListener = (details: {
  error: string;
  frameId: number;
  tabId: number;
  url: string;
}) => void;

function waitForAsyncListeners(): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
}

function createListenerHarness(
  options: {
    confirmBlockedScreenNavigation?: (context: ConfirmBlockedScreenContext) => Promise<boolean>;
    currentTabUrl?: string | null;
    evaluateBlockedPath?: EvaluateBlockedPath;
    evaluateBlockedSubdomain?: EvaluateBlockedSubdomain;
    handleRuntimeMessage?: (message: unknown, sender: unknown) => unknown;
    allowLocalRuntimeDependency?: (input: {
      anchorHost: string;
      dependencyHost: string;
      requestType: string;
    }) => Promise<unknown>;
    recordDependencyObservationEvent?: Parameters<
      typeof registerBackgroundListeners
    >[0]['recordDependencyObservationEvent'];
  } = {}
): {
  addedBlocks: BlockedScreenContext[];
  autoAllowCalls: unknown[];
  localRuntimeDependencyCalls: unknown[];
  beforeRequestFilters: unknown[];
  confirmCalls: ConfirmBlockedScreenContext[];
  redirects: BlockedScreenContext[];
  runtimeMessage:
    | ((message: unknown, sender: unknown, sendResponse: (response: unknown) => void) => unknown)
    | null;
  webRequestBefore: WebRequestBeforeListener | null;
  webNavigationBefore: WebNavigationBeforeListener | null;
  webNavigationError: WebNavigationErrorListener | null;
  webRequestError: WebRequestErrorListener | null;
} {
  const addedBlocks: BlockedScreenContext[] = [];
  const autoAllowCalls: unknown[] = [];
  const localRuntimeDependencyCalls: unknown[] = [];
  const beforeRequestFilters: unknown[] = [];
  const confirmCalls: ConfirmBlockedScreenContext[] = [];
  const redirects: BlockedScreenContext[] = [];
  let webRequestBefore: WebRequestBeforeListener | null = null;
  let webRequestError: WebRequestErrorListener | null = null;
  let webNavigationBefore: WebNavigationBeforeListener | null = null;
  let webNavigationError: WebNavigationErrorListener | null = null;
  let runtimeMessage:
    | ((message: unknown, sender: unknown, sendResponse: (response: unknown) => void) => unknown)
    | null = null;

  const browser = {
    webRequest: {
      onBeforeRequest: {
        addListener: (listener: WebRequestBeforeListener, filter: unknown) => {
          webRequestBefore = listener;
          beforeRequestFilters.push(filter);
        },
      },
      onErrorOccurred: {
        addListener: (listener: WebRequestErrorListener) => {
          webRequestError = listener;
        },
      },
    },
    webNavigation: {
      onBeforeNavigate: {
        addListener: (listener: WebNavigationBeforeListener) => {
          webNavigationBefore = listener;
        },
      },
      onErrorOccurred: {
        addListener: (listener: WebNavigationErrorListener) => {
          webNavigationError = listener;
        },
      },
    },
    runtime: {
      getURL: (path: string) => `moz-extension://unit-test/${path}`,
      onMessage: {
        addListener: (listener: unknown): void => {
          runtimeMessage = listener as (
            message: unknown,
            sender: unknown,
            sendResponse: (response: unknown) => void
          ) => unknown;
        },
      },
    },
    tabs: {
      get: () =>
        Promise.resolve({
          id: 1,
          url: options.currentTabUrl ?? undefined,
        }),
      onRemoved: {
        addListener: () => undefined,
      },
    },
  } as unknown as Browser;

  const listenerOptions = {
    addBlockedDomain: (tabId: number, hostname: string, error: string, origin?: string | null) => {
      addedBlocks.push({
        tabId,
        hostname,
        error,
        origin: origin ?? null,
      });
    },
    browser,
    clearTabRuntimeState: () => undefined,
    disposeTab: () => undefined,
    evaluateBlockedPath:
      options.evaluateBlockedPath ?? ((): ReturnType<EvaluateBlockedPath> => null),
    evaluateBlockedSubdomain:
      options.evaluateBlockedSubdomain ?? ((): ReturnType<EvaluateBlockedSubdomain> => null),
    allowLocalRuntimeDependency: async (input) => {
      localRuntimeDependencyCalls.push(input);
      return options.allowLocalRuntimeDependency
        ? await options.allowLocalRuntimeDependency(input)
        : { success: true };
    },
    handleRuntimeMessage:
      options.handleRuntimeMessage ?? ((): Promise<undefined> => Promise.resolve(undefined)),
    ...(options.recordDependencyObservationEvent
      ? { recordDependencyObservationEvent: options.recordDependencyObservationEvent }
      : {}),
    redirectToBlockedScreen: (context: BlockedScreenContext) => {
      redirects.push(context);
      return Promise.resolve();
    },
    confirmBlockedScreenNavigation: async (context: ConfirmBlockedScreenContext) => {
      confirmCalls.push(context);
      return options.confirmBlockedScreenNavigation
        ? await options.confirmBlockedScreenNavigation(context)
        : false;
    },
  } as Parameters<typeof registerBackgroundListeners>[0] & {
    confirmBlockedScreenNavigation: (context: ConfirmBlockedScreenContext) => Promise<boolean>;
  };

  registerBackgroundListeners(listenerOptions);

  return {
    addedBlocks,
    autoAllowCalls,
    localRuntimeDependencyCalls,
    beforeRequestFilters,
    confirmCalls,
    redirects,
    get webRequestBefore(): WebRequestBeforeListener | null {
      return webRequestBefore;
    },
    get runtimeMessage():
      | ((message: unknown, sender: unknown, sendResponse: (response: unknown) => void) => unknown)
      | null {
      return runtimeMessage;
    },
    get webNavigationBefore(): WebNavigationBeforeListener | null {
      return webNavigationBefore;
    },
    get webNavigationError(): WebNavigationErrorListener | null {
      return webNavigationError;
    },
    get webRequestError(): WebRequestErrorListener | null {
      return webRequestError;
    },
  };
}

void describe('background listeners blocked-screen routing', () => {
  void test('keeps runtime message channel open until async handlers send a response', async () => {
    const harness = createListenerHarness({
      handleRuntimeMessage: () => Promise.resolve({ success: true, id: 'request-1' }),
    });
    assert.ok(harness.runtimeMessage);

    const responses: unknown[] = [];
    const keepAlive = harness.runtimeMessage(
      { action: 'submitBlockedDomainRequest' },
      { tab: { id: 1 } },
      (response) => {
        responses.push(response);
      }
    );

    assert.equal(keepAlive, true);
    await waitForAsyncListeners();
    assert.deepEqual(responses, [{ success: true, id: 'request-1' }]);
  });

  void test('does not auto-allow page resource candidates reported by content scripts', async () => {
    const harness = createListenerHarness();
    assert.ok(harness.runtimeMessage);

    const responses: unknown[] = [];
    const keepAlive = harness.runtimeMessage(
      {
        action: 'openpathPageResourceCandidate',
        kind: 'fetch',
        pageUrl: 'http://allowed.example/app',
        resourceUrl: 'http://api.allowed-cdn.example/data.json',
        tabId: 1,
      },
      { tab: { id: 9, url: 'http://allowed.example/fallback' } },
      (response) => {
        responses.push(response);
      }
    );

    assert.equal(keepAlive, true);
    await waitForAsyncListeners();
    assert.deepEqual(responses, [undefined]);
    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('ignores page subresource candidate kinds in Firefox Core', async () => {
    const harness = createListenerHarness();
    assert.ok(harness.runtimeMessage);

    const candidates = [
      ['image', 'http://image.example/pixel.png', 'image'],
      ['script', 'http://script.example/asset.js', 'script'],
      ['stylesheet', 'http://style.example/site.css', 'stylesheet'],
      ['font', 'http://fonts.example/font.woff2', 'font'],
      ['xmlhttprequest', 'http://xhr.example/data.json', 'xmlhttprequest'],
      ['unknown', 'http://other.example/resource', 'other'],
    ] as const;

    for (const [kind, resourceUrl] of candidates) {
      harness.runtimeMessage(
        {
          action: 'openpathPageResourceCandidate',
          kind,
          pageUrl: 'http://allowed.example/app',
          resourceUrl,
          tabId: 3,
        },
        {},
        () => undefined
      );
    }

    await waitForAsyncListeners();
    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('does not process malformed page resource candidates in Firefox Core', async () => {
    const harness = createListenerHarness();
    assert.ok(harness.runtimeMessage);

    const responses: unknown[] = [];
    harness.runtimeMessage(
      {
        action: 'openpathPageResourceCandidate',
        pageUrl: 'http://allowed.example/app',
        tabId: 1,
      },
      { tab: { id: 1 } },
      (response) => {
        responses.push(response);
      }
    );

    await waitForAsyncListeners();
    assert.deepEqual(responses, [undefined]);
    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('registers request interception for all page resource types', () => {
    const harness = createListenerHarness();

    assert.ok(harness.webRequestBefore);
    assert.deepEqual(harness.beforeRequestFilters, [
      {
        urls: ['<all_urls>'],
      },
    ]);
  });

  void test('records browser dependency request and navigation observations when diagnostics are injected', () => {
    const recorded: unknown[] = [];
    const harness = createListenerHarness({
      recordDependencyObservationEvent: (event) => {
        recorded.push(event);
      },
    });

    assert.ok(harness.webRequestBefore);
    assert.ok(harness.webRequestError);
    assert.ok(harness.webNavigationBefore);
    assert.ok(harness.webNavigationError);

    harness.webRequestBefore({
      requestId: 'req-1',
      tabId: 4,
      frameId: 0,
      type: 'script',
      url: 'https://cdn.example.test/app.js',
      documentUrl: 'https://origin.example.test/app',
      originUrl: 'https://origin.example.test',
    } as WebRequest.OnBeforeRequestDetailsType);
    harness.webRequestError({
      requestId: 'req-2',
      tabId: 4,
      frameId: 0,
      type: 'xmlhttprequest',
      url: 'https://api.example.test/data.json',
      documentUrl: 'https://origin.example.test/app',
      originUrl: 'https://origin.example.test',
    } as WebRequest.OnErrorOccurredDetailsType);
    harness.webNavigationBefore({
      tabId: 4,
      frameId: 0,
      url: 'https://origin.example.test/app',
    });
    harness.webNavigationError({
      tabId: 4,
      frameId: 0,
      url: 'https://blocked.example.test/',
      error: 'NS_ERROR_UNKNOWN_HOST',
    });

    assert.deepEqual(recorded, [
      {
        source: 'webRequest.onBeforeRequest',
        tabId: 4,
        frameId: 0,
        requestId: 'req-1',
        type: 'script',
        anchorHost: 'origin.example.test',
        dependencyHost: 'cdn.example.test',
      },
      {
        source: 'webRequest.onErrorOccurred',
        tabId: 4,
        frameId: 0,
        requestId: 'req-2',
        type: 'xmlhttprequest',
        anchorHost: 'origin.example.test',
        dependencyHost: 'api.example.test',
      },
      {
        source: 'webNavigation.onBeforeNavigate',
        tabId: 4,
        frameId: 0,
        anchorHost: 'origin.example.test',
      },
      {
        source: 'webNavigation.onErrorOccurred',
        tabId: 4,
        frameId: 0,
        anchorHost: 'blocked.example.test',
      },
    ]);
  });

  void test('reports eligible page resources to the local dependency overlay without remote auto-allow', async () => {
    const harness = createListenerHarness({
      currentTabUrl: 'https://allowed.example/app',
    });
    assert.ok(harness.webRequestBefore);

    const result = harness.webRequestBefore({
      type: 'xmlhttprequest',
      tabId: 3,
      url: 'https://cdn.example/data.json',
      originUrl: 'https://allowed.example/app',
    } as WebRequest.OnBeforeRequestDetailsType);

    assert.ok(result instanceof Promise);
    assert.deepEqual(await result, {});
    assert.deepEqual(harness.autoAllowCalls, []);
    assert.deepEqual(harness.localRuntimeDependencyCalls, [
      {
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'xmlhttprequest',
      },
    ]);
  });

  void test('allows eligible page resources through the local native dependency overlay only', async () => {
    const nativePayloads: unknown[] = [];
    const harness = createListenerHarness({
      allowLocalRuntimeDependency: (input) => {
        nativePayloads.push(input);
        return Promise.resolve({ success: true });
      },
    });
    assert.ok(harness.webNavigationBefore);
    assert.ok(harness.webRequestBefore);

    harness.webNavigationBefore({
      frameId: 0,
      tabId: 44,
      url: 'https://allowed.example/lesson?token=secret',
    });

    const result = harness.webRequestBefore({
      documentUrl: 'https://allowed.example/lesson?token=secret',
      originUrl: 'https://allowed.example',
      tabId: 44,
      type: 'script',
      url: 'https://cdn.example.net/assets/app.js?user=student',
    } as WebRequest.OnBeforeRequestDetailsType);

    assert.ok(result instanceof Promise);
    assert.deepEqual(await result, {});
    assert.deepEqual(nativePayloads, [
      {
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example.net',
        requestType: 'script',
      },
    ]);
  });

  void test('derives local dependency overlay anchor host from originUrl when tab and document context are absent', async () => {
    const nativePayloads: unknown[] = [];
    const harness = createListenerHarness({
      allowLocalRuntimeDependency: (input) => {
        nativePayloads.push(input);
        return Promise.resolve({ success: true });
      },
    });
    assert.ok(harness.webRequestBefore);

    const result = harness.webRequestBefore({
      originUrl: 'https://allowed.example/lesson',
      tabId: 45,
      type: 'xmlhttprequest',
      url: 'https://api.not-yet-approved.example/data.json',
    } as WebRequest.OnBeforeRequestDetailsType);

    assert.ok(result instanceof Promise);
    assert.deepEqual(await result, {});
    assert.deepEqual(nativePayloads, [
      {
        anchorHost: 'allowed.example',
        dependencyHost: 'api.not-yet-approved.example',
        requestType: 'xmlhttprequest',
      },
    ]);
  });

  void test('does not block main-frame navigations while probing auto-allow candidates', () => {
    const harness = createListenerHarness({
      currentTabUrl: 'https://allowed.example/app',
    });
    assert.ok(harness.webRequestBefore);

    const result = harness.webRequestBefore({
      type: 'main_frame',
      tabId: 3,
      url: 'https://allowed.example/app',
    } as WebRequest.OnBeforeRequestDetailsType);

    assert.equal(result, undefined);
    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('does not auto-allow requests cancelled by blocked subdomain policy', () => {
    const harness = createListenerHarness({
      evaluateBlockedSubdomain: () => ({
        cancel: true,
        reason: 'BLOCKED_SUBDOMAIN_POLICY:ads.example.org',
      }),
    });
    assert.ok(harness.webRequestBefore);

    const result = harness.webRequestBefore({
      type: 'xmlhttprequest',
      tabId: 1,
      url: 'https://ads.example.org/pixel',
      originUrl: 'https://allowed.example/app',
    } as WebRequest.OnBeforeRequestDetailsType);

    assert.deepEqual(result, { cancel: true });
    assert.deepEqual(harness.autoAllowCalls, []);
    assert.deepEqual(harness.addedBlocks, [
      {
        tabId: 1,
        hostname: 'ads.example.org',
        error: 'BLOCKED_SUBDOMAIN_POLICY:ads.example.org',
        origin: 'https://allowed.example/app',
      },
    ]);
  });

  void test('redirects a main-frame timeout when native policy confirms the hostname is blocked', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
    });
    assert.ok(harness.webRequestError);

    harness.webRequestError({
      error: 'NS_ERROR_NET_TIMEOUT',
      tabId: 7,
      type: 'main_frame',
      url: 'https://blocked.example/lesson',
    } as WebRequest.OnErrorOccurredDetailsType);

    await waitForAsyncListeners();

    assert.deepEqual(harness.confirmCalls, [
      {
        tabId: 7,
        hostname: 'blocked.example',
        error: 'NS_ERROR_NET_TIMEOUT',
        origin: null,
        url: 'https://blocked.example/lesson',
      },
    ]);
    assert.deepEqual(harness.redirects, [
      {
        tabId: 7,
        hostname: 'blocked.example',
        error: 'NS_ERROR_NET_TIMEOUT',
        origin: null,
      },
    ]);
  });

  void test('does not redirect a main-frame refused connection when native policy says it is allowed', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(false),
    });
    assert.ok(harness.webRequestError);

    harness.webRequestError({
      error: 'NS_ERROR_CONNECTION_REFUSED',
      tabId: 8,
      type: 'main_frame',
      url: 'https://allowed.example/lesson',
    } as WebRequest.OnErrorOccurredDetailsType);

    await waitForAsyncListeners();

    assert.equal(harness.confirmCalls.length, 1);
    assert.deepEqual(harness.redirects, []);
  });

  void test('keeps unknown-host main-frame redirects immediate without native confirmation', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.reject(new Error('should not be called')),
    });
    assert.ok(harness.webRequestError);

    harness.webRequestError({
      error: 'NS_ERROR_UNKNOWN_HOST',
      tabId: 9,
      type: 'main_frame',
      url: 'https://missing.example/lesson',
    } as WebRequest.OnErrorOccurredDetailsType);

    await waitForAsyncListeners();

    assert.deepEqual(harness.confirmCalls, []);
    assert.deepEqual(harness.redirects, [
      {
        tabId: 9,
        hostname: 'missing.example',
        error: 'NS_ERROR_UNKNOWN_HOST',
        origin: null,
      },
    ]);
  });

  void test('uses webNavigation top-frame errors as a fallback for native-confirmed blocks', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
    });
    assert.ok(harness.webNavigationError);

    harness.webNavigationError({
      error: 'NS_ERROR_NET_TIMEOUT',
      frameId: 0,
      tabId: 10,
      url: 'https://navigation-blocked.example/lesson',
    });

    await waitForAsyncListeners();

    assert.deepEqual(harness.redirects, [
      {
        tabId: 10,
        hostname: 'navigation-blocked.example',
        error: 'NS_ERROR_NET_TIMEOUT',
        origin: null,
      },
    ]);
  });

  void test('preflights top-frame navigations through native policy before Firefox reports status 0', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
    });
    assert.ok(harness.webNavigationBefore);

    harness.webNavigationBefore({
      frameId: 0,
      tabId: 14,
      url: 'https://preflight-blocked.example/lesson',
    });

    await waitForAsyncListeners();

    assert.deepEqual(harness.confirmCalls, [
      {
        tabId: 14,
        hostname: 'preflight-blocked.example',
        error: 'OPENPATH_NATIVE_POLICY_BLOCKED',
        origin: null,
        url: 'https://preflight-blocked.example/lesson',
      },
    ]);
    assert.deepEqual(harness.redirects, [
      {
        tabId: 14,
        hostname: 'preflight-blocked.example',
        error: 'OPENPATH_NATIVE_POLICY_BLOCKED',
        origin: null,
      },
    ]);
  });

  void test('ignores stale native preflight confirmations after a newer top-frame navigation starts', async () => {
    let resolveFirstConfirmation: (confirmed: boolean) => void = () => undefined;
    const firstConfirmation = new Promise<boolean>((resolve) => {
      resolveFirstConfirmation = resolve;
    });
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: (context) =>
        context.hostname === 'slow-blocked.example' ? firstConfirmation : Promise.resolve(false),
    });
    assert.ok(harness.webNavigationBefore);

    harness.webNavigationBefore({
      frameId: 0,
      tabId: 15,
      url: 'https://slow-blocked.example/lesson',
    });
    harness.webNavigationBefore({
      frameId: 0,
      tabId: 15,
      url: 'https://allowed-after.example/lesson',
    });

    await waitForAsyncListeners();
    resolveFirstConfirmation(true);
    await waitForAsyncListeners();

    assert.deepEqual(harness.redirects, []);
  });

  void test('deduplicates webRequest and webNavigation redirects for the same blocked navigation', async () => {
    let resolveConfirmation: (confirmed: boolean) => void = () => undefined;
    const confirmation = new Promise<boolean>((resolve) => {
      resolveConfirmation = resolve;
    });
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => confirmation,
    });
    assert.ok(harness.webRequestError);
    assert.ok(harness.webNavigationError);

    const blockedNavigation = {
      error: 'NS_ERROR_NET_TIMEOUT',
      tabId: 12,
      url: 'https://deduped-blocked.example/lesson',
    };

    harness.webRequestError({
      ...blockedNavigation,
      type: 'main_frame',
    } as WebRequest.OnErrorOccurredDetailsType);
    harness.webNavigationError({
      ...blockedNavigation,
      frameId: 0,
    });

    await waitForAsyncListeners();
    assert.equal(harness.confirmCalls.length, 1);
    assert.deepEqual(harness.redirects, []);

    resolveConfirmation(true);
    await waitForAsyncListeners();

    assert.deepEqual(harness.redirects, [
      {
        tabId: 12,
        hostname: 'deduped-blocked.example',
        error: 'NS_ERROR_NET_TIMEOUT',
        origin: null,
      },
    ]);
  });

  void test('does not reload the blocked screen for late duplicate errors after redirecting', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
    });
    assert.ok(harness.webNavigationBefore);
    assert.ok(harness.webRequestError);

    const blockedUrl = 'https://late-duplicate.example/lesson';
    harness.webNavigationBefore({
      frameId: 0,
      tabId: 16,
      url: blockedUrl,
    });

    await waitForAsyncListeners();
    assert.deepEqual(harness.redirects, [
      {
        tabId: 16,
        hostname: 'late-duplicate.example',
        error: 'OPENPATH_NATIVE_POLICY_BLOCKED',
        origin: null,
      },
    ]);

    harness.webRequestError({
      error: 'NS_ERROR_NET_TIMEOUT',
      tabId: 16,
      type: 'main_frame',
      url: blockedUrl,
    } as WebRequest.OnErrorOccurredDetailsType);

    await waitForAsyncListeners();
    assert.deepEqual(harness.redirects, [
      {
        tabId: 16,
        hostname: 'late-duplicate.example',
        error: 'OPENPATH_NATIVE_POLICY_BLOCKED',
        origin: null,
      },
    ]);
  });

  void test('does not redirect when the tab already shows the blocked screen for the same hostname', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
      currentTabUrl:
        'moz-extension://unit-test/blocked/blocked.html?domain=late-duplicate.example&error=OPENPATH_NATIVE_POLICY_BLOCKED',
    });
    assert.ok(harness.webRequestError);

    harness.webRequestError({
      error: 'NS_ERROR_NET_TIMEOUT',
      tabId: 17,
      type: 'main_frame',
      url: 'https://late-duplicate.example/favicon.ico',
    } as WebRequest.OnErrorOccurredDetailsType);

    await waitForAsyncListeners();

    assert.deepEqual(harness.redirects, []);
  });

  void test('does not redirect subresource blocking errors to the blocked screen', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
    });
    assert.ok(harness.webRequestError);

    harness.webRequestError({
      error: 'NS_ERROR_NET_TIMEOUT',
      tabId: 11,
      type: 'xmlhttprequest',
      url: 'https://api.blocked.example/data.json',
    } as WebRequest.OnErrorOccurredDetailsType);

    await waitForAsyncListeners();

    assert.deepEqual(harness.confirmCalls, []);
    assert.deepEqual(harness.redirects, []);
    assert.equal(harness.addedBlocks.length, 1);
  });

  void test('does not auto-allow ajax errors from an allowed origin', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
    });
    assert.ok(harness.webRequestError);

    harness.webRequestError({
      error: 'NS_ERROR_NET_TIMEOUT',
      originUrl: 'https://allowed.example/app',
      tabId: 13,
      type: 'xmlhttprequest',
      url: 'https://api.blocked.example/data.json',
    } as WebRequest.OnErrorOccurredDetailsType);

    await waitForAsyncListeners();

    assert.deepEqual(harness.confirmCalls, []);
    assert.deepEqual(harness.redirects, []);
    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('reports page subresource requests to the local overlay without blocked-screen redirects', async () => {
    const resourceTypes: WebRequest.ResourceType[] = ['script', 'image', 'stylesheet', 'font'];

    for (const requestType of resourceTypes) {
      const harness = createListenerHarness({
        confirmBlockedScreenNavigation: () => Promise.resolve(true),
      });
      assert.ok(harness.webRequestBefore);

      const result = harness.webRequestBefore({
        originUrl: 'https://allowed.example/app',
        tabId: 35,
        type: requestType,
        url: `https://${requestType}.blocked.example/resource`,
      } as WebRequest.OnBeforeRequestDetailsType);

      assert.ok(result instanceof Promise);
      assert.deepEqual(await result, {});
      assert.deepEqual(harness.confirmCalls, []);
      assert.deepEqual(harness.redirects, []);
      assert.deepEqual(harness.autoAllowCalls, []);
      assert.deepEqual(harness.localRuntimeDependencyCalls, [
        {
          anchorHost: 'allowed.example',
          dependencyHost: `${requestType}.blocked.example`,
          requestType,
        },
      ]);
    }
  });

  void test('reports stylesheet-initiated font subresources to the local overlay only', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
      currentTabUrl: 'https://www.reddit.com/r/openpath',
    });
    assert.ok(harness.webRequestBefore);

    const result = harness.webRequestBefore({
      originUrl: 'https://fonts.googleapis.com/css2?family=Inter',
      tabId: 41,
      type: 'font',
      url: 'https://fonts.gstatic.com/s/inter/v12/font.woff2',
    } as WebRequest.OnBeforeRequestDetailsType);

    assert.ok(result instanceof Promise);
    assert.deepEqual(await result, {});
    assert.deepEqual(harness.confirmCalls, []);
    assert.deepEqual(harness.redirects, []);
    assert.deepEqual(harness.autoAllowCalls, []);
    assert.deepEqual(harness.localRuntimeDependencyCalls, [
      {
        anchorHost: 'fonts.googleapis.com',
        dependencyHost: 'fonts.gstatic.com',
        requestType: 'font',
      },
    ]);
  });

  void test('does not start auto-allow when Firefox omits a usable tab id for a page subresource', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
    });
    assert.ok(harness.webRequestBefore);

    const result = harness.webRequestBefore({
      documentUrl: 'https://allowed.example/app',
      tabId: -1,
      type: 'script',
      url: 'https://cdn.blocked.example/asset.js',
    } as WebRequest.OnBeforeRequestDetailsType);

    await waitForAsyncListeners();

    assert.equal(result, undefined);
    assert.deepEqual(harness.confirmCalls, []);
    assert.deepEqual(harness.redirects, []);
    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('does not auto-allow missing Firefox request types with page context', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
    });
    assert.ok(harness.webRequestBefore);

    const result = harness.webRequestBefore({
      originUrl: 'https://allowed.example/app',
      tabId: 37,
      url: 'https://api.blocked.example/data.json',
    } as WebRequest.OnBeforeRequestDetailsType);

    await waitForAsyncListeners();

    assert.equal(result, undefined);
    assert.deepEqual(harness.confirmCalls, []);
    assert.deepEqual(harness.redirects, []);
    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('does not auto-allow requests cancelled by blocked path policy', async () => {
    const harness = createListenerHarness({
      evaluateBlockedPath: () => ({ cancel: true, reason: 'BLOCKED_PATH_POLICY:test' }),
    });
    assert.ok(harness.webRequestBefore);

    const result = harness.webRequestBefore({
      originUrl: 'https://allowed.example/app',
      tabId: 36,
      type: 'script',
      url: 'https://cdn.blocked.example/private.js',
    } as WebRequest.OnBeforeRequestDetailsType);

    await waitForAsyncListeners();

    assert.deepEqual(result, { cancel: true });
    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('does not auto-allow blocked page subresources from an allowed origin', async () => {
    const resourceTypes: WebRequest.ResourceType[] = [
      'script',
      'image',
      'stylesheet',
      'font',
      'media',
      'imageset',
      'beacon',
      'ping',
      'websocket',
      'web_manifest',
      'json',
      'other',
    ];

    for (const requestType of resourceTypes) {
      const harness = createListenerHarness({
        confirmBlockedScreenNavigation: () => Promise.resolve(true),
      });
      assert.ok(harness.webRequestError);

      harness.webRequestError({
        error: 'NS_ERROR_NET_TIMEOUT',
        originUrl: 'https://allowed.example/app',
        tabId: 31,
        type: requestType,
        url: `https://${requestType}.blocked.example/resource`,
      } as WebRequest.OnErrorOccurredDetailsType);

      await waitForAsyncListeners();

      assert.deepEqual(harness.confirmCalls, []);
      assert.deepEqual(harness.redirects, []);
      assert.deepEqual(harness.autoAllowCalls, []);
    }
  });

  void test('does not auto-allow blocked frame navigation errors', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
    });
    assert.ok(harness.webRequestError);

    harness.webRequestError({
      error: 'NS_ERROR_NET_TIMEOUT',
      originUrl: 'https://allowed.example/app',
      tabId: 32,
      type: 'sub_frame',
      url: 'https://embed.blocked.example/frame',
    } as WebRequest.OnErrorOccurredDetailsType);

    await waitForAsyncListeners();

    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('does not auto-allow ajax errors when Firefox omits request origins', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
      currentTabUrl: 'https://allowed.example/app',
    });
    assert.ok(harness.webRequestError);

    harness.webRequestError({
      error: 'NS_ERROR_NET_TIMEOUT',
      tabId: 13,
      type: 'fetch',
      url: 'https://api.blocked.example/data.json',
    } as unknown as WebRequest.OnErrorOccurredDetailsType);

    await waitForAsyncListeners();

    assert.deepEqual(harness.confirmCalls, []);
    assert.deepEqual(harness.redirects, []);
    assert.deepEqual(harness.autoAllowCalls, []);
  });

  void test('does not auto-allow preview image requests when Firefox omits request context', async () => {
    const harness = createListenerHarness({
      confirmBlockedScreenNavigation: () => Promise.resolve(true),
      currentTabUrl: 'https://www.reddit.com/r/openpath/comments/demo',
    });
    assert.ok(harness.webRequestBefore);

    const result = harness.webRequestBefore({
      tabId: 52,
      url: 'https://preview.redd.it/my-paprika-had-no-seeds-v0-0q7k5y7403yg1.jpeg?width=1080&crop=smart',
    } as WebRequest.OnBeforeRequestDetailsType);

    await waitForAsyncListeners();

    assert.equal(result, undefined);
    assert.deepEqual(harness.confirmCalls, []);
    assert.deepEqual(harness.redirects, []);
    assert.deepEqual(harness.autoAllowCalls, []);
  });
});
