import type { WebRequest } from 'webextension-polyfill';
import { getErrorMessage, logger } from './logger.js';
import { BLOCKED_SCREEN_PATH, extractHostname, isExtensionUrl } from './path-blocking.js';

const BLOCKING_ERRORS = [
  'NS_ERROR_UNKNOWN_HOST',
  'NS_ERROR_CONNECTION_REFUSED',
  'NS_ERROR_NET_TIMEOUT',
  'NS_ERROR_PROXY_CONNECTION_REFUSED',
];
const IGNORED_ERRORS = ['NS_BINDING_ABORTED', 'NS_ERROR_ABORT'];
const IMMEDIATE_BLOCKED_SCREEN_ERRORS = new Set([
  'NS_ERROR_UNKNOWN_HOST',
  'NS_ERROR_PROXY_CONNECTION_REFUSED',
]);
const NATIVE_CONFIRMED_BLOCKED_SCREEN_ERRORS = new Set([
  'NS_ERROR_CONNECTION_REFUSED',
  'NS_ERROR_NET_TIMEOUT',
]);
const NATIVE_POLICY_BLOCKED_ERROR = 'OPENPATH_NATIVE_POLICY_BLOCKED';
const DUPLICATE_BLOCKED_SCREEN_REDIRECT_WINDOW_MS = 60_000;

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
  confirmBlockedScreenNavigation?: (context: ConfirmBlockedScreenContext) => Promise<boolean>;
  getBlockedScreenUrl?: () => string;
  getCurrentTabUrl: (tabId: number) => Promise<string | null | undefined>;
  now?: () => number;
  redirectToBlockedScreen: (context: BlockedScreenContext) => Promise<void>;
  saveBlockedPageContext?: (tabId: number, domain: string, originalUrl: string | undefined) => void;
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
  ) => void;
  handleNativePolicyNavigationPreflight: (details: {
    frameId: number;
    tabId: number;
    url: string;
  }) => void;
}

function isTopFrameNavigation(details: { frameId?: number; type?: string }): boolean {
  if (details.type !== undefined) {
    return details.type === 'main_frame';
  }

  return details.frameId === 0;
}

function shouldDisplayBlockedScreenImmediately(details: {
  error: string;
  frameId?: number;
  type?: string;
  url: string;
}): boolean {
  return (
    isTopFrameNavigation(details) &&
    IMMEDIATE_BLOCKED_SCREEN_ERRORS.has(details.error) &&
    !isExtensionUrl(details.url)
  );
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

function buildRedirectKey(context: ConfirmBlockedScreenContext): string {
  return [context.tabId.toString(), context.hostname, context.error, context.url].join(':');
}

function buildDisplayedRedirectKey(context: ConfirmBlockedScreenContext): string {
  return [context.tabId.toString(), context.hostname, context.url].join(':');
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
  const now = deps.now ?? ((): number => Date.now());
  const getBlockedScreenUrl =
    deps.getBlockedScreenUrl ?? ((): string => `moz-extension://openpath/${BLOCKED_SCREEN_PATH}`);
  const pendingBlockedScreenRedirects = new Set<string>();
  const displayedBlockedScreenRedirects = new Map<number, { key: string; redirectedAt: number }>();
  const latestNativePolicyPreflightByTab = new Map<number, string>();

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
      isCurrentNavigation?: () => boolean;
      recordBlockedDomain?: boolean;
      requireNativeConfirmation: boolean;
    }
  ): Promise<void> {
    const redirectKey = buildRedirectKey(context);
    const displayedRedirectKey = buildDisplayedRedirectKey(context);
    const displayedRedirect = displayedBlockedScreenRedirects.get(context.tabId);
    if (
      displayedRedirect?.key === displayedRedirectKey &&
      now() - displayedRedirect.redirectedAt < DUPLICATE_BLOCKED_SCREEN_REDIRECT_WINDOW_MS
    ) {
      return;
    }

    if (pendingBlockedScreenRedirects.has(redirectKey)) {
      return;
    }

    pendingBlockedScreenRedirects.add(redirectKey);
    try {
      if (await tabAlreadyShowsBlockedScreen(context)) {
        return;
      }

      if (optionsForRedirect.requireNativeConfirmation) {
        const confirmed = await deps.confirmBlockedScreenNavigation?.(context);
        if (confirmed !== true) {
          return;
        }
      }

      if (optionsForRedirect.isCurrentNavigation?.() === false) {
        return;
      }

      if (optionsForRedirect.recordBlockedDomain) {
        logger.info(`[Monitor] Bloqueado por política nativa: ${context.hostname}`, {
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
      displayedBlockedScreenRedirects.set(context.tabId, {
        key: displayedRedirectKey,
        redirectedAt: now(),
      });
    } catch (error) {
      logger.warn('[Monitor] No se pudo confirmar pantalla de bloqueo', {
        tabId: context.tabId,
        hostname: context.hostname,
        error: getErrorMessage(error),
      });
    } finally {
      pendingBlockedScreenRedirects.delete(redirectKey);
    }
  }

  function handleNativePolicyNavigationPreflight(details: {
    frameId: number;
    tabId: number;
    url: string;
  }): void {
    if (details.frameId !== 0 || isExtensionUrl(details.url)) {
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

    latestNativePolicyPreflightByTab.set(context.tabId, context.url);
    void redirectToBlockedScreenOnce(context, {
      isCurrentNavigation: () =>
        latestNativePolicyPreflightByTab.get(context.tabId) === context.url,
      recordBlockedDomain: true,
      requireNativeConfirmation: true,
    });
  }

  function handleBlockedScreenNavigationError(
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
  ): void {
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

    if (optionsForError.recordBlockedDomain) {
      logger.info(`[Monitor] Bloqueado: ${context.hostname}`, {
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

    if (shouldDisplayBlockedScreenImmediately(details)) {
      void redirectToBlockedScreenOnce(context, { requireNativeConfirmation: false });
    } else if (shouldConfirmBlockedScreenNavigation(details)) {
      void redirectToBlockedScreenOnce(context, { requireNativeConfirmation: true });
    }
  }

  return {
    disposeTab: (tabId): void => {
      latestNativePolicyPreflightByTab.delete(tabId);
      displayedBlockedScreenRedirects.delete(tabId);
    },
    handleBlockedScreenNavigationError,
    handleNativePolicyNavigationPreflight,
  };
}
