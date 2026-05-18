import type { WebRequest } from 'webextension-polyfill';
import { logger, getErrorMessage } from './logger.js';
import {
  MAX_BLOCKED_SUBDOMAIN_RULES,
  compileBlockedSubdomainRules,
  evaluateSubdomainBlocking,
  getBlockedSubdomainRulesVersion,
  type BlockedSubdomainRulesState,
  type NativeBlockedSubdomainsResponse,
} from './subdomain-blocking.js';

const BLOCKED_SUBDOMAIN_REFRESH_INTERVAL_MS = 60000;
const BLOCKED_SUBDOMAIN_INITIAL_RETRY_DELAY_MS = 2000;
const BLOCKED_SUBDOMAIN_MAX_RETRIES = 3;

interface BackgroundSubdomainRulesControllerOptions {
  extensionOrigin: string;
  getBlockedSubdomains: () => Promise<NativeBlockedSubdomainsResponse>;
}

interface BackgroundSubdomainRulesController {
  evaluateRequest: (
    details: WebRequest.OnBeforeRequestDetailsType
  ) => ReturnType<typeof evaluateSubdomainBlocking>;
  forceRefresh: () => Promise<{ success: boolean; error?: string }>;
  getDebugState: () => {
    success: true;
    version: string;
    count: number;
    rawRules: string[];
  };
  init: () => Promise<void>;
  refresh: (force?: boolean) => Promise<boolean>;
  startRefreshLoop: () => void;
}

export function createBackgroundSubdomainRulesController(
  options: BackgroundSubdomainRulesControllerOptions
): BackgroundSubdomainRulesController {
  let state: BlockedSubdomainRulesState = {
    version: '',
    rules: [],
  };
  let refreshTimer: ReturnType<typeof setInterval> | null = null;

  async function refresh(force = false): Promise<boolean> {
    try {
      const response = await options.getBlockedSubdomains();
      if (!response.success) {
        logger.warn('[Monitor] No se pudieron obtener reglas de subdominios', {
          error: response.error,
        });
        return false;
      }

      const version = getBlockedSubdomainRulesVersion(response);
      if (!force && state.version === version) {
        return true;
      }

      const subdomains = Array.isArray(response.subdomains) ? response.subdomains : [];
      state = {
        version,
        rules: compileBlockedSubdomainRules(subdomains, {
          maxRules: MAX_BLOCKED_SUBDOMAIN_RULES,
          onTruncated: ({ provided, capped }) => {
            logger.warn('[Monitor] Reglas de subdominio truncadas', { provided, capped });
          },
        }),
      };

      logger.info('[Monitor] Subdomain rules updated', {
        count: state.rules.length,
        source: response.source,
      });
      return true;
    } catch (error) {
      logger.warn('[Monitor] Fallo al refrescar reglas de subdominios', {
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
    }, BLOCKED_SUBDOMAIN_REFRESH_INTERVAL_MS);
  }

  async function init(): Promise<void> {
    for (let attempt = 0; attempt < BLOCKED_SUBDOMAIN_MAX_RETRIES; attempt++) {
      const ok = await refresh(true);
      if (ok) {
        return;
      }
      const delay = BLOCKED_SUBDOMAIN_INITIAL_RETRY_DELAY_MS * Math.pow(2, attempt);
      logger.warn('[Monitor] Reintentando carga de reglas de subdominio', {
        attempt: attempt + 1,
        nextRetryMs: delay,
      });
      await new Promise<void>((resolve) => {
        setTimeout(resolve, delay);
      });
    }
    logger.error('[Monitor] No se pudieron cargar reglas de subdominio tras reintentos', {
      maxRetries: BLOCKED_SUBDOMAIN_MAX_RETRIES,
    });
  }

  async function forceRefresh(): Promise<{ success: boolean; error?: string }> {
    try {
      const success = await refresh(true);
      return success
        ? { success: true }
        : { success: false, error: 'No se pudieron refrescar las reglas de subdominio' };
    } catch (error) {
      return { success: false, error: getErrorMessage(error) };
    }
  }

  function evaluateRequest(
    details: WebRequest.OnBeforeRequestDetailsType
  ): ReturnType<typeof evaluateSubdomainBlocking> {
    return evaluateSubdomainBlocking(details, state.rules, {
      extensionOrigin: options.extensionOrigin,
    });
  }

  function getDebugState(): { success: true; version: string; count: number; rawRules: string[] } {
    return {
      success: true,
      version: state.version,
      count: state.rules.length,
      rawRules: state.rules.map((rule) => rule.rawRule),
    };
  }

  return {
    evaluateRequest,
    forceRefresh,
    getDebugState,
    init,
    refresh,
    startRefreshLoop,
  };
}
