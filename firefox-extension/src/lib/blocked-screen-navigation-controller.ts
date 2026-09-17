import type { WebRequest } from 'webextension-polyfill';
import { getErrorMessage, logger } from './logger.js';
import { BLOCKED_SCREEN_PATH, extractHostname, isExtensionUrl } from './path-blocking.js';
import {
  createNavigationState,
  type NavigationIdentity,
  type NavigationState,
} from './navigation-state.js';

const BLOCKING_ERRORS = [
  'NS_ERROR_UNKNOWN_HOST',
  'NS_ERROR_CONNECTION_REFUSED',
  'NS_ERROR_NET_TIMEOUT',
  'NS_ERROR_PROXY_CONNECTION_REFUSED',
];
const IGNORED_ERRORS = ['NS_BINDING_ABORTED', 'NS_ERROR_ABORT'];
// Every blocking error must be confirmed by the native host before the blocked screen is shown.
// A transport/proxy failure on its own (agent down, restarting, boot window) is not a policy
// block, so we never display the blocked screen without native confirmation that the domain is
// actually blocked by policy.
const NATIVE_CONFIRMED_BLOCKED_SCREEN_ERRORS = new Set([
  'NS_ERROR_UNKNOWN_HOST',
  'NS_ERROR_CONNECTION_REFUSED',
  'NS_ERROR_NET_TIMEOUT',
  'NS_ERROR_PROXY_CONNECTION_REFUSED',
]);
const NATIVE_POLICY_BLOCKED_ERROR = 'OPENPATH_NATIVE_POLICY_BLOCKED';
const CAPTIVE_PORTAL_RECOVERY_ERRORS = new Set([
  'NS_ERROR_UNKNOWN_HOST',
  'NS_ERROR_CONNECTION_REFUSED',
  'NS_ERROR_NET_TIMEOUT',
  NATIVE_POLICY_BLOCKED_ERROR,
]);

interface CaptivePortalRecoveryOptions {
  isCurrentNavigation?: () => boolean;
}

export interface NativeBlockedScreenConfirmation {
  blocked: boolean;
  portalRecoveryEligible?: boolean;
}

type NativeBlockedScreenConfirmationResult = boolean | NativeBlockedScreenConfirmation;

type CaptivePortalRecoveryHandler = (
  context: ConfirmBlockedScreenContext,
  options?: CaptivePortalRecoveryOptions
) => Promise<boolean>;

export interface BlockedScreenContext {
  tabId: number;
  hostname: string;
  error: string;
  origin: string | null;
}

export interface ConfirmBlockedScreenContext extends BlockedScreenContext {
  url: string;
}

export interface BlockedScreenNavigationControllerDeps {
  addBlockedDomain: (
    tabId: number,
    hostname: string,
    error: string,
    origin?: string | null
  ) => void;
  confirmBlockedScreenNavigation?: (
    context: ConfirmBlockedScreenContext
  ) => Promise<NativeBlockedScreenConfirmationResult>;
  getBlockedScreenUrl?: () => string;
  getCurrentTabUrl: (tabId: number) => Promise<string | null | undefined>;
  navigationState?: NavigationState;
  now?: () => number;
  recoverCaptivePortalNavigation?: CaptivePortalRecoveryHandler;
  redirectToBlockedScreen: (context: BlockedScreenContext) => Promise<void>;
  saveBlockedPageContext?: (tabId: number, domain: string, originalUrl: string | undefined) => void;
}

function normalizeNativeBlockedScreenConfirmation(
  confirmation: NativeBlockedScreenConfirmationResult | undefined
): NativeBlockedScreenConfirmation {
  if (typeof confirmation === 'boolean') {
    return { blocked: confirmation };
  }

  return confirmation ?? { blocked: false };
}

export interface BlockedScreenNavigationController {
  disposeTab: (tabId: number) => void;
  handleBlockedScreenNavigationError: (
    details: {
      documentUrl?: string;
      error: string;
      frameId?: number;
      originUrl?: string;
      tabId: number;
      type?: string;
      url: string;
    },
    optionsForError: { recordBlockedDomain: boolean; requestType?: WebRequest.ResourceType }
  ) => Promise<void>;
  handleNativePolicyNavigationPreflight: (details: {
    frameId: number;
    tabId: number;
    url: string;
  }) => Promise<void>;
}

function isTopFrameNavigation(details: { frameId?: number; type?: string }): boolean {
  if (details.type !== undefined) {
    return details.type === 'main_frame';
  }

  return details.frameId === 0;
}

function shouldConfirmBlockedScreenNavigation(details: {
  error: string;
  frameId?: number;
  type?: string;
  url: string;
}): boolean {
  return (
    isTopFrameNavigation(details) &&
    NATIVE_CONFIRMED_BLOCKED_SCREEN_ERRORS.has(details.error) &&
    !isExtensionUrl(details.url)
  );
}

function buildBlockedScreenContext(details: {
  error: string;
  originUrl?: string;
  documentUrl?: string;
  tabId: number;
  url: string;
}): ConfirmBlockedScreenContext | null {
  const hostname = extractHostname(details.url);
  if (!hostname || details.tabId < 0) {
    return null;
  }

  return {
    tabId: details.tabId,
    hostname,
    error: details.error,
    origin: extractHostname(details.originUrl ?? details.documentUrl ?? ''),
    url: details.url,
  };
}

async function recoverCaptivePortalNavigationIfEligible(
  context: ConfirmBlockedScreenContext,
  recoverCaptivePortalNavigation: CaptivePortalRecoveryHandler | undefined,
  options?: CaptivePortalRecoveryOptions
): Promise<boolean> {
  return (
    CAPTIVE_PORTAL_RECOVERY_ERRORS.has(context.error) &&
    (await recoverCaptivePortalNavigation?.(context, options)) === true
  );
}

function isSameBlockedScreenUrl(
  currentUrl: string,
  blockedScreenUrl: string,
  hostname: string
): boolean {
  try {
    const current = new URL(currentUrl);
    const blockedScreen = new URL(blockedScreenUrl);
    return (
      current.origin === blockedScreen.origin &&
      current.pathname === blockedScreen.pathname &&
      current.searchParams.get('domain') === hostname
    );
  } catch {
    return false;
  }
}

export function createBlockedScreenNavigationController(
  deps: BlockedScreenNavigationControllerDeps
): BlockedScreenNavigationController {
  const getBlockedScreenUrl =
    deps.getBlockedScreenUrl ?? ((): string => `moz-extension://openpath/${BLOCKED_SCREEN_PATH}`);
  const navigationState = deps.navigationState ?? createNavigationState();
  const recoverCaptivePortalNavigation = deps.recoverCaptivePortalNavigation;

  async function tabAlreadyShowsBlockedScreen(
    context: ConfirmBlockedScreenContext
  ): Promise<boolean> {
    try {
      const tabUrl = await deps.getCurrentTabUrl(context.tabId);
      return typeof tabUrl === 'string'
        ? isSameBlockedScreenUrl(tabUrl, getBlockedScreenUrl(), context.hostname)
        : false;
    } catch {
      return false;
    }
  }

  async function redirectToBlockedScreenOnce(
    context: ConfirmBlockedScreenContext,
    optionsForRedirect: {
      identity: NavigationIdentity;
      recordBlockedDomain?: boolean;
      requireNativeConfirmation: boolean;
    }
  ): Promise<void> {
    if (!navigationState.reserveRedirect(optionsForRedirect.identity)) return;
    try {
      if (await tabAlreadyShowsBlockedScreen(context)) {
        return;
      }

      if (optionsForRedirect.requireNativeConfirmation) {
        const confirmation = normalizeNativeBlockedScreenConfirmation(
          await deps.confirmBlockedScreenNavigation?.(context)
        );
        if (!confirmation.blocked) {
          if (!navigationState.isCurrent(optionsForRedirect.identity)) {
            return;
          }
          await recoverCaptivePortalNavigationIfEligible(context, recoverCaptivePortalNavigation, {
            isCurrentNavigation: () => navigationState.isCurrent(optionsForRedirect.identity),
          });
          return;
        }

        if (
          confirmation.portalRecoveryEligible === true &&
          navigationState.isCurrent(optionsForRedirect.identity) &&
          (await recoverCaptivePortalNavigationIfEligible(context, recoverCaptivePortalNavigation, {
            isCurrentNavigation: () => navigationState.isCurrent(optionsForRedirect.identity),
          }))
        ) {
          return;
        }
      } else if (
        navigationState.isCurrent(optionsForRedirect.identity) &&
        (await recoverCaptivePortalNavigationIfEligible(context, recoverCaptivePortalNavigation, {
          isCurrentNavigation: () => navigationState.isCurrent(optionsForRedirect.identity),
        }))
      ) {
        return;
      }

      if (!navigationState.isCurrent(optionsForRedirect.identity)) {
        return;
      }

      if (optionsForRedirect.recordBlockedDomain) {
        logger.info(`[Monitor] Blocked by native policy: ${context.hostname}`, {
          error: context.error,
        });
        deps.addBlockedDomain(context.tabId, context.hostname, context.error, context.origin);
      }

      deps.saveBlockedPageContext?.(context.tabId, context.hostname, context.url);
      await deps.redirectToBlockedScreen({
        tabId: context.tabId,
        hostname: context.hostname,
        error: context.error,
        origin: context.origin,
      });
      navigationState.markShown(optionsForRedirect.identity);
    } catch (error) {
      logger.warn('[Monitor] No se pudo confirmar pantalla de bloqueo', {
        tabId: context.tabId,
        hostname: context.hostname,
        error: getErrorMessage(error),
      });
      throw error;
    } finally {
      navigationState.releaseRedirect(optionsForRedirect.identity);
    }
  }

  async function handleNativePolicyNavigationPreflight(details: {
    frameId: number;
    tabId: number;
    url: string;
  }): Promise<void> {
    if (details.frameId !== 0) {
      return;
    }
    if (isExtensionUrl(details.url)) {
      navigationState.dispose(details.tabId);
      return;
    }

    const context = buildBlockedScreenContext({
      error: NATIVE_POLICY_BLOCKED_ERROR,
      tabId: details.tabId,
      url: details.url,
    });
    if (!context) {
      return;
    }

    const identity = navigationState.begin(context.tabId, context.url, 'preflight');
    await redirectToBlockedScreenOnce(context, {
      identity,
      recordBlockedDomain: true,
      requireNativeConfirmation: true,
    });
  }

  async function handleBlockedScreenNavigationError(
    details: {
      documentUrl?: string;
      error: string;
      frameId?: number;
      originUrl?: string;
      tabId: number;
      type?: string;
      url: string;
    },
    optionsForError: { recordBlockedDomain: boolean; requestType?: WebRequest.ResourceType }
  ): Promise<void> {
    if (IGNORED_ERRORS.includes(details.error)) {
      return;
    }

    if (!BLOCKING_ERRORS.includes(details.error)) {
      return;
    }

    const context = buildBlockedScreenContext(details);
    if (!context) {
      return;
    }

    if (optionsForError.recordBlockedDomain && !isTopFrameNavigation(details)) {
      logger.info(`[Monitor] Blocked: ${context.hostname}`, {
        error: details.error,
        requestType: optionsForError.requestType,
      });
      deps.addBlockedDomain(
        details.tabId,
        context.hostname,
        details.error,
        details.originUrl ?? details.documentUrl
      );
    }

    if (shouldConfirmBlockedScreenNavigation(details)) {
      const existing = navigationState.get(context.tabId);
      if (existing?.source === 'preflight' && existing.url !== context.url) return;
      const identity =
        existing?.url === context.url
          ? existing
          : navigationState.begin(context.tabId, context.url, 'error');
      await redirectToBlockedScreenOnce(context, {
        identity,
        recordBlockedDomain: optionsForError.recordBlockedDomain,
        requireNativeConfirmation: true,
      });
    }
  }

  return {
    disposeTab: (tabId): void => {
      navigationState.dispose(tabId);
    },
    handleBlockedScreenNavigationError,
    handleNativePolicyNavigationPreflight,
  };
}
