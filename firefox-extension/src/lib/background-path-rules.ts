import type { WebRequest } from 'webextension-polyfill';
import { logger, getErrorMessage } from './logger.js';
import {
  MAX_BLOCKED_PATH_RULES,
  compileBlockedPathRules,
  evaluatePathBlocking,
  getBlockedPathRulesVersion,
  type BlockedPathRulesState,
  type NativeBlockedPathsResponse,
} from './path-blocking.js';

const BLOCKED_PATH_REFRESH_INTERVAL_MS = 60000;
const BLOCKED_PATH_INITIAL_RETRY_DELAY_MS = 2000;
const BLOCKED_PATH_MAX_RETRIES = 3;

interface BackgroundPathRulesControllerOptions {
  extensionOrigin: string;
  getBlockedPaths: () => Promise<NativeBlockedPathsResponse>;
}

interface BackgroundPathRulesController {
  evaluateRequest: (
    details: WebRequest.OnBeforeRequestDetailsType
  ) => ReturnType<typeof evaluatePathBlocking>;
  forceRefresh: () => Promise<{ success: boolean; error?: string }>;
  getDebugState: () => {
    success: true;
    version: string;
    count: number;
    rawRules: string[];
    compiledPatterns: string[];
  };
  init: () => Promise<void>;
  refresh: (force?: boolean) => Promise<boolean>;
  startRefreshLoop: () => void;
}

export function createBackgroundPathRulesController(
  options: BackgroundPathRulesControllerOptions
): BackgroundPathRulesController {
  let blockedPathRulesState: BlockedPathRulesState = {
    version: '',
    rules: [],
  };
  let blockedPathRefreshTimer: ReturnType<typeof setInterval> | null = null;

  async function refresh(force = false): Promise<boolean> {
    try {
      const response = await options.getBlockedPaths();
      if (!response.success) {
        logger.warn('[Monitor] No se pudieron obtener reglas de rutas', {
          error: response.error,
        });
        return false;
      }

      const version = getBlockedPathRulesVersion(response);
      if (!force && blockedPathRulesState.version === version) {
        return true;
      }

      const paths = Array.isArray(response.paths) ? response.paths : [];
      blockedPathRulesState = {
        version,
        rules: compileBlockedPathRules(paths, {
          maxRules: MAX_BLOCKED_PATH_RULES,
          onTruncated: ({ provided, capped }) => {
            logger.warn('[Monitor] Reglas de ruta truncadas', { provided, capped });
          },
        }),
      };

      logger.info('[Monitor] Path rules updated', {
        count: blockedPathRulesState.rules.length,
        source: response.source,
      });
      return true;
    } catch (error) {
      logger.warn('[Monitor] Fallo al refrescar reglas de rutas', {
        error: getErrorMessage(error),
      });
      return false;
    }
  }

  function startRefreshLoop(): void {
    if (blockedPathRefreshTimer) {
      clearInterval(blockedPathRefreshTimer);
    }

    blockedPathRefreshTimer = setInterval(() => {
      void refresh(false);
    }, BLOCKED_PATH_REFRESH_INTERVAL_MS);
  }

  async function init(): Promise<void> {
    for (let attempt = 0; attempt < BLOCKED_PATH_MAX_RETRIES; attempt++) {
      const ok = await refresh(true);
      if (ok) {
        return;
      }

      const delay = BLOCKED_PATH_INITIAL_RETRY_DELAY_MS * Math.pow(2, attempt);
      logger.warn('[Monitor] Reintentando carga de reglas de ruta', {
        attempt: attempt + 1,
        nextRetryMs: delay,
      });
      await new Promise<void>((resolve) => {
        setTimeout(resolve, delay);
      });
    }

    logger.error('[Monitor] No se pudieron cargar reglas de ruta tras reintentos', {
      maxRetries: BLOCKED_PATH_MAX_RETRIES,
    });
  }

  async function forceRefresh(): Promise<{ success: boolean; error?: string }> {
    try {
      const success = await refresh(true);
      return success
        ? { success: true }
        : { success: false, error: 'No se pudieron refrescar las reglas de ruta' };
    } catch (error) {
      return {
        success: false,
        error: getErrorMessage(error),
      };
    }
  }

  function evaluateRequest(
    details: WebRequest.OnBeforeRequestDetailsType
  ): ReturnType<typeof evaluatePathBlocking> {
    return evaluatePathBlocking(details, blockedPathRulesState.rules, {
      extensionOrigin: options.extensionOrigin,
    });
  }

  function getDebugState(): {
    success: true;
    version: string;
    count: number;
    rawRules: string[];
    compiledPatterns: string[];
  } {
    return {
      success: true as const,
      version: blockedPathRulesState.version,
      count: blockedPathRulesState.rules.length,
      rawRules: blockedPathRulesState.rules.map((rule) => rule.rawRule),
      compiledPatterns: blockedPathRulesState.rules.flatMap((rule) => rule.compiledPatterns),
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
