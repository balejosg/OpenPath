import type { Tabs } from 'webextension-polyfill';

import { logger, getErrorMessage } from './logger.js';
import type { VerifyResponse } from './native-messaging-client.js';

export const TAB_RECONCILE_INTERVAL_MS = 5000;
const TAB_RECONCILE_INITIAL_RETRY_DELAY_MS = 2000;
const TAB_RECONCILE_MAX_RETRIES = 3;

export const WHITELIST_POLICY_REMOVED_REASON = 'POLICY_BLOCKED';

export interface NativePolicyVersionResponse {
  success: boolean;
  version?: string;
  error?: string;
}

export interface BlockedTabRedirect {
  tabId: number;
  hostname: string;
  error: string;
}

interface BackgroundTabReconciliationControllerOptions {
  getPolicyVersion: () => Promise<NativePolicyVersionResponse>;
  checkDomains: (domains: string[]) => Promise<VerifyResponse>;
  queryTabs: () => Promise<Tabs.Tab[]>;
  redirectToBlockedScreen: (redirect: BlockedTabRedirect) => Promise<void>;
}

interface BackgroundTabReconciliationController {
  init: () => Promise<void>;
  refresh: (force?: boolean) => Promise<boolean>;
  startRefreshLoop: () => void;
}

function extractHttpHost(rawUrl: string | undefined): string | null {
  if (!rawUrl) {
    return null;
  }
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return null;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return null;
  }
  return parsed.hostname.toLowerCase() || null;
}

export function createBackgroundTabReconciliationController(
  options: BackgroundTabReconciliationControllerOptions
): BackgroundTabReconciliationController {
  let state = { version: '' };
  let refreshTimer: ReturnType<typeof setInterval> | null = null;

  async function reconcileOpenTabs(): Promise<boolean> {
    const tabs = await options.queryTabs();
    const tabHosts: { tab: Tabs.Tab; host: string }[] = [];
    for (const candidate of tabs) {
      const host = extractHttpHost(candidate.url);
      if (host !== null) {
        tabHosts.push({ tab: candidate, host });
      }
    }
    if (tabHosts.length === 0) {
      return true;
    }

    const uniqueHosts = [...new Set(tabHosts.map((entry) => entry.host))];
    const checkResponse = await options.checkDomains(uniqueHosts);
    if (!checkResponse.success) {
      logger.warn('[Monitor] check de hosts falló durante la reconciliación', {
        error: checkResponse.error,
      });
      return false;
    }

    const allowedByHost = new Map<string, boolean>();
    for (const result of checkResponse.results) {
      allowedByHost.set(result.domain.toLowerCase(), result.inWhitelist);
    }

    for (const { tab, host } of tabHosts) {
      if (allowedByHost.get(host) === false && typeof tab.id === 'number') {
        try {
          await options.redirectToBlockedScreen({
            tabId: tab.id,
            hostname: host,
            error: WHITELIST_POLICY_REMOVED_REASON,
          });
        } catch (error) {
          logger.warn('[Monitor] No se pudo redirigir la pestaña bloqueada', {
            tabId: tab.id,
            host,
            error: getErrorMessage(error),
          });
        }
      }
    }
    return true;
  }

  async function refresh(force = false): Promise<boolean> {
    try {
      const versionResponse = await options.getPolicyVersion();
      if (!versionResponse.success) {
        logger.warn('[Monitor] No se pudo obtener la versión de política', {
          error: versionResponse.error,
        });
        return false;
      }

      const version = versionResponse.version ?? '';
      if (!force && version === state.version) {
        return true;
      }

      const reconciled = await reconcileOpenTabs();
      if (!reconciled) {
        return false;
      }

      state = { version };
      return true;
    } catch (error) {
      logger.warn('[Monitor] Fallo al reconciliar pestañas abiertas', {
        error: getErrorMessage(error),
      });
      return false;
    }
  }

  function startRefreshLoop(): void {
    if (refreshTimer) {
      clearInterval(refreshTimer);
    }
    refreshTimer = setInterval(() => {
      void refresh(false);
    }, TAB_RECONCILE_INTERVAL_MS);
  }

  async function init(): Promise<void> {
    for (let attempt = 0; attempt < TAB_RECONCILE_MAX_RETRIES; attempt++) {
      const ok = await refresh(true);
      if (ok) {
        return;
      }
      const delay = TAB_RECONCILE_INITIAL_RETRY_DELAY_MS * Math.pow(2, attempt);
      logger.warn('[Monitor] Reintentando reconciliación de pestañas', {
        attempt: attempt + 1,
        nextRetryMs: delay,
      });
      await new Promise<void>((resolve) => {
        setTimeout(resolve, delay);
      });
    }
    logger.error('[Monitor] No se pudo reconciliar pestañas tras reintentos', {
      maxRetries: TAB_RECONCILE_MAX_RETRIES,
    });
  }

  return { init, refresh, startRefreshLoop };
}
