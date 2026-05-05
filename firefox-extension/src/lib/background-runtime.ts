import type { Browser } from 'webextension-polyfill';
import { createAutoAllowWorkflow } from './auto-allow-workflow.js';
import { registerBackgroundListeners } from './background-listeners.js';
import {
  createBackgroundMessageHandler,
  type GoogleSearchGameGuardEvent,
} from './background-message-handler.js';
import { createBackgroundPathRulesController } from './background-path-rules.js';
import { createBackgroundSubdomainRulesController } from './background-subdomain-rules.js';
import { logger, getErrorMessage } from './logger.js';
import { getRequestApiEndpoints, loadRequestConfig } from './config-storage.js';
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
const MAX_GOOGLE_SEARCH_GAME_GUARD_EVENTS = 20;
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
  let googleSearchGameGuardBlockedCount = 0;
  const googleSearchGameGuardEvents: GoogleSearchGameGuardEvent[] = [];
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
    const [nativeAvailable, nativeCheck, nativeBlockedPaths, nativeBlockedSubdomains] =
      await Promise.all([
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
      ]);

    return {
      success: true,
      extensionOrigin,
      manifestVersion: browser.runtime.getManifest().version,
      nativeAvailable,
      nativeCheck,
      nativeBlockedPaths,
      nativeBlockedSubdomains,
      pathRules: blockedPathRulesController.getDebugState(),
      subdomainRules: blockedSubdomainRulesController.getDebugState(),
      googleSearchGameGuard: {
        blockedCount: googleSearchGameGuardBlockedCount,
        recentEvents: googleSearchGameGuardEvents.slice(),
      },
    };
  }

  function recordGoogleSearchGameGuardEvent(event: GoogleSearchGameGuardEvent): void {
    googleSearchGameGuardBlockedCount += 1;
    googleSearchGameGuardEvents.push(event);
    while (googleSearchGameGuardEvents.length > MAX_GOOGLE_SEARCH_GAME_GUARD_EVENTS) {
      googleSearchGameGuardEvents.shift();
    }
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
      loadRequestConfig,
      sendNativeMessage: (message) => nativeMessagingClient.sendMessage(message),
    });
  }

  const { autoAllowBlockedDomain, retryLocalUpdate } = createAutoAllowWorkflow({
    getErrorMessage,
    getRequestApiEndpoints: (config) =>
      getRequestApiEndpoints({
        ...config,
        debugMode: false,
        sharedSecret: '',
      }),
    getStoredDomainStatus: (tabId, hostname) => domainStatuses[tabId]?.get(hostname),
    inFlightAutoRequests,
    loadRequestConfig,
    refreshBlockedPathRules: async () => {
      const [pathRefresh, subdomainRefresh] = await Promise.all([
        blockedPathRulesController.refresh(true),
        blockedSubdomainRulesController.refresh(true),
      ]);
      return pathRefresh && subdomainRefresh;
    },
    requestLocalWhitelistUpdate: (hostnames) =>
      nativeMessagingClient.requestLocalWhitelistUpdate(hostnames),
    sendNativeMessage: (message) => nativeMessagingClient.sendMessage(message),
    setDomainStatus,
  });
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
    getPathRulesDebug: blockedPathRulesController.getDebugState,
    getSubdomainRulesDebug: blockedSubdomainRulesController.getDebugState,
    recordGoogleSearchGameGuardEvent,
    getSystemHostname: () => nativeMessagingClient.sendMessage({ action: 'get-hostname' }),
    isNativeHostAvailable,
    retryLocalUpdate,
    submitBlockedDomainRequest,
    triggerWhitelistUpdate: async (): Promise<NativeResponse> => {
      const response = (await nativeMessagingClient.sendMessage({
        action: 'update-whitelist',
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
      autoAllowBlockedDomain,
      browser,
      clearTabRuntimeState,
      disposeTab,
      evaluateBlockedPath: blockedPathRulesController.evaluateRequest,
      evaluateBlockedSubdomain: blockedSubdomainRulesController.evaluateRequest,
      confirmBlockedScreenNavigation,
      handleRuntimeMessage,
      recordGoogleSearchGameGuardEvent,
      redirectToBlockedScreen,
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
