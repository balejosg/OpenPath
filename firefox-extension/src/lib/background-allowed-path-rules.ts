import type { WebRequest } from 'webextension-polyfill';
import { logger, getErrorMessage } from './logger.js';
import {
  MAX_ALLOWED_PATH_RULES,
  compileAllowedPathRules,
  evaluateAllowedPath,
  getAllowedPathRulesVersion,
  type AllowedPathRulesState,
  type NativeAllowedPathsResponse,
} from './allowed-path.js';

const ALLOWED_PATH_REFRESH_INTERVAL_MS = 60000;
const ALLOWED_PATH_INITIAL_RETRY_DELAY_MS = 2000;
const ALLOWED_PATH_MAX_RETRIES = 3;

interface BackgroundAllowedPathRulesControllerOptions {
  extensionOrigin: string;
  getAllowedPaths: () => Promise<NativeAllowedPathsResponse>;
}

export interface BackgroundAllowedPathRulesController {
  evaluateRequest: (
    details: WebRequest.OnBeforeRequestDetailsType
  ) => ReturnType<typeof evaluateAllowedPath>;
  forceRefresh: () => Promise<{ success: boolean; error?: string }>;
  getDebugState: () => {
    success: true;
    version: string;
    count: number;
    managedHosts: string[];
    rawRules: string[];
    compiledPatterns: string[];
  };
  init: () => Promise<void>;
  refresh: (force?: boolean) => Promise<boolean>;
  startRefreshLoop: () => void;
}

export function createBackgroundAllowedPathRulesController(
  options: BackgroundAllowedPathRulesControllerOptions
): BackgroundAllowedPathRulesController {
  let state: AllowedPathRulesState = { version: '', rules: [], managedHosts: new Set<string>() };
  let refreshTimer: ReturnType<typeof setInterval> | null = null;

  async function refresh(force = false): Promise<boolean> {
    try {
      const response = await options.getAllowedPaths();
      if (!response.success) {
        logger.warn('[Monitor] No se pudieron obtener reglas allowed-path', {
          error: response.error,
        });
        return false;
      }

      const version = getAllowedPathRulesVersion(response);
      if (!force && state.version === version) {
        return true;
      }

      const paths = Array.isArray(response.paths) ? response.paths : [];
      const { rules, managedHosts } = compileAllowedPathRules(paths, {
        maxRules: MAX_ALLOWED_PATH_RULES,
        onTruncated: ({ provided, capped }) => {
          logger.warn('[Monitor] Reglas allowed-path truncadas', { provided, capped });
        },
      });
      state = { version, rules, managedHosts };

      logger.info('[Monitor] Allowed-path rules updated', {
        count: rules.length,
        hosts: managedHosts.size,
        source: response.source,
      });
      return true;
    } catch (error) {
      logger.warn('[Monitor] Fallo al refrescar reglas allowed-path', {
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
    }, ALLOWED_PATH_REFRESH_INTERVAL_MS);
  }

  async function init(): Promise<void> {
    for (let attempt = 0; attempt < ALLOWED_PATH_MAX_RETRIES; attempt++) {
      const ok = await refresh(true);
      if (ok) {
        return;
      }
      const delay = ALLOWED_PATH_INITIAL_RETRY_DELAY_MS * Math.pow(2, attempt);
      logger.warn('[Monitor] Reintentando carga de reglas allowed-path', {
        attempt: attempt + 1,
        nextRetryMs: delay,
      });
      await new Promise<void>((resolve) => {
        setTimeout(resolve, delay);
      });
    }
    logger.error('[Monitor] No se pudieron cargar reglas allowed-path tras reintentos', {
      maxRetries: ALLOWED_PATH_MAX_RETRIES,
    });
  }

  async function forceRefresh(): Promise<{ success: boolean; error?: string }> {
    try {
      const success = await refresh(true);
      return success
        ? { success: true }
        : { success: false, error: 'No se pudieron refrescar las reglas allowed-path' };
    } catch (error) {
      return { success: false, error: getErrorMessage(error) };
    }
  }

  function evaluateRequest(
    details: WebRequest.OnBeforeRequestDetailsType
  ): ReturnType<typeof evaluateAllowedPath> {
    return evaluateAllowedPath(details, state, { extensionOrigin: options.extensionOrigin });
  }

  function getDebugState(): {
    success: true;
    version: string;
    count: number;
    managedHosts: string[];
    rawRules: string[];
    compiledPatterns: string[];
  } {
    return {
      success: true as const,
      version: state.version,
      count: state.rules.length,
      managedHosts: Array.from(state.managedHosts),
      rawRules: state.rules.map((rule) => rule.rawRule),
      compiledPatterns: state.rules.flatMap((rule) => rule.compiledPatterns),
    };
  }

  return { evaluateRequest, forceRefresh, getDebugState, init, refresh, startRefreshLoop };
}
