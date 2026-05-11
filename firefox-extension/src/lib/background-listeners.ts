import type { Browser, Runtime, WebNavigation, WebRequest } from 'webextension-polyfill';
import { getErrorMessage, logger } from './logger.js';
import { shouldClearBlockedMonitorStateOnNavigate } from './blocked-screen-contract.js';
import { BLOCKED_SCREEN_PATH, ROUTE_BLOCK_REASON, extractHostname } from './path-blocking.js';
import { BLOCKED_SUBDOMAIN_REASON } from './subdomain-blocking.js';
import {
  createBlockedScreenNavigationController,
  type BlockedScreenContext,
  type ConfirmBlockedScreenContext,
} from './blocked-screen-navigation-controller.js';
import { evaluateGoogleGameBlocking, isGoogleGamePolicyOutcome } from './google-game-blocking.js';
import type { OpenPathDependencyObservationEventInput } from './dependency-observation-diagnostics.js';

interface BackgroundListenersOptions {
  addBlockedDomain: (
    tabId: number,
    hostname: string,
    error: string,
    origin?: string | null
  ) => void;
  browser: Browser;
  clearTabRuntimeState: (tabId: number) => void;
  disposeTab: (tabId: number) => void;
  evaluateBlockedPath: (
    details: WebRequest.OnBeforeRequestDetailsType
  ) => { cancel?: boolean; redirectUrl?: string; reason?: string } | null;
  evaluateBlockedSubdomain: (
    details: WebRequest.OnBeforeRequestDetailsType
  ) => { cancel?: boolean; redirectUrl?: string; reason?: string } | null;
  confirmBlockedScreenNavigation?: (context: ConfirmBlockedScreenContext) => Promise<boolean>;
  handleRuntimeMessage: (message: unknown, sender: Runtime.MessageSender) => Promise<unknown>;
  recordDependencyObservationEvent?: (event: OpenPathDependencyObservationEventInput) => void;
  redirectToBlockedScreen: (context: BlockedScreenContext) => Promise<void>;
}

function createRuntimeMessageResponder(
  options: Pick<BackgroundListenersOptions, 'handleRuntimeMessage'>
): (
  message: unknown,
  sender: Runtime.MessageSender,
  sendResponse: (response: unknown) => void
) => true {
  return (message, sender, sendResponse) => {
    const responsePromise = options.handleRuntimeMessage(message, sender);

    void Promise.resolve(responsePromise).then(
      (response) => {
        sendResponse(response);
      },
      (error: unknown) => {
        sendResponse({ success: false, error: getErrorMessage(error) });
      }
    );

    return true;
  };
}

export function registerBackgroundListeners(options: BackgroundListenersOptions): void {
  const blockedScreenNavigation = createBlockedScreenNavigationController({
    addBlockedDomain: options.addBlockedDomain,
    ...(options.confirmBlockedScreenNavigation
      ? { confirmBlockedScreenNavigation: options.confirmBlockedScreenNavigation }
      : {}),
    getBlockedScreenUrl: () => options.browser.runtime.getURL(BLOCKED_SCREEN_PATH),
    getCurrentTabUrl: async (tabId) => {
      const tab = await options.browser.tabs.get(tabId);
      return tab.url;
    },
    redirectToBlockedScreen: options.redirectToBlockedScreen,
  });
  options.browser.webRequest.onBeforeRequest.addListener(
    (details: WebRequest.OnBeforeRequestDetailsType) => {
      options.recordDependencyObservationEvent?.({
        source: 'webRequest.onBeforeRequest',
        tabId: details.tabId,
        frameId: details.frameId,
        requestId: details.requestId,
        type: details.type,
        pageUrl: details.documentUrl ?? details.originUrl,
        documentUrl: details.documentUrl,
        originUrl: details.originUrl,
        resourceUrl: details.url,
      });
      const result =
        options.evaluateBlockedPath(details) ??
        options.evaluateBlockedSubdomain(details) ??
        evaluateGoogleGameBlocking(details, {
          extensionOrigin: options.browser.runtime.getURL('/'),
        });
      if (!result) {
        return;
      }

      const hostname = extractHostname(details.url) ?? 'dominio desconocido';

      if (details.tabId >= 0) {
        const fallbackReason =
          result.reason?.startsWith(BLOCKED_SUBDOMAIN_REASON) === true
            ? `${BLOCKED_SUBDOMAIN_REASON}:unknown`
            : isGoogleGamePolicyOutcome(result)
              ? 'GOOGLE_GAME_POLICY:unknown'
              : `${ROUTE_BLOCK_REASON}:unknown`;
        const reason = result.reason ?? fallbackReason;
        options.addBlockedDomain(
          details.tabId,
          hostname,
          reason,
          details.originUrl ?? details.documentUrl
        );
      }

      if (result.redirectUrl) {
        return { redirectUrl: result.redirectUrl };
      }

      return { cancel: true };
    },
    { urls: ['<all_urls>'] },
    ['blocking']
  );

  options.browser.webRequest.onErrorOccurred.addListener(
    (details: WebRequest.OnErrorOccurredDetailsType) => {
      options.recordDependencyObservationEvent?.({
        source: 'webRequest.onErrorOccurred',
        tabId: details.tabId,
        frameId: details.frameId,
        requestId: details.requestId,
        type: details.type,
        pageUrl: details.documentUrl ?? details.originUrl,
        documentUrl: details.documentUrl,
        originUrl: details.originUrl,
        resourceUrl: details.url,
      });
      const hostname = extractHostname(details.url);
      if (!hostname) {
        return;
      }

      if (details.tabId >= 0) {
        blockedScreenNavigation.handleBlockedScreenNavigationError(details, {
          recordBlockedDomain: true,
          requestType: details.type,
        });
      }
    },
    { urls: ['<all_urls>'] }
  );

  options.browser.webNavigation.onBeforeNavigate.addListener(
    (details: WebNavigation.OnBeforeNavigateDetailsType) => {
      options.recordDependencyObservationEvent?.({
        source: 'webNavigation.onBeforeNavigate',
        tabId: details.tabId,
        frameId: details.frameId,
        pageUrl: details.url,
        resourceUrl: details.url,
      });
      blockedScreenNavigation.handleNativePolicyNavigationPreflight({
        frameId: details.frameId,
        tabId: details.tabId,
        url: details.url,
      });

      if (
        shouldClearBlockedMonitorStateOnNavigate(
          { frameId: details.frameId, url: details.url },
          options.browser.runtime.getURL(BLOCKED_SCREEN_PATH)
        )
      ) {
        logger.debug(`[Monitor] Limpiando bloqueos para tab ${details.tabId.toString()}`);
        options.clearTabRuntimeState(details.tabId);
      }
    }
  );

  options.browser.webNavigation.onErrorOccurred.addListener(
    (details: WebNavigation.OnErrorOccurredDetailsType) => {
      options.recordDependencyObservationEvent?.({
        source: 'webNavigation.onErrorOccurred',
        tabId: details.tabId,
        frameId: details.frameId,
        pageUrl: details.url,
        resourceUrl: details.url,
      });
      const maybeError = (details as { error?: unknown }).error;
      if (typeof maybeError !== 'string' || maybeError.length === 0) {
        return;
      }

      blockedScreenNavigation.handleBlockedScreenNavigationError(
        {
          error: maybeError,
          frameId: details.frameId,
          tabId: details.tabId,
          url: details.url,
        },
        {
          recordBlockedDomain: true,
        }
      );
    }
  );

  options.browser.tabs.onRemoved.addListener((tabId: number) => {
    blockedScreenNavigation.disposeTab(tabId);
    options.disposeTab(tabId);
    logger.debug(`[Monitor] Tab ${tabId.toString()} cerrada, datos eliminados`);
  });

  options.browser.runtime.onMessage.addListener(
    createRuntimeMessageResponder({
      handleRuntimeMessage: options.handleRuntimeMessage,
    })
  );
}
