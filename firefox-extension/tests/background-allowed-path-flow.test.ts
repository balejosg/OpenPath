import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import type { Browser, WebRequest } from 'webextension-polyfill';
import { registerBackgroundListeners } from '../src/lib/background-listeners.js';

type HistoryStateUpdatedListener = (details: {
  frameId: number;
  tabId: number;
  url: string;
}) => void;

type WebRequestBeforeListener = (details: WebRequest.OnBeforeRequestDetailsType) => unknown;

function createMinimalBrowser(): {
  browser: Browser;
  dispatchHistoryStateUpdated: (details: { frameId: number; tabId: number; url: string }) => void;
  dispatchBeforeRequest: (details: WebRequest.OnBeforeRequestDetailsType) => unknown;
  tabUpdates: { tabId: number; url: string }[];
} {
  let historyStateUpdatedListener: HistoryStateUpdatedListener | null = null;
  let beforeRequestListener: WebRequestBeforeListener | null = null;
  const tabUpdates: { tabId: number; url: string }[] = [];

  const browser = {
    webRequest: {
      onBeforeRequest: {
        addListener: (listener: WebRequestBeforeListener) => {
          beforeRequestListener = listener;
        },
      },
      onErrorOccurred: {
        addListener: () => undefined,
      },
    },
    webNavigation: {
      onBeforeNavigate: {
        addListener: () => undefined,
      },
      onErrorOccurred: {
        addListener: () => undefined,
      },
      onHistoryStateUpdated: {
        addListener: (listener: HistoryStateUpdatedListener) => {
          historyStateUpdatedListener = listener;
        },
      },
    },
    runtime: {
      getURL: (path: string) => `moz-extension://abc/${path}`,
      onMessage: {
        addListener: () => undefined,
      },
    },
    tabs: {
      get: () => Promise.resolve({ id: 7, url: 'https://www.youtube.com/' }),
      update: (tabId: number, info: { url: string }) => {
        tabUpdates.push({ tabId, url: info.url });
        return Promise.resolve({});
      },
      onRemoved: {
        addListener: () => undefined,
      },
    },
  } as unknown as Browser;

  return {
    browser,
    dispatchHistoryStateUpdated: (details) => {
      if (!historyStateUpdatedListener) {
        throw new Error('onHistoryStateUpdated listener not registered');
      }
      historyStateUpdatedListener(details);
    },
    dispatchBeforeRequest: (details) => {
      if (!beforeRequestListener) {
        throw new Error('onBeforeRequest listener not registered');
      }
      return beforeRequestListener(details);
    },
    tabUpdates,
  };
}

function baseListenerOptions(
  browser: Browser
): Omit<
  Parameters<typeof registerBackgroundListeners>[0],
  'evaluateBlockedPath' | 'evaluateBlockedSubdomain' | 'evaluateAllowedPath'
> {
  return {
    addBlockedDomain: () => undefined,
    browser,
    clearTabRuntimeState: () => undefined,
    disposeTab: () => undefined,
    allowLocalRuntimeDependency: () => Promise.resolve({ success: true }),
    handleRuntimeMessage: () => Promise.resolve(undefined),
    redirectToBlockedScreen: () => Promise.resolve(),
    confirmBlockedScreenNavigation: () => Promise.resolve(false),
  };
}

void describe('allowed-path background flow', () => {
  void test('redirects a managed-host main_frame request to the blocked screen', () => {
    const { browser, dispatchBeforeRequest } = createMinimalBrowser();

    registerBackgroundListeners({
      ...baseListenerOptions(browser),
      evaluateBlockedPath: () => null,
      evaluateBlockedSubdomain: () => null,
      evaluateAllowedPath: (details) =>
        details.type === 'main_frame' && details.url.includes('/watch?v=zzz')
          ? {
              redirectUrl: 'moz-extension://abc/blocked/blocked.html?domain=youtube.com',
              reason: 'ALLOWED_PATH_POLICY:youtube.com',
            }
          : null,
    });

    const result = dispatchBeforeRequest({
      type: 'main_frame',
      url: 'https://www.youtube.com/watch?v=zzz',
      tabId: 7,
      frameId: 0,
      requestId: '1',
      method: 'GET',
      timeStamp: 0,
    } as WebRequest.OnBeforeRequestDetailsType);

    assert.deepEqual(result, {
      redirectUrl: 'moz-extension://abc/blocked/blocked.html?domain=youtube.com',
    });
  });

  void test('redirects a managed-host SPA route change to the blocked screen', async () => {
    const { browser, dispatchHistoryStateUpdated, tabUpdates } = createMinimalBrowser();

    registerBackgroundListeners({
      ...baseListenerOptions(browser),
      evaluateBlockedPath: () => null,
      evaluateBlockedSubdomain: () => null,
      evaluateAllowedPath: (details) =>
        details.type === 'main_frame' && details.url.includes('/watch?v=zzz')
          ? {
              redirectUrl: 'moz-extension://abc/blocked/blocked.html?domain=youtube.com',
              reason: 'ALLOWED_PATH_POLICY:youtube.com',
            }
          : null,
    });

    dispatchHistoryStateUpdated({
      tabId: 7,
      frameId: 0,
      url: 'https://www.youtube.com/watch?v=zzz',
    });

    await Promise.resolve();

    assert.deepEqual(tabUpdates, [
      { tabId: 7, url: 'moz-extension://abc/blocked/blocked.html?domain=youtube.com' },
    ]);
  });

  void test('ignores SPA navigations on sub-frames (frameId !== 0)', async () => {
    const { browser, dispatchHistoryStateUpdated, tabUpdates } = createMinimalBrowser();

    registerBackgroundListeners({
      ...baseListenerOptions(browser),
      evaluateBlockedPath: () => null,
      evaluateBlockedSubdomain: () => null,
      evaluateAllowedPath: (details) =>
        details.type === 'main_frame'
          ? {
              redirectUrl: 'moz-extension://abc/blocked/blocked.html?domain=youtube.com',
              reason: 'ALLOWED_PATH_POLICY:youtube.com',
            }
          : null,
    });

    dispatchHistoryStateUpdated({
      tabId: 7,
      frameId: 1,
      url: 'https://www.youtube.com/watch?v=zzz',
    });

    await Promise.resolve();

    assert.deepEqual(tabUpdates, []);
  });

  void test('passes non-managed SPA navigations through without redirecting', async () => {
    const { browser, dispatchHistoryStateUpdated, tabUpdates } = createMinimalBrowser();

    registerBackgroundListeners({
      ...baseListenerOptions(browser),
      evaluateBlockedPath: () => null,
      evaluateBlockedSubdomain: () => null,
      evaluateAllowedPath: () => null,
    });

    dispatchHistoryStateUpdated({
      tabId: 7,
      frameId: 0,
      url: 'https://www.example.com/',
    });

    await Promise.resolve();

    assert.deepEqual(tabUpdates, []);
  });
});
