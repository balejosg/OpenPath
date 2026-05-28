import { getErrorMessage, logger as defaultLogger } from './logger.js';
import type {
  CaptivePortalRecoveryInput,
  CaptivePortalRecoveryResponse,
} from './native-messaging-client.js';

const CAPTIVE_PORTAL_RECOVERY_RATE_LIMIT_MS = 30_000;
const CAPTIVE_PORTAL_NATIVE_RECOVERY_RETRY_DELAY_MS = 750;

interface CaptivePortalRecoveryLogger {
  info: (message: string, context?: Record<string, unknown>) => void;
}

export interface CaptivePortalRecoveryNavigationContext {
  tabId: number;
  hostname: string;
  portalRecoveryHosts?: string[];
  url: string;
}

export interface CaptivePortalRecoveryController {
  clearLimiter: () => void;
  disposeTab: (tabId: number) => void;
  handleConnectivityAvailable: () => Promise<void>;
  handlePortalStateChanged: (state: string) => Promise<void>;
  recoverNavigation: (
    context: CaptivePortalRecoveryNavigationContext,
    options?: { isCurrentNavigation?: () => boolean }
  ) => Promise<boolean>;
}

export interface CaptivePortalRecoveryControllerDeps {
  getPortalState: () => Promise<string | null | undefined>;
  isNativePortalRecoveryEligible?: (
    context: CaptivePortalRecoveryNavigationContext
  ) => Promise<boolean>;
  logger?: CaptivePortalRecoveryLogger;
  now?: () => number;
  recoverCaptivePortalNavigation: (
    input: CaptivePortalRecoveryInput
  ) => Promise<CaptivePortalRecoveryResponse>;
  retryNavigation: (tabId: number, url: string) => Promise<void>;
  sleep?: (milliseconds: number) => Promise<void>;
}

function buildRecoveryKey(tabId: number, hostname: string): string {
  return `${tabId.toString()}:${hostname.trim().toLowerCase()}`;
}

function buildRecoveryHostSignature(context: CaptivePortalRecoveryNavigationContext): Set<string> {
  const hosts = new Set<string>();
  for (const candidate of [context.hostname, ...(context.portalRecoveryHosts ?? [])]) {
    const normalized = candidate.trim().toLowerCase();
    if (normalized) {
      hosts.add(normalized);
    }
  }
  return hosts;
}

function hasEnrichedRecoveryHosts(currentHosts: Set<string>, previousHosts: Set<string>): boolean {
  for (const host of currentHosts) {
    if (!previousHosts.has(host)) {
      return true;
    }
  }
  return false;
}

export function createCaptivePortalRecoveryController(
  deps: CaptivePortalRecoveryControllerDeps
): CaptivePortalRecoveryController {
  const logger = deps.logger ?? defaultLogger;
  const now = deps.now ?? ((): number => Date.now());
  const sleep =
    deps.sleep ??
    ((milliseconds: number): Promise<void> =>
      new Promise((resolve) => {
        setTimeout(resolve, milliseconds);
      }));
  const recoveryAttemptByTabAndHost = new Map<
    string,
    { attemptedAt: number; hosts: Set<string> }
  >();

  function clearLimiter(): void {
    recoveryAttemptByTabAndHost.clear();
  }

  async function reconcileCaptivePortalRecovery(input: {
    reason: string;
    state?: string;
  }): Promise<void> {
    await deps
      .recoverCaptivePortalNavigation({
        operation: 'reconcile',
        portalState: input.state ?? 'Unknown',
        source: `firefox-captivePortal:${input.reason}`,
      })
      .catch((error: unknown) => {
        logger.info('[Monitor] Captive portal recovery reconcile unavailable', {
          reason: input.reason,
          error: getErrorMessage(error),
        });
      });
  }

  async function recoverNavigation(
    context: CaptivePortalRecoveryNavigationContext,
    options?: { isCurrentNavigation?: () => boolean }
  ): Promise<boolean> {
    const key = buildRecoveryKey(context.tabId, context.hostname);
    const currentTime = now();
    const recoveryHosts = buildRecoveryHostSignature(context);
    const lastAttempt = recoveryAttemptByTabAndHost.get(key);
    if (
      lastAttempt !== undefined &&
      currentTime - lastAttempt.attemptedAt < CAPTIVE_PORTAL_RECOVERY_RATE_LIMIT_MS &&
      !hasEnrichedRecoveryHosts(recoveryHosts, lastAttempt.hosts)
    ) {
      return false;
    }

    const portalState = await deps.getPortalState().catch((error: unknown) => {
      logger.info('[Monitor] Captive portal state unavailable', {
        tabId: context.tabId,
        hostname: context.hostname,
        error: getErrorMessage(error),
      });
      return null;
    });
    if (portalState !== 'locked_portal') {
      const stateAllowsNativeSignal =
        portalState === null || portalState === undefined || portalState === 'unknown';
      const nativeEligible =
        stateAllowsNativeSignal &&
        (await deps.isNativePortalRecoveryEligible?.(context).catch((error: unknown) => {
          logger.info('[Monitor] Native captive portal recovery signal unavailable', {
            tabId: context.tabId,
            hostname: context.hostname,
            error: getErrorMessage(error),
          });
          return false;
        })) === true;
      if (!nativeEligible) {
        return false;
      }
    }

    recoveryAttemptByTabAndHost.set(key, { attemptedAt: currentTime, hosts: recoveryHosts });
    const response = await deps
      .recoverCaptivePortalNavigation({
        ...(context.portalRecoveryHosts && context.portalRecoveryHosts.length > 0
          ? { portalRecoveryHosts: context.portalRecoveryHosts }
          : {}),
        portalState: portalState ?? 'Unknown',
        triggerHost: context.hostname,
        tabId: context.tabId,
      })
      .catch((error: unknown) => {
        logger.info('[Monitor] Captive portal recovery unavailable', {
          tabId: context.tabId,
          hostname: context.hostname,
          error: getErrorMessage(error),
        });
        return { success: false };
      });

    if (!response.success) {
      return false;
    }

    if (options?.isCurrentNavigation?.() === false) {
      return false;
    }

    void (async (): Promise<void> => {
      await sleep(CAPTIVE_PORTAL_NATIVE_RECOVERY_RETRY_DELAY_MS);

      if (options?.isCurrentNavigation?.() === false) {
        return;
      }

      try {
        await deps.retryNavigation(context.tabId, context.url);
      } catch (error) {
        logger.info('[Monitor] Captive portal recovery retry failed', {
          tabId: context.tabId,
          hostname: context.hostname,
          error: getErrorMessage(error),
        });
      }
    })();
    return true;
  }

  return {
    clearLimiter,
    disposeTab: (tabId): void => {
      for (const key of recoveryAttemptByTabAndHost.keys()) {
        if (key.startsWith(`${tabId.toString()}:`)) {
          recoveryAttemptByTabAndHost.delete(key);
        }
      }
    },
    handleConnectivityAvailable: async (): Promise<void> => {
      clearLimiter();
      await reconcileCaptivePortalRecovery({ reason: 'connectivity-available' });
    },
    handlePortalStateChanged: async (state): Promise<void> => {
      clearLimiter();
      if (state !== 'locked_portal') {
        await reconcileCaptivePortalRecovery({ reason: 'state-changed', state });
      }
    },
    recoverNavigation,
  };
}
