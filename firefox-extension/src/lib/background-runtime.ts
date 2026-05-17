import type { Browser } from 'webextension-polyfill';
import { registerBackgroundListeners } from './background-listeners.js';
import { createBackgroundMessageHandler } from './background-message-handler.js';
import { createBackgroundPathRulesController } from './background-path-rules.js';
import { createBackgroundSubdomainRulesController } from './background-subdomain-rules.js';
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

interface BlockedScreenContext {
  tabId: number;
  hostname: string;
  error: string;
  origin: string | null;
}

interface ConfirmBlockedScreenContext extends BlockedScreenContext {
  url: string;
}

const NATIVE_HOST_NAME = 'whitelist_native_host';
const BLOCKED_DNS_SENTINELS = new Set(['0.0.0.0', '::', '192.0.2.1', '100::']);
interface BackgroundRuntimeOptions {
  hostName?: string;
}

interface BackgroundRuntime {
  init: () => Promise<void>;
}

export function isNativePolicyBlockedResult(
  result: VerifyResponse['results'][number] | undefined
): boolean {
  if (!result || result.policyActive === false || result.error) {
    return false;
  }

  const resolvedIp =
    typeof result.resolvedIp === 'string' && result.resolvedIp.length > 0
      ? result.resolvedIp
      : null;
  const resolves =
    result.resolves ?? (resolvedIp !== null && !BLOCKED_DNS_SENTINELS.has(resolvedIp));
  return !result.inWhitelist && !resolves;
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

  async function checkDomainsWithNative(domains: string[]): Promise<VerifyResponse> {
    return await nativeMessagingClient.checkDomains(domains);
  }

  async function confirmBlockedScreenNavigation(
    context: ConfirmBlockedScreenContext
  ): Promise<boolean> {
    const response = await checkDomainsWithNative([context.hostname]);
    if (!response.success) {
      return false;
    }

    const result = response.results.find((item) => item.domain === context.hostname);
    return isNativePolicyBlockedResult(result);
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
      message: 'Reintentando actualizacion local',
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
      message: success ? 'Actualizacion local completada' : 'Sigue fallando la actualizacion local',
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
      },
      evaluateBlockedPath: blockedPathRulesController.evaluateRequest,
      evaluateBlockedSubdomain: blockedSubdomainRulesController.evaluateRequest,
      confirmBlockedScreenNavigation,
      handleRuntimeMessage,
      recordDependencyObservationEvent: recordOpenPathDependencyObservationEvent,
      redirectToBlockedScreen,
      saveBlockedPageContext,
    });
    await blockedPathRulesController.init();
    await blockedSubdomainRulesController.init();
    blockedPathRulesController.startRefreshLoop();
    blockedSubdomainRulesController.startRefreshLoop();
    logger.info('[Monitor de Bloqueos] Background script v2.0.0 (MV3) cargado');
  }

  return {
    init,
  };
}
