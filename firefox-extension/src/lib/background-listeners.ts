import type { Browser, Runtime, WebNavigation, WebRequest } from 'webextension-polyfill';
import { getErrorMessage, logger } from './logger.js';
import {
  DEFAULT_LOCAL_RUNTIME_DEPENDENCY_PERSISTENT_SOFT_TIMEOUT_MS,
  LOCAL_RUNTIME_DEPENDENCY_PERSISTENT_SOFT_TIMEOUT_BY_TYPE_MS,
  isPendingRuntimeDependencyResponse,
} from './runtime-dependency-protocol.js';
import { t } from './i18n.js';
import { shouldClearBlockedMonitorStateOnNavigate } from './blocked-screen-contract.js';
import { BLOCKED_SCREEN_PATH, ROUTE_BLOCK_REASON, extractHostname } from './path-blocking.js';
import { BLOCKED_SUBDOMAIN_REASON } from './subdomain-blocking.js';
import { ALLOWED_PATH_BLOCK_REASON } from './allowed-path.js';
import {
  createBlockedScreenNavigationController,
  type BlockedScreenContext,
  type ConfirmBlockedScreenContext,
  type NativeBlockedScreenConfirmation,
} from './blocked-screen-navigation-controller.js';
import { evaluateGoogleGameBlocking, isGoogleGamePolicyOutcome } from './google-game-blocking.js';
import type { OpenPathDependencyObservationEventInput } from './dependency-observation-diagnostics.js';
import type { NavigationState } from './navigation-state.js';

const MAX_CAPTIVE_PORTAL_RECOVERY_HOSTS = 16;
/** Window in which an onErrorOccurred event is attributed to our own cancellation. */
const CANCELLED_PENDING_REQUEST_TTL_MS = 15_000;

export interface RuntimeDependencyCancellationContext {
  anchorHost: string;
  dependencyHost: string;
  frameId: number;
  requestType: string;
  tabId: number;
  documentUrl?: string;
  originUrl?: string;
  requestId?: string;
}

export interface MainFrameNavigationContext {
  tabId: number;
  url: string;
  method?: string;
}

interface BackgroundListenersOptions {
  addBlockedDomain: (
    tabId: number,
    hostname: string,
    error: string,
    origin?: string | null
  ) => void;
  allowLocalRuntimeDependency?: (input: {
    anchorHost: string;
    dependencyHost: string;
    requestType: string;
  }) => Promise<unknown>;
  browser: Browser;
  clearTabRuntimeState: (tabId: number) => void;
  disposeTab: (tabId: number) => void;
  evaluateBlockedPath: (
    details: WebRequest.OnBeforeRequestDetailsType
  ) => { cancel?: boolean; redirectUrl?: string; reason?: string } | null;
  evaluateBlockedSubdomain: (
    details: WebRequest.OnBeforeRequestDetailsType
  ) => { cancel?: boolean; redirectUrl?: string; reason?: string } | null;
  evaluateAllowedPath: (
    details: WebRequest.OnBeforeRequestDetailsType
  ) => { cancel?: boolean; redirectUrl?: string; reason?: string } | null;
  confirmBlockedScreenNavigation?: (
    context: ConfirmBlockedScreenContext
  ) => Promise<boolean | NativeBlockedScreenConfirmation>;
  recoverCaptivePortalNavigation?: (
    context: ConfirmBlockedScreenContext & { portalRecoveryHosts?: string[] },
    options?: { isCurrentNavigation?: () => boolean }
  ) => Promise<boolean>;
  handleRuntimeMessage: (message: unknown, sender: Runtime.MessageSender) => Promise<unknown>;
  localRuntimeDependencyTimeoutMs?: number;
  navigationState?: NavigationState;
  noteMainFrameNavigation?: (context: MainFrameNavigationContext) => void;
  noteMainFrameRequest?: (context: MainFrameNavigationContext) => void;
  noteNavigationCommitted?: (context: MainFrameNavigationContext) => void;
  onRuntimeDependencyCancelled?: (context: RuntimeDependencyCancellationContext) => void;
  recordDependencyObservationEvent?: (event: OpenPathDependencyObservationEventInput) => void;
  redirectToBlockedScreen: (context: BlockedScreenContext) => Promise<void>;
  saveBlockedPageContext?: (tabId: number, domain: string, originalUrl: string | undefined) => void;
  shouldCancelPendingRuntimeDependency?: () => boolean;
}

const DEFAULT_LOCAL_RUNTIME_DEPENDENCY_SOFT_TIMEOUT_MS = 5000;
// Budgets cover queue write + agent apply + local DNS reload. They are the
// extension-side release valve: a proven-ready result releases earlier, and
// a cancelled-pending entry is repaired by the single auto-reload. Windows
// measurements (2026-09-27) showed Acrylic fast-apply latencies of ~4.2 s for
// a first batch, so render-blocking types get a wider budget; with the
// persistent transport the budgets are retuned to cover the cold port connect
// (see `runtime-dependency-protocol.ts`).
const LOCAL_RUNTIME_DEPENDENCY_SOFT_TIMEOUT_BY_TYPE_MS = new Map<string, number>([
  ['fetch', 5000],
  ['xmlhttprequest', 5000],
  ['image', 5000],
  ['imageset', 5000],
  ['script', 6000],
  ['stylesheet', 6000],
  ['font', 6000],
]);

function extractRequestHostname(url: string | undefined): string | null {
  if (!url) {
    return null;
  }

  try {
    const parsed = new URL(url);
    return parsed.hostname.toLowerCase();
  } catch {
    return null;
  }
}

function isDependencyRequestType(type: unknown): type is string {
  return typeof type === 'string' && type.length > 0 && type !== 'main_frame';
}

function normalizeCaptivePortalRecoveryHost(hostname: string | null): string | null {
  const normalized = (hostname ?? '').trim().replace(/\.$/, '').toLowerCase();
  if (!normalized || normalized.length > 253 || normalized.startsWith('*.')) {
    return null;
  }
  if (!normalized.includes('.') || normalized.endsWith('.local')) {
    return null;
  }
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(normalized) || /^\[[0-9a-f:]+\]$/i.test(normalized)) {
    return null;
  }
  if (
    !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(
      normalized
    )
  ) {
    return null;
  }
  return normalized;
}

function rememberCaptivePortalRecoveryHost(
  hostsByTab: Map<number, Set<string>>,
  tabId: number,
  hostname: string | null
): void {
  if (tabId < 0) {
    return;
  }
  const normalized = normalizeCaptivePortalRecoveryHost(hostname);
  if (!normalized) {
    return;
  }
  const hosts = hostsByTab.get(tabId) ?? new Set<string>();
  if (hosts.size < MAX_CAPTIVE_PORTAL_RECOVERY_HOSTS || hosts.has(normalized)) {
    hosts.add(normalized);
    hostsByTab.set(tabId, hosts);
  }
}

function startCaptivePortalRecoveryNavigation(
  hostsByTab: Map<number, Set<string>>,
  tabId: number,
  hostname: string | null
): void {
  if (tabId < 0) {
    return;
  }
  hostsByTab.delete(tabId);
  rememberCaptivePortalRecoveryHost(hostsByTab, tabId, hostname);
}

function getCaptivePortalRecoveryHosts(
  hostsByTab: Map<number, Set<string>>,
  tabId: number,
  triggerHost: string
): string[] {
  const hosts = new Set<string>(hostsByTab.get(tabId) ?? []);
  const normalizedTrigger = normalizeCaptivePortalRecoveryHost(triggerHost);
  if (normalizedTrigger) {
    hosts.add(normalizedTrigger);
  }
  return Array.from(hosts).slice(0, MAX_CAPTIVE_PORTAL_RECOVERY_HOSTS);
}

function resolveAnchorHost(
  details: Pick<WebRequest.OnBeforeRequestDetailsType, 'documentUrl' | 'originUrl' | 'tabId'>,
  tabAnchorHosts: Map<number, string>
): string | null {
  return (
    (details.tabId >= 0 ? (tabAnchorHosts.get(details.tabId) ?? null) : null) ??
    extractRequestHostname(details.documentUrl) ??
    extractRequestHostname(details.originUrl)
  );
}

function resolveLocalRuntimeDependencySoftTimeoutMs(
  requestType: string,
  overrideTimeoutMs: number | undefined,
  persistentTransportActive: boolean
): number {
  if (overrideTimeoutMs !== undefined) {
    return overrideTimeoutMs;
  }
  const normalizedType = requestType.toLowerCase();
  if (persistentTransportActive) {
    return (
      LOCAL_RUNTIME_DEPENDENCY_PERSISTENT_SOFT_TIMEOUT_BY_TYPE_MS.get(normalizedType) ??
      DEFAULT_LOCAL_RUNTIME_DEPENDENCY_PERSISTENT_SOFT_TIMEOUT_MS
    );
  }
  return (
    LOCAL_RUNTIME_DEPENDENCY_SOFT_TIMEOUT_BY_TYPE_MS.get(normalizedType) ??
    DEFAULT_LOCAL_RUNTIME_DEPENDENCY_SOFT_TIMEOUT_MS
  );
}

interface RuntimeDependencyWaitOptions {
  onCancelled: (context: RuntimeDependencyCancellationContext) => void;
  overrideTimeoutMs?: number;
  /**
   * Live check for the persistent transport + auto-reload capability. It is
   * consulted when the budget is armed (budget family) and again at expiry
   * (cancel vs release), because a cold port may become ready mid-wait.
   */
  shouldCancel: () => boolean;
}

/**
 * Waits for the native allow flow to prove readiness within the request's
 * budget. With the persistent transport active, a budget expiry while the
 * entry is still pending cancels the request (no DNS query, no negative
 * answer) so the single auto-reload can repair the page once the dependency
 * becomes ready. Without it the historical release behavior is preserved.
 */
function waitForLocalRuntimeDependencyDecision(
  promise: Promise<unknown>,
  requestType: string,
  context: RuntimeDependencyCancellationContext,
  options: RuntimeDependencyWaitOptions
): Promise<Record<string, never> | { cancel: true }> {
  void promise.catch((error: unknown) => {
    logger.error('[Monitor] Error applying local runtime dependency', {
      error: getErrorMessage(error),
      requestType,
    });
  });

  const timeoutMs = resolveLocalRuntimeDependencySoftTimeoutMs(
    requestType,
    options.overrideTimeoutMs,
    options.shouldCancel()
  );

  return new Promise((resolve) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const settle = (value: Record<string, never> | { cancel: true }): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer !== null) {
        clearTimeout(timer);
      }
      resolve(value);
    };

    timer = setTimeout(() => {
      if (settled) {
        return;
      }
      if (options.shouldCancel()) {
        logger.debug('[Monitor] Local runtime dependency cancelled at budget', {
          requestType,
          timeoutMs,
          dependencyHost: context.dependencyHost,
        });
        try {
          options.onCancelled(context);
        } catch (error) {
          logger.warn('[Monitor] Error recordando dependencia cancelada', {
            error: getErrorMessage(error),
          });
        }
        settle({ cancel: true });
        return;
      }

      // Local diagnostic only: the request was released before the native host
      // proved readiness, which is the signal used to retune the budgets.
      logger.debug('[Monitor] Local runtime dependency soft timeout reached', {
        requestType,
        timeoutMs,
      });
      settle({});
    }, timeoutMs);

    // Only a proven-ready result releases the request early; pending/queued
    // results keep waiting until the budget, and terminal failures
    // (denied/error) fall through immediately so the request fails fast.
    promise.then(
      (response) => {
        if (isPendingRuntimeDependencyResponse(response)) {
          return;
        }
        settle({});
      },
      () => {
        settle({});
      }
    );
  });
}

function createRuntimeMessageResponder(
  options: Pick<BackgroundListenersOptions, 'allowLocalRuntimeDependency' | 'handleRuntimeMessage'>
): (
  message: unknown,
  sender: Runtime.MessageSender,
  sendResponse: (response: unknown) => void
) => unknown {
  return (message, sender, sendResponse) => {
    const captiveRuntimeDependency = parseCaptivePortalRuntimeDependencyMessage(message);
    const responsePromise =
      captiveRuntimeDependency && options.allowLocalRuntimeDependency
        ? Promise.resolve(options.allowLocalRuntimeDependency(captiveRuntimeDependency)).catch(
            (error: unknown) => ({ success: false, error: getErrorMessage(error) })
          )
        : Promise.resolve(options.handleRuntimeMessage(message, sender)).catch(
            (error: unknown) => ({
              success: false,
              error: getErrorMessage(error),
            })
          );

    void responsePromise.then((response) => {
      sendResponse(response);
    });

    return responsePromise;
  };
}

function parseCaptivePortalRuntimeDependencyMessage(message: unknown): {
  anchorHost: string;
  dependencyHost: string;
  requestType: string;
} | null {
  if (!message || typeof message !== 'object') {
    return null;
  }

  const candidate = message as {
    action?: unknown;
    anchorHost?: unknown;
    dependencyHost?: unknown;
    requestType?: unknown;
  };
  if (candidate.action !== 'openpathCaptivePortalRuntimeDependency') {
    return null;
  }
  if (
    typeof candidate.anchorHost !== 'string' ||
    typeof candidate.dependencyHost !== 'string' ||
    typeof candidate.requestType !== 'string'
  ) {
    return null;
  }

  const anchorHost = candidate.anchorHost.trim().toLowerCase();
  const dependencyHost = candidate.dependencyHost.trim().toLowerCase();
  const requestType = candidate.requestType.trim().toLowerCase();
  if (!anchorHost || !dependencyHost || !isDependencyRequestType(requestType)) {
    return null;
  }

  return {
    anchorHost,
    dependencyHost,
    requestType,
  };
}

export function registerBackgroundListeners(options: BackgroundListenersOptions): void {
  const tabAnchorHosts = new Map<number, string>();
  const captivePortalRecoveryHostsByTab = new Map<number, Set<string>>();
  const cancelledPendingRequests = new Map<string, number>();

  function rememberCancelledPendingRequest(context: RuntimeDependencyCancellationContext): void {
    if (!context.requestId) {
      return;
    }
    const now = Date.now();
    for (const [requestId, cancelledAt] of cancelledPendingRequests) {
      if (now - cancelledAt > CANCELLED_PENDING_REQUEST_TTL_MS) {
        cancelledPendingRequests.delete(requestId);
      }
    }
    cancelledPendingRequests.set(context.requestId, now);
  }

  function wasCancelledPendingRequest(requestId: string | undefined): boolean {
    if (!requestId) {
      return false;
    }
    const cancelledAt = cancelledPendingRequests.get(requestId);
    if (cancelledAt === undefined) {
      return false;
    }
    if (Date.now() - cancelledAt > CANCELLED_PENDING_REQUEST_TTL_MS) {
      cancelledPendingRequests.delete(requestId);
      return false;
    }
    return true;
  }

  const configuredCaptivePortalRecovery = options.recoverCaptivePortalNavigation;
  const recoverCaptivePortalNavigation = configuredCaptivePortalRecovery
    ? (
        context: ConfirmBlockedScreenContext,
        recoveryOptions?: { isCurrentNavigation?: () => boolean }
      ): Promise<boolean> => {
        const portalRecoveryHosts = getCaptivePortalRecoveryHosts(
          captivePortalRecoveryHostsByTab,
          context.tabId,
          context.hostname
        );
        return configuredCaptivePortalRecovery(
          portalRecoveryHosts.length > 1 ? { ...context, portalRecoveryHosts } : context,
          recoveryOptions
        );
      }
    : undefined;
  const blockedScreenNavigation = createBlockedScreenNavigationController({
    addBlockedDomain: options.addBlockedDomain,
    ...(options.confirmBlockedScreenNavigation
      ? { confirmBlockedScreenNavigation: options.confirmBlockedScreenNavigation }
      : {}),
    ...(recoverCaptivePortalNavigation ? { recoverCaptivePortalNavigation } : {}),
    getBlockedScreenUrl: () => options.browser.runtime.getURL(BLOCKED_SCREEN_PATH),
    getCurrentTabUrl: async (tabId) => {
      const tab = await options.browser.tabs.get(tabId);
      return tab.url;
    },
    ...(options.navigationState ? { navigationState: options.navigationState } : {}),
    redirectToBlockedScreen: options.redirectToBlockedScreen,
    ...(options.saveBlockedPageContext
      ? { saveBlockedPageContext: options.saveBlockedPageContext }
      : {}),
  });
  options.browser.webRequest.onBeforeRequest.addListener(
    (details: WebRequest.OnBeforeRequestDetailsType) => {
      const dependencyHost = extractRequestHostname(details.url);
      const anchorHost = resolveAnchorHost(details, tabAnchorHosts);
      if (details.type === 'main_frame' && details.tabId >= 0) {
        options.noteMainFrameRequest?.({
          tabId: details.tabId,
          url: details.url,
          method: details.method,
        });
      }
      options.recordDependencyObservationEvent?.({
        source: 'webRequest.onBeforeRequest',
        tabId: details.tabId,
        frameId: details.frameId,
        requestId: details.requestId,
        type: details.type,
        ...(anchorHost ? { anchorHost } : {}),
        ...(dependencyHost ? { dependencyHost } : {}),
      });
      const result =
        options.evaluateBlockedPath(details) ??
        options.evaluateBlockedSubdomain(details) ??
        options.evaluateAllowedPath(details) ??
        evaluateGoogleGameBlocking(details, {
          extensionOrigin: options.browser.runtime.getURL('/'),
        });
      if (!result) {
        if (details.type === 'main_frame' && details.tabId >= 0 && dependencyHost) {
          tabAnchorHosts.set(details.tabId, dependencyHost);
          startCaptivePortalRecoveryNavigation(
            captivePortalRecoveryHostsByTab,
            details.tabId,
            dependencyHost
          );
          return;
        }

        if (anchorHost && dependencyHost && anchorHost !== dependencyHost) {
          rememberCaptivePortalRecoveryHost(
            captivePortalRecoveryHostsByTab,
            details.tabId,
            anchorHost
          );
          rememberCaptivePortalRecoveryHost(
            captivePortalRecoveryHostsByTab,
            details.tabId,
            dependencyHost
          );
        }

        if (
          !options.allowLocalRuntimeDependency ||
          !isDependencyRequestType(details.type) ||
          details.tabId < 0 ||
          !anchorHost ||
          !dependencyHost ||
          anchorHost === dependencyHost
        ) {
          return;
        }

        return waitForLocalRuntimeDependencyDecision(
          options.allowLocalRuntimeDependency({
            anchorHost,
            dependencyHost,
            requestType: details.type,
          }),
          details.type,
          {
            anchorHost,
            dependencyHost,
            frameId: details.frameId,
            requestType: details.type,
            tabId: details.tabId,
            ...(details.documentUrl ? { documentUrl: details.documentUrl } : {}),
            ...(details.originUrl ? { originUrl: details.originUrl } : {}),
            ...(details.requestId ? { requestId: details.requestId } : {}),
          },
          {
            shouldCancel: options.shouldCancelPendingRuntimeDependency ?? ((): boolean => false),
            ...(options.localRuntimeDependencyTimeoutMs !== undefined
              ? { overrideTimeoutMs: options.localRuntimeDependencyTimeoutMs }
              : {}),
            onCancelled: (context) => {
              rememberCancelledPendingRequest(context);
              options.recordDependencyObservationEvent?.({
                source: 'webRequest.onBeforeRequest',
                tabId: context.tabId,
                frameId: context.frameId,
                ...(context.requestId ? { requestId: context.requestId } : {}),
                type: context.requestType,
                kind: 'cancelled-pending',
                anchorHost: context.anchorHost,
                dependencyHost: context.dependencyHost,
              });
              options.onRuntimeDependencyCancelled?.(context);
            },
          }
        ).then((decision) => ('cancel' in decision ? { cancel: true } : {}));
      }

      if (details.type === 'main_frame' && details.tabId >= 0 && dependencyHost) {
        tabAnchorHosts.set(details.tabId, dependencyHost);
        startCaptivePortalRecoveryNavigation(
          captivePortalRecoveryHostsByTab,
          details.tabId,
          dependencyHost
        );
      }

      const hostname = extractHostname(details.url) ?? t('blockedUnknownDomain');

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
        options.saveBlockedPageContext?.(details.tabId, hostname, details.url);
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
      const cancelledPending = wasCancelledPendingRequest(details.requestId);
      const anchorHost = resolveAnchorHost(details, tabAnchorHosts);
      const dependencyHost = extractRequestHostname(details.url);
      if (anchorHost && dependencyHost && anchorHost !== dependencyHost) {
        rememberCaptivePortalRecoveryHost(
          captivePortalRecoveryHostsByTab,
          details.tabId,
          anchorHost
        );
        rememberCaptivePortalRecoveryHost(
          captivePortalRecoveryHostsByTab,
          details.tabId,
          dependencyHost
        );
      } else if (details.frameId === 0 && dependencyHost) {
        rememberCaptivePortalRecoveryHost(
          captivePortalRecoveryHostsByTab,
          details.tabId,
          dependencyHost
        );
      }
      options.recordDependencyObservationEvent?.({
        source: 'webRequest.onErrorOccurred',
        tabId: details.tabId,
        frameId: details.frameId,
        requestId: details.requestId,
        type: details.type,
        ...(anchorHost ? { anchorHost } : {}),
        ...(dependencyHost ? { dependencyHost } : {}),
        ...(cancelledPending ? { kind: 'cancelled-pending' } : {}),
      });
      if (cancelledPending) {
        // Our own budget cancellation is not a blocked domain: it must not
        // feed the badge/blocked screen nor trigger a native policy check.
        return;
      }
      const hostname = extractHostname(details.url);
      if (!hostname) {
        return;
      }

      if (details.tabId >= 0) {
        void blockedScreenNavigation
          .handleBlockedScreenNavigationError(details, {
            recordBlockedDomain: true,
            requestType: details.type,
          })
          .catch((error: unknown) => {
            logger.warn('[Monitor] Falló la gestión del error de navegación', {
              error: getErrorMessage(error),
              tabId: details.tabId,
            });
          });
      }
    },
    { urls: ['<all_urls>'] }
  );

  options.browser.webNavigation.onBeforeNavigate.addListener(
    (details: WebNavigation.OnBeforeNavigateDetailsType) => {
      const navigationHost = extractRequestHostname(details.url);
      if (details.frameId === 0 && navigationHost) {
        tabAnchorHosts.set(details.tabId, navigationHost);
        startCaptivePortalRecoveryNavigation(
          captivePortalRecoveryHostsByTab,
          details.tabId,
          navigationHost
        );
        options.noteMainFrameNavigation?.({ tabId: details.tabId, url: details.url });
      }
      options.recordDependencyObservationEvent?.({
        source: 'webNavigation.onBeforeNavigate',
        tabId: details.tabId,
        frameId: details.frameId,
        ...(navigationHost ? { anchorHost: navigationHost } : {}),
      });
      void blockedScreenNavigation
        .handleNativePolicyNavigationPreflight({
          frameId: details.frameId,
          tabId: details.tabId,
          url: details.url,
        })
        .catch((error: unknown) => {
          logger.warn('[Monitor] Falló el preflight de navegación', {
            error: getErrorMessage(error),
            tabId: details.tabId,
          });
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

  // onCommitted marks the current navigation's document commit; the auto-reload
  // module uses it to keep the navigation identity current without treating it
  // as a newer navigation.
  const webNavigationOnCommitted = (
    options.browser.webNavigation as unknown as {
      onCommitted?: {
        addListener: (listener: (details: WebNavigation.OnCommittedDetailsType) => void) => void;
      };
    }
  ).onCommitted;
  webNavigationOnCommitted?.addListener((details: WebNavigation.OnCommittedDetailsType) => {
    if (details.frameId !== 0) {
      return;
    }
    options.noteNavigationCommitted?.({ tabId: details.tabId, url: details.url });
  });

  options.browser.webNavigation.onHistoryStateUpdated.addListener(
    (details: WebNavigation.OnHistoryStateUpdatedDetailsType) => {
      if (details.frameId !== 0) {
        return;
      }
      const result = options.evaluateAllowedPath({
        type: 'main_frame',
        url: details.url,
        tabId: details.tabId,
      } as WebRequest.OnBeforeRequestDetailsType);
      if (!result?.redirectUrl) {
        return;
      }
      const hostname = extractHostname(details.url) ?? t('blockedUnknownDomain');
      if (details.tabId >= 0) {
        options.addBlockedDomain(
          details.tabId,
          hostname,
          result.reason ?? `${ALLOWED_PATH_BLOCK_REASON}:unknown`,
          null
        );
      }
      void options.browser.tabs.update(details.tabId, { url: result.redirectUrl });
    }
  );

  options.browser.webNavigation.onErrorOccurred.addListener(
    (details: WebNavigation.OnErrorOccurredDetailsType) => {
      const navigationHost = extractRequestHostname(details.url);
      if (details.frameId === 0 && navigationHost) {
        rememberCaptivePortalRecoveryHost(
          captivePortalRecoveryHostsByTab,
          details.tabId,
          navigationHost
        );
      }
      options.recordDependencyObservationEvent?.({
        source: 'webNavigation.onErrorOccurred',
        tabId: details.tabId,
        frameId: details.frameId,
        ...(navigationHost ? { anchorHost: navigationHost } : {}),
      });
      const maybeError = (details as { error?: unknown }).error;
      if (typeof maybeError !== 'string' || maybeError.length === 0) {
        return;
      }

      void blockedScreenNavigation
        .handleBlockedScreenNavigationError(
          {
            error: maybeError,
            frameId: details.frameId,
            tabId: details.tabId,
            url: details.url,
          },
          {
            recordBlockedDomain: true,
          }
        )
        .catch((error: unknown) => {
          logger.warn('[Monitor] Falló la gestión del error de navegación', {
            error: getErrorMessage(error),
            tabId: details.tabId,
          });
        });
    }
  );

  options.browser.tabs.onRemoved.addListener((tabId: number) => {
    blockedScreenNavigation.disposeTab(tabId);
    tabAnchorHosts.delete(tabId);
    captivePortalRecoveryHostsByTab.delete(tabId);
    options.disposeTab(tabId);
    logger.debug(`[Monitor] Tab ${tabId.toString()} cerrada, datos eliminados`);
  });

  options.browser.runtime.onMessage.addListener(
    createRuntimeMessageResponder({
      ...(options.allowLocalRuntimeDependency
        ? { allowLocalRuntimeDependency: options.allowLocalRuntimeDependency }
        : {}),
      handleRuntimeMessage: options.handleRuntimeMessage,
    }) as Parameters<typeof options.browser.runtime.onMessage.addListener>[0]
  );
}
