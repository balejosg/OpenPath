import type {
  ConfirmBlockedScreenContext,
  NativeBlockedScreenConfirmation,
} from './blocked-screen-navigation-controller.js';
import type { VerifyResponse } from './native-messaging-client.js';
import { withTimeoutOrFallback } from './async-timeout.js';

// Black-hole IPs the endpoint agents sinkhole blocked domains to (RFC 5737 TEST-NET-1 and the IPv6
// discard prefix). A domain that "resolves" only to one of these is not actually reachable, so it
// counts as blocked rather than allowed. Kept in sync with linux/lib/dns-dnsmasq.sh sinkhole config.
const BLOCKED_DNS_SENTINELS = new Set(['0.0.0.0', '::', '192.0.2.1', '100::']);

// How long a confirmed "blocked" decision stays usable without re-asking the native host. Keeps
// repeat navigations to the same blocked domain instant while bounding staleness.
const BLOCKED_SCREEN_DECISION_TTL_MS = 5_000;

// Upper bound on how long the blocked-screen confirmation waits for the native host. A slow or hung
// host must not stall the decision; on timeout we treat it as "not confirmed" and fall back to the
// reactive navigation-error path instead of blocking the preflight.
const BLOCKED_SCREEN_NATIVE_CONFIRM_TIMEOUT_MS = 1_500;

export function isNativePolicyBlockedResult(
  result: VerifyResponse['results'][number] | undefined
): boolean {
  // Fail open on anything that is not an affirmative policy decision: a missing result, an
  // explicitly inactive policy (policyActive === false), or an errored native check are all
  // "not a policy block", so a transport failure never shows the blocked screen on its own. A
  // missing policyActive is left as unknown (we do NOT fail open for it) and falls through.
  if (!result || result.policyActive === false || result.error) {
    return false;
  }

  const resolvedIp =
    typeof result.resolvedIp === 'string' && result.resolvedIp.length > 0
      ? result.resolvedIp
      : null;
  // A domain that only resolves to a sinkhole sentinel is not actually reachable, so it does not
  // count as resolving to a real IP. Trust the native host's explicit `resolves` when present.
  const resolvesToRealIp = resolvedIp !== null && !BLOCKED_DNS_SENTINELS.has(resolvedIp);
  const resolves = result.resolves ?? resolvesToRealIp;
  return !result.inWhitelist && !resolves;
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

  // Short-TTL cache of confirmed "blocked" decisions, keyed by normalized hostname. Lets repeat
  // navigations to the same blocked domain show the blocked screen instantly without another native
  // round-trip. Only positive (confirmed blocked) decisions are cached; cleared on whitelist updates.
  const decisionCache = new Map<
    string,
    { blocked: boolean; portalRecoveryEligible?: boolean; expiresAt: number }
  >();

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

    // Bound the native check so a slow/hung host cannot stall the blocked-screen decision. A
    // timeout (or any failure) is not a confirmation: return not-blocked and let the reactive
    // navigation-error path retry, never cache it.
    const response = await withTimeoutOrFallback(
      checkDomains([context.hostname], {
        error: context.error,
        source: 'blocked-screen-navigation',
      }),
      nativeConfirmTimeoutMs,
      { success: false, results: [] }
    );
    if (!response.success) {
      return { blocked: false };
    }

    const result = response.results.find((item) => item.domain === context.hostname);
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
    if (decision.blocked) {
      decisionCache.set(cacheKey, {
        ...decision,
        expiresAt: now() + decisionTtlMs,
      });
    } else {
      decisionCache.delete(cacheKey);
    }

    return decision;
  }

  function clearCache(): void {
    decisionCache.clear();
  }

  return { confirm, clearCache };
}
