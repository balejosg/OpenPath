import type { Browser } from 'webextension-polyfill';
import { registerBackgroundListeners } from './background-listeners.js';
import { createBackgroundMessageHandler } from './background-message-handler.js';
import { createBackgroundPathRulesController } from './background-path-rules.js';
import { createBackgroundSubdomainRulesController } from './background-subdomain-rules.js';
import { createBackgroundTabReconciliationController } from './background-tab-reconciliation.js';
import { logger, getErrorMessage } from './logger.js';
import {
  DEFAULT_REQUEST_CONFIG,
  getRequestApiEndpoints,
  hasValidRequestConfig,
  loadRequestConfigWithNativeFallback,
} from './config-storage.js';
import { loadNativeRequestConfigWithSender } from './config-storage-native.js';
import { buildBlockedDomainSubmitBody } from './blocked-request.js';
import { createBlockedMonitorState } from './blocked-monitor-state.js';
import {
  createNativeMessagingClient,
  type NativeResponse,
  type VerifyResponse,
} from './native-messaging-client.js';
import { createCaptivePortalRecoveryController } from './captive-portal-recovery-controller.js';
import {
  submitBlockedDomainRequest as submitBlockedDomainRequestViaApi,
  type SubmitBlockedDomainInput,
  type SubmitBlockedDomainResult,
} from './request-api.js';
import {
  buildBlockedScreenRedirectUrl,
  extractHostname,
  type NativeBlockedPathsResponse,
} from './path-blocking.js';
import type { NativeBlockedSubdomainsResponse } from './subdomain-blocking.js';
import {
  clearOpenPathDependencyObservationDiagnostics,
  configureOpenPathDependencyObservationDiagnostics,
  getOpenPathDependencyObservationDiagnostics,
  recordOpenPathDependencyObservationEvent,
} from './dependency-observation-diagnostics.js';
import { t } from './i18n.js';
import { createBlockedScreenConfirmer } from './blocked-screen-confirmer.js';

interface BlockedScreenContext {
  tabId: number;
  hostname: string;
  error: string;
  origin: string | null;
}

interface ConfirmBlockedScreenContext extends BlockedScreenContext {
  url: string;
}

interface CaptivePortalBrowserApi {
  getState?: () => Promise<string>;
  onConnectivityAvailable?: {
    addListener: (listener: () => void) => void;
  };
  onStateChanged?: {
    addListener: (listener: (details: { state: string }) => void) => void;
  };
}

const NATIVE_HOST_NAME = 'whitelist_native_host';
interface BackgroundRuntimeOptions {
  hostName?: string;
  now?: () => number;
}

interface BackgroundRuntime {
  init: () => Promise<void>;
}

export function createBackgroundRuntime(
  browser: Browser,
  options: BackgroundRuntimeOptions = {}
): BackgroundRuntime {
  const inFlightAutoRequests = new Map<string, Promise<void>>();
  const blockedPageContextByTabAndDomain = new Map<
    string,
    { domain: string; originalUrl: string }
  >();
  const latestBlockedPageContextByDomain = new Map<
    string,
    { domain: string; originalUrl: string }
  >();
  const portalRecoveryEligibleByHost = new Map<string, boolean>();
  const now = options.now ?? ((): number => Date.now());
  const blockedMonitorState = createBlockedMonitorState(
    {
      setBadgeText: (options) => browser.action.setBadgeText(options),
      setBadgeBackgroundColor: (options) => browser.action.setBadgeBackgroundColor(options),
    },
    {
      extractHostname,
      inFlightAutoRequests,
    }
  );

  const nativeMessagingClient = createNativeMessagingClient({
    hostName: options.hostName ?? NATIVE_HOST_NAME,
    logger,
  });
  const extensionOrigin = browser.runtime.getURL('/');
  const blockedPathRulesController = createBackgroundPathRulesController({
    extensionOrigin,
    getBlockedPaths: async () =>
      (await nativeMessagingClient.sendMessage({
        action: 'get-blocked-paths',
      })) as NativeBlockedPathsResponse,
  });
  const blockedSubdomainRulesController = createBackgroundSubdomainRulesController({
    extensionOrigin,
    getBlockedSubdomains: async () =>
      (await nativeMessagingClient.sendMessage({
        action: 'get-blocked-subdomains',
      })) as NativeBlockedSubdomainsResponse,
  });
  const captivePortalRecoveryController = createCaptivePortalRecoveryController({
    getPortalState: async () => getCaptivePortalApi()?.getState?.(),
    isNativePortalRecoveryEligible: ({ hostname }) =>
      Promise.resolve(portalRecoveryEligibleByHost.get(hostname.trim().toLowerCase()) === true),
    logger,
    recoverCaptivePortalNavigation: (input) =>
      nativeMessagingClient.recoverCaptivePortalNavigation(input),
    retryNavigation: async (tabId, url) => {
      await browser.tabs.update(tabId, { url });
    },
  });

  async function redirectToBlockedScreen(context: BlockedScreenContext): Promise<void> {
    try {
      const redirectUrl = buildBlockedScreenRedirectUrl({
        extensionOrigin: browser.runtime.getURL('/'),
        hostname: context.hostname,
        error: context.error,
        origin: context.origin,
      });
      await browser.tabs.update(context.tabId, { url: redirectUrl });
    } catch (error) {
      logger.error('[Monitor] No se pudo mostrar pantalla de bloqueo', {
        tabId: context.tabId,
        hostname: context.hostname,
        error: getErrorMessage(error),
      });
    }
  }

  const tabReconciliationController = createBackgroundTabReconciliationController({
    getPolicyVersion: async () => {
      const response = (await nativeMessagingClient.sendMessage({
        action: 'get-policy-version',
      })) as { success?: boolean; version?: string; error?: string };
      return {
        success: response.success === true,
        version: typeof response.version === 'string' ? response.version : '',
        ...(typeof response.error === 'string' ? { error: response.error } : {}),
      };
    },
    checkDomains: (domains) => nativeMessagingClient.checkDomains(domains),
    queryTabs: () => browser.tabs.query({}),
    redirectToBlockedScreen: ({ tabId, hostname, error }) =>
      redirectToBlockedScreen({ tabId, hostname, error, origin: null }),
  });

  const {
    addBlockedDomain,
    clearBlockedDomains,
    clearTabRuntimeState,
    disposeTab,
    domainStatuses,
    getBlockedDomainsForTab,
    getDomainStatusesForTab,
    setDomainStatus,
  } = blockedMonitorState;

  function buildBlockedPageContextKey(tabId: number, domain: string): string {
    return `${tabId.toString()}:${domain.trim().toLowerCase()}`;
  }

  function saveBlockedPageContext(
    tabId: number,
    domain: string,
    originalUrl: string | undefined
  ): void {
    const normalizedDomain = domain.trim().toLowerCase();
    if (tabId < 0 || normalizedDomain.length === 0 || !originalUrl) {
      return;
    }

    const context = { domain: normalizedDomain, originalUrl };
    blockedPageContextByTabAndDomain.set(
      buildBlockedPageContextKey(tabId, normalizedDomain),
      context
    );
    latestBlockedPageContextByDomain.set(normalizedDomain, context);
  }

  function getBlockedPageContext(
    tabId: number | null,
    domain: string
  ): { domain: string; originalUrl: string } | null {
    const normalizedDomain = domain.trim().toLowerCase();
    if (normalizedDomain.length === 0) {
      return null;
    }

    if (tabId !== null) {
      const byTab = blockedPageContextByTabAndDomain.get(
        buildBlockedPageContextKey(tabId, normalizedDomain)
      );
      if (byTab) {
        return byTab;
      }
    }

    return latestBlockedPageContextByDomain.get(normalizedDomain) ?? null;
  }

  async function checkDomainsWithNative(
    domains: string[],
    context?: { error?: string; source?: string }
  ): Promise<VerifyResponse> {
    return await nativeMessagingClient.checkDomains(domains, context);
  }

  function getCaptivePortalApi(): CaptivePortalBrowserApi | undefined {
    return (browser as unknown as { captivePortal?: CaptivePortalBrowserApi }).captivePortal;
  }

  const blockedScreenConfirmer = createBlockedScreenConfirmer({
    checkDomains: checkDomainsWithNative,
    now,
    // The runtime owns the shared eligibility map (also read by the captive-portal controller) and
    // the recovery limiter, so it decides what an eligibility change means.
    recordPortalRecoveryEligibility: (hostname, eligible) => {
      if (portalRecoveryEligibleByHost.get(hostname) !== eligible) {
        portalRecoveryEligibleByHost.set(hostname, eligible);
        captivePortalRecoveryController.clearLimiter();
      }
    },
  });

  async function recoverCaptivePortalNavigation(
    context: ConfirmBlockedScreenContext,
    options?: { isCurrentNavigation?: () => boolean }
  ): Promise<boolean> {
    return await captivePortalRecoveryController.recoverNavigation(context, options);
  }

  function registerCaptivePortalListeners(): void {
    const captivePortal = getCaptivePortalApi();
    captivePortal?.onConnectivityAvailable?.addListener(() => {
      void captivePortalRecoveryController.handleConnectivityAvailable();
    });
    captivePortal?.onStateChanged?.addListener((details) => {
      void captivePortalRecoveryController.handlePortalStateChanged(details.state);
    });
  }

  async function isNativeHostAvailable(): Promise<boolean> {
    return await nativeMessagingClient.isAvailable();
  }

  async function getOpenPathDiagnostics(domains: string[]): Promise<unknown> {
    const requestedDomains = domains
      .map((domain) => domain.trim().toLowerCase())
      .filter((domain) => domain.length > 0);
    const [
      nativeAvailable,
      nativeCheck,
      nativeBlockedPaths,
      nativeBlockedSubdomains,
      nativeRequestConfig,
    ] = await Promise.all([
      isNativeHostAvailable().catch(() => false),
      requestedDomains.length > 0
        ? checkDomainsWithNative(requestedDomains).catch((error: unknown) => ({
            success: false,
            results: [],
            error: getErrorMessage(error),
          }))
        : Promise.resolve({ success: true, results: [] }),
      nativeMessagingClient
        .sendMessage({ action: 'get-blocked-paths' })
        .catch((error: unknown) => ({ success: false, error: getErrorMessage(error) })),
      nativeMessagingClient
        .sendMessage({ action: 'get-blocked-subdomains' })
        .catch((error: unknown) => ({ success: false, error: getErrorMessage(error) })),
      (async (): Promise<{
        enabled: boolean;
        endpointCount: number;
        nativeEndpointCount: number;
        valid: boolean;
      }> => {
        const nativeFallback = await loadNativeRequestConfigWithSender((message) =>
          nativeMessagingClient.sendMessage(message)
        );
        const requestConfig = await loadRequestConfigWithNativeFallback(nativeFallback);
        return {
          nativeEndpointCount: getRequestApiEndpoints({
            ...DEFAULT_REQUEST_CONFIG,
            ...nativeFallback,
          }).length,
          endpointCount: getRequestApiEndpoints(requestConfig).length,
          enabled: requestConfig.enableRequests,
          valid: hasValidRequestConfig(requestConfig),
        };
      })().catch((error: unknown) => ({ success: false, error: getErrorMessage(error) })),
    ]);

    return {
      success: true,
      extensionOrigin,
      manifestVersion: browser.runtime.getManifest().version,
      nativeAvailable,
      nativeCheck,
      nativeBlockedPaths,
      nativeBlockedSubdomains,
      nativeRequestConfig,
      pathRules: blockedPathRulesController.getDebugState(),
      subdomainRules: blockedSubdomainRulesController.getDebugState(),
    };
  }

  async function submitBlockedDomainRequest(
    input: SubmitBlockedDomainInput
  ): Promise<SubmitBlockedDomainResult> {
    return await submitBlockedDomainRequestViaApi(input, {
      buildBlockedDomainSubmitBody,
      getClientVersion: () => browser.runtime.getManifest().version,
      getRequestApiEndpoints: (config) =>
        getRequestApiEndpoints({
          ...config,
          debugMode: false,
          sharedSecret: '',
        }),
      loadRequestConfig: async () => {
        const nativeFallback = await loadNativeRequestConfigWithSender((message) =>
          nativeMessagingClient.sendMessage(message)
        );
        return loadRequestConfigWithNativeFallback(nativeFallback);
      },
      sendNativeMessage: (message) => nativeMessagingClient.sendMessage(message),
    });
  }

  async function retryLocalUpdate(tabId: number, hostname: string): Promise<{ success: boolean }> {
    const currentStatus = domainStatuses[tabId]?.get(hostname);
    const requestTypePatch = currentStatus?.requestType
      ? { requestType: currentStatus.requestType }
      : {};

    setDomainStatus(tabId, hostname, {
      state: 'pending',
      updatedAt: Date.now(),
      message: t('popupLocalUpdateRetrying'),
      ...requestTypePatch,
    });

    const nativeUpdate = await nativeMessagingClient
      .requestLocalWhitelistUpdate([hostname])
      .catch(() => false);
    const [pathRefresh, subdomainRefresh] = await Promise.all([
      blockedPathRulesController.refresh(true).catch(() => false),
      blockedSubdomainRulesController.refresh(true).catch(() => false),
    ]);
    const success = nativeUpdate && pathRefresh && subdomainRefresh;

    setDomainStatus(tabId, hostname, {
      state: success ? 'autoApproved' : 'localUpdateError',
      updatedAt: Date.now(),
      message: success ? t('popupLocalUpdateCompleted') : t('popupLocalUpdateStillFailing'),
      ...requestTypePatch,
    });

    return { success };
  }
  const forceBlockedPathRulesRefresh = blockedPathRulesController.forceRefresh;
  const forceBlockedSubdomainRulesRefresh = blockedSubdomainRulesController.forceRefresh;

  const handleRuntimeMessage = createBackgroundMessageHandler({
    clearBlockedDomains,
    evaluateBlockedPathDebug: (input) =>
      blockedPathRulesController.evaluateRequest({ type: input.type, url: input.url } as never),
    evaluateBlockedSubdomainDebug: (input) =>
      blockedSubdomainRulesController.evaluateRequest({
        type: input.type,
        url: input.url,
      } as never),
    forceBlockedPathRulesRefresh,
    forceBlockedSubdomainRulesRefresh,
    getBlockedDomainsForTab,
    getBlockedPageContext,
    getDomainStatusesForTab,
    getErrorMessage,
    getMachineToken: () => nativeMessagingClient.sendMessage({ action: 'get-machine-token' }),
    getNativeBlockedPathsDebug: async () =>
      (await nativeMessagingClient.sendMessage({
        action: 'get-blocked-paths',
      })) as NativeBlockedPathsResponse,
    getNativeBlockedSubdomainsDebug: async () =>
      (await nativeMessagingClient.sendMessage({
        action: 'get-blocked-subdomains',
      })) as NativeBlockedSubdomainsResponse,
    getOpenPathDiagnostics,
    configureOpenPathDependencyObservationDiagnostics: (config) =>
      configureOpenPathDependencyObservationDiagnostics({
        ...config,
        verifyHost: async (hostname) => checkDomainsWithNative([hostname]),
      }),
    getOpenPathDependencyObservationDiagnostics,
    clearOpenPathDependencyObservationDiagnostics,
    recordOpenPathDependencyObservationEvent,
    getPathRulesDebug: blockedPathRulesController.getDebugState,
    getSubdomainRulesDebug: blockedSubdomainRulesController.getDebugState,
    getSystemHostname: () => nativeMessagingClient.sendMessage({ action: 'get-hostname' }),
    isNativeHostAvailable,
    retryLocalUpdate,
    submitBlockedDomainRequest,
    triggerWhitelistUpdate: async (domains: string[] = []): Promise<NativeResponse> => {
      const response = (await nativeMessagingClient.sendMessage({
        action: 'update-whitelist',
        ...(domains.length > 0 ? { domains } : {}),
      })) as NativeResponse;
      if (response.success) {
        // Policy just changed: drop cached block decisions so a freshly-allowed domain is not held
        // on the blocked screen by a stale "blocked" verdict.
        blockedScreenConfirmer.clearCache();
        await Promise.all([
          blockedPathRulesController.refresh(true),
          blockedSubdomainRulesController.refresh(true),
        ]);
      }
      return response;
    },
    verifyDomains: checkDomainsWithNative,
  });

  async function init(): Promise<void> {
    // Pre-warm the native connection so the first blocked-screen confirmation does not pay the
    // connect() cost while the user waits for the page. Fire-and-forget; warmUp never throws.
    void nativeMessagingClient.warmUp();
    registerBackgroundListeners({
      addBlockedDomain: (tabId, hostname, error, origin) => {
        addBlockedDomain(tabId, hostname, error, origin ?? undefined);
      },
      browser,
      allowLocalRuntimeDependency: (input) =>
        nativeMessagingClient.allowLocalRuntimeDependency(input),
      clearTabRuntimeState,
      disposeTab: (tabId) => {
        disposeTab(tabId);
        for (const key of blockedPageContextByTabAndDomain.keys()) {
          if (key.startsWith(`${tabId.toString()}:`)) {
            blockedPageContextByTabAndDomain.delete(key);
          }
        }
        captivePortalRecoveryController.disposeTab(tabId);
      },
      evaluateBlockedPath: blockedPathRulesController.evaluateRequest,
      evaluateBlockedSubdomain: blockedSubdomainRulesController.evaluateRequest,
      confirmBlockedScreenNavigation: blockedScreenConfirmer.confirm,
      recoverCaptivePortalNavigation,
      handleRuntimeMessage,
      recordDependencyObservationEvent: recordOpenPathDependencyObservationEvent,
      redirectToBlockedScreen,
      saveBlockedPageContext,
    });
    registerCaptivePortalListeners();
    await blockedPathRulesController.init();
    await blockedSubdomainRulesController.init();
    await tabReconciliationController.init();
    blockedPathRulesController.startRefreshLoop();
    blockedSubdomainRulesController.startRefreshLoop();
    tabReconciliationController.startRefreshLoop();
    logger.info('[Blocking Monitor] Background script v2.0.0 (MV3) loaded');
  }

  return {
    init,
  };
}
