import type {
  ConfirmBlockedScreenContext,
  NativeBlockedScreenConfirmation,
} from './blocked-screen-navigation-controller.js';
import type { VerifyResponse } from './native-messaging-client.js';
import { logger } from './logger.js';
import { normalizePolicyDecision, permitsPolicyRedirect } from './policy-decision.js';

// How long a confirmed "blocked" decision stays usable without re-asking the native host. Keeps
// repeat navigations to the same blocked domain instant while bounding staleness.
const BLOCKED_SCREEN_DECISION_TTL_MS = 5_000;

// Upper bound on how long the blocked-screen confirmation waits for the native host. A slow or hung
// host must not stall the decision; on timeout we treat it as "not confirmed" and fall back to the
// reactive navigation-error path instead of blocking the preflight.
//
// Must fit the Windows native host's cold-start round trip: the host is a PowerShell script spawned
// per session (Firefox kills idle hosts), so the first check pays script engine startup, support-file
// dot-sourcing, and state reads. Measured ~0.9-1.0s on runner-class hardware without AV; student
// machines with real-time AV can take several seconds. Keep the bound above that range while still
// failing open promptly on a genuinely dead host.
const BLOCKED_SCREEN_NATIVE_CONFIRM_TIMEOUT_MS = 4_000;
const BLOCKED_SCREEN_NATIVE_CONFIRM_HARD_TIMEOUT_MS = 12_000;
type TimerHandle = number | ReturnType<typeof setTimeout>;

export function isNativePolicyBlockedResult(
  result: VerifyResponse['results'][number] | undefined
): boolean {
  return result ? permitsPolicyRedirect(normalizePolicyDecision(result)) : false;
}

export interface BlockedScreenConfirmerDeps {
  // Asks the native host whether the given domains are blocked by policy.
  checkDomains: (
    domains: string[],
    context?: { error?: string; source?: string }
  ) => Promise<VerifyResponse>;
  // Clock used for the decision-cache TTL; injectable for tests.
  now: () => number;
  // Reports the native host's captive-portal recovery eligibility for a host. The caller owns the
  // shared eligibility map and the recovery limiter, so it decides what a change means.
  recordPortalRecoveryEligibility?: (hostname: string, eligible: boolean) => void;
  // Overridable timings (default to the module constants); injectable for fast, deterministic tests.
  decisionTtlMs?: number;
  nativeConfirmTimeoutMs?: number;
  nativeConfirmHardTimeoutMs?: number;
  clearTimeoutFn?: (handle: TimerHandle) => void;
  setTimeoutFn?: (callback: () => void, delayMs: number) => TimerHandle;
}

export interface BlockedScreenConfirmer {
  // Decide whether a navigation should show the blocked screen, confirming with the native host.
  confirm: (context: ConfirmBlockedScreenContext) => Promise<NativeBlockedScreenConfirmation>;
  // Drop all cached decisions (e.g. after a whitelist update changed policy).
  clearCache: () => void;
}

// Owns the short-TTL "is this domain blocked by policy?" decision cache and the bounded native
// round-trip behind it. Extracted from the background runtime so it can be unit-tested in isolation
// instead of through the full init() harness.
export function createBlockedScreenConfirmer(
  deps: BlockedScreenConfirmerDeps
): BlockedScreenConfirmer {
  const { checkDomains, now, recordPortalRecoveryEligibility } = deps;
  const decisionTtlMs = deps.decisionTtlMs ?? BLOCKED_SCREEN_DECISION_TTL_MS;
  const nativeConfirmTimeoutMs =
    deps.nativeConfirmTimeoutMs ?? BLOCKED_SCREEN_NATIVE_CONFIRM_TIMEOUT_MS;
  const nativeConfirmHardTimeoutMs =
    deps.nativeConfirmHardTimeoutMs ?? BLOCKED_SCREEN_NATIVE_CONFIRM_HARD_TIMEOUT_MS;
  const clearTimeoutFn = deps.clearTimeoutFn ?? clearTimeout;
  const setTimeoutFn = deps.setTimeoutFn ?? setTimeout;

  // Short-TTL cache of confirmed "blocked" decisions, keyed by normalized hostname. Lets repeat
  // navigations to the same blocked domain show the blocked screen instantly without another native
  // round-trip. Only positive (confirmed blocked) decisions are cached; cleared on whitelist updates.
  const decisionCache = new Map<
    string,
    { blocked: boolean; portalRecoveryEligible?: boolean; expiresAt: number }
  >();
  const inFlight = new Map<string, Promise<NativeBlockedScreenConfirmation>>();
  let policyEpoch = 0;

  async function confirm(
    context: ConfirmBlockedScreenContext
  ): Promise<NativeBlockedScreenConfirmation> {
    const cacheKey = context.hostname.trim().toLowerCase();
    const cached = decisionCache.get(cacheKey);
    if (cached && cached.expiresAt > now()) {
      return {
        blocked: cached.blocked,
        ...(cached.portalRecoveryEligible !== undefined
          ? { portalRecoveryEligible: cached.portalRecoveryEligible }
          : {}),
      };
    }

    const existing = inFlight.get(cacheKey);
    if (existing) return existing;
    const startedEpoch = policyEpoch;
    const request = (async (): Promise<NativeBlockedScreenConfirmation> => {
      const softTimer = setTimeoutFn(() => {
        logger.info('[Monitor] Native policy check exceeded soft timeout', {
          code: 'native-soft-timeout',
          elapsedMs: nativeConfirmTimeoutMs,
          source: 'blocked-screen-navigation',
        });
      }, nativeConfirmTimeoutMs);
      let hardTimer: TimerHandle | undefined;
      const response = await Promise.race([
        checkDomains([context.hostname], {
          error: context.error,
          source: 'blocked-screen-navigation',
        }).catch(
          (error: unknown): VerifyResponse => ({
            success: false,
            results: [],
            error: error instanceof Error ? error.message : String(error),
          })
        ),
        new Promise<VerifyResponse>((resolve) => {
          hardTimer = setTimeoutFn(() => {
            resolve({ success: false, results: [], error: 'native-hard-timeout' });
          }, nativeConfirmHardTimeoutMs);
        }),
      ]);
      clearTimeoutFn(softTimer);
      if (hardTimer !== undefined) clearTimeoutFn(hardTimer);
      if (response.error === 'native-hard-timeout') {
        logger.info('[Monitor] Native policy check reached hard timeout', {
          code: 'native-hard-timeout',
          elapsedMs: nativeConfirmHardTimeoutMs,
          source: 'blocked-screen-navigation',
        });
      }
      if (!response.success || startedEpoch !== policyEpoch) return { blocked: false };

      const result = response.results.find((item) => item.domain.trim().toLowerCase() === cacheKey);
      if (result?.portalRecoveryEligible !== undefined) {
        recordPortalRecoveryEligibility?.(cacheKey, result.portalRecoveryEligible);
      }

      const decision: NativeBlockedScreenConfirmation = {
        blocked: isNativePolicyBlockedResult(result),
        ...(result?.portalRecoveryEligible !== undefined
          ? { portalRecoveryEligible: result.portalRecoveryEligible }
          : {}),
      };

      // Cache only confirmed blocks. Allowed/unknown verdicts are never cached, so a domain that
      // later becomes blocked is re-evaluated immediately; a stale "blocked" is bounded by the TTL
      // and invalidated on whitelist updates (see clearCache).
      if (decision.blocked && startedEpoch === policyEpoch) {
        decisionCache.set(cacheKey, {
          ...decision,
          expiresAt: now() + decisionTtlMs,
        });
      } else {
        decisionCache.delete(cacheKey);
      }

      return decision;
    })().finally(() => {
      if (inFlight.get(cacheKey) === request) inFlight.delete(cacheKey);
    });
    inFlight.set(cacheKey, request);
    return request;
  }

  function clearCache(): void {
    policyEpoch += 1;
    decisionCache.clear();
    inFlight.clear();
  }

  return { confirm, clearCache };
}
