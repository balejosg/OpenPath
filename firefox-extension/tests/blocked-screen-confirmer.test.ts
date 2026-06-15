import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  createBlockedScreenConfirmer,
  isNativePolicyBlockedResult,
  type BlockedScreenConfirmerDeps,
} from '../src/lib/blocked-screen-confirmer.js';
import type { ConfirmBlockedScreenContext } from '../src/lib/blocked-screen-navigation-controller.js';
import type { VerifyResponse } from '../src/lib/native-messaging-client.js';

function context(hostname: string, error = 'NS_ERROR_NET_TIMEOUT'): ConfirmBlockedScreenContext {
  return {
    tabId: 5,
    hostname,
    error,
    origin: null,
    url: `https://${hostname}/page`,
  };
}

// A native response confirming each domain as a policy block: not whitelisted, policy active, does
// not resolve to a real IP.
function blockedResponse(domains: string[]): VerifyResponse {
  return {
    success: true,
    results: domains.map((domain) => ({
      domain,
      inWhitelist: false,
      policyActive: true,
      resolves: false,
    })),
  };
}

// A native response that allows each domain (whitelisted), so it must never be cached as blocked.
function allowedResponse(domains: string[]): VerifyResponse {
  return {
    success: true,
    results: domains.map((domain) => ({
      domain,
      inWhitelist: true,
      policyActive: true,
      resolves: false,
    })),
  };
}

// Wraps a responder so the test can count how many native checks the confirmer actually issued.
function countingCheck(responder: (domains: string[]) => Promise<VerifyResponse>): {
  check: BlockedScreenConfirmerDeps['checkDomains'];
  calls: () => number;
  lastDomains: () => string[] | undefined;
} {
  const records: string[][] = [];
  const check: BlockedScreenConfirmerDeps['checkDomains'] = (domains) => {
    records.push(domains);
    return responder(domains);
  };
  return {
    check,
    calls: () => records.length,
    lastDomains: () => records.at(-1),
  };
}

void test('native policy confirmation ignores fail-open or inactive policy results', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'portal.fixture.test',
      inWhitelist: false,
      policyActive: false,
      resolves: false,
    }),
    false
  );
});

void test('native policy confirmation treats missing policy state as unknown, not inactive', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'legacy-native-host.example',
      inWhitelist: false,
      resolves: false,
    }),
    true
  );
});

void test('native policy confirmation ignores errored native check results', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'broken-native-host.example',
      error: 'OpenPath whitelist command not found',
      inWhitelist: false,
      policyActive: true,
      resolves: false,
    }),
    false
  );
});

void test('native policy confirmation requires a denied domain that does not resolve publicly', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'blocked.example',
      inWhitelist: false,
      policyActive: true,
      resolves: false,
    }),
    true
  );
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'allowed.example',
      inWhitelist: false,
      policyActive: true,
      resolves: true,
    }),
    false
  );
});

void test('native policy confirmation treats null resolvedIp as unresolved', () => {
  assert.equal(
    isNativePolicyBlockedResult({
      domain: 'legacy-null-ip.example',
      inWhitelist: false,
      policyActive: true,
      resolvedIp: null,
    } as unknown as Parameters<typeof isNativePolicyBlockedResult>[0]),
    true
  );
});

void test('confirmer reports a native-confirmed policy block', async () => {
  const native = countingCheck((domains) => Promise.resolve(blockedResponse(domains)));
  const confirmer = createBlockedScreenConfirmer({ checkDomains: native.check, now: () => 1000 });

  const decision = await confirmer.confirm(context('blocked.example'));
  assert.deepEqual(decision, { blocked: true });
  assert.deepEqual(native.lastDomains(), ['blocked.example']);
});

void test('confirmer serves a repeat blocked host from cache without a second native check', async () => {
  const native = countingCheck((domains) => Promise.resolve(blockedResponse(domains)));
  const confirmer = createBlockedScreenConfirmer({ checkDomains: native.check, now: () => 1000 });

  assert.deepEqual(await confirmer.confirm(context('blocked.example')), { blocked: true });
  assert.deepEqual(await confirmer.confirm(context('blocked.example')), { blocked: true });
  assert.equal(native.calls(), 1);
});

void test('confirmer normalizes the cache key by host case and whitespace', async () => {
  const native = countingCheck((domains) => Promise.resolve(blockedResponse(domains)));
  const confirmer = createBlockedScreenConfirmer({ checkDomains: native.check, now: () => 1000 });

  await confirmer.confirm(context('Blocked.Example'));
  await confirmer.confirm(context('  blocked.example  '));
  assert.equal(native.calls(), 1);
});

void test('confirmer re-checks a blocked host after the decision TTL expires', async () => {
  let currentNow = 1000;
  const native = countingCheck((domains) => Promise.resolve(blockedResponse(domains)));
  const confirmer = createBlockedScreenConfirmer({
    checkDomains: native.check,
    now: () => currentNow,
    decisionTtlMs: 5000,
  });

  await confirmer.confirm(context('blocked.example'));
  assert.equal(native.calls(), 1);

  currentNow = 1000 + 5001;
  await confirmer.confirm(context('blocked.example'));
  assert.equal(native.calls(), 2);
});

void test('confirmer drops cached decisions on clearCache', async () => {
  const native = countingCheck((domains) => Promise.resolve(blockedResponse(domains)));
  const confirmer = createBlockedScreenConfirmer({ checkDomains: native.check, now: () => 1000 });

  await confirmer.confirm(context('blocked.example'));
  assert.equal(native.calls(), 1);

  confirmer.clearCache();
  await confirmer.confirm(context('blocked.example'));
  assert.equal(native.calls(), 2);
});

void test('confirmer never caches an allowed verdict', async () => {
  const native = countingCheck((domains) => Promise.resolve(allowedResponse(domains)));
  const confirmer = createBlockedScreenConfirmer({ checkDomains: native.check, now: () => 1000 });

  assert.deepEqual(await confirmer.confirm(context('allowed.example')), { blocked: false });
  // A later visit must re-evaluate, never short-circuit on a cached "allowed".
  await confirmer.confirm(context('allowed.example'));
  assert.equal(native.calls(), 2);
});

void test('confirmer treats a failed native response as not-blocked and does not cache it', async () => {
  const native = countingCheck(() => Promise.resolve({ success: false, results: [] }));
  const confirmer = createBlockedScreenConfirmer({ checkDomains: native.check, now: () => 1000 });

  assert.deepEqual(await confirmer.confirm(context('blocked.example')), { blocked: false });
  await confirmer.confirm(context('blocked.example'));
  assert.equal(native.calls(), 2);
});

void test('confirmer falls back to not-blocked when the native host does not answer in time', async () => {
  const native = countingCheck(() => new Promise<VerifyResponse>(() => undefined));
  const confirmer = createBlockedScreenConfirmer({
    checkDomains: native.check,
    now: () => 1000,
    nativeConfirmTimeoutMs: 5,
  });

  assert.deepEqual(await confirmer.confirm(context('blocked.example')), { blocked: false });
  // A timeout is not a confirmation, so it is never cached: the next visit checks again.
  await confirmer.confirm(context('blocked.example'));
  assert.equal(native.calls(), 2);
});

void test('confirmer reports captive-portal recovery eligibility through the injected callback', async () => {
  const eligibility: { hostname: string; eligible: boolean }[] = [];
  const native = countingCheck((domains) =>
    Promise.resolve({
      success: true,
      results: domains.map((domain) => ({
        domain,
        inWhitelist: false,
        policyActive: true,
        portalRecoveryEligible: true,
        resolves: false,
      })),
    })
  );
  const confirmer = createBlockedScreenConfirmer({
    checkDomains: native.check,
    now: () => 1000,
    recordPortalRecoveryEligibility: (hostname, eligible) => {
      eligibility.push({ hostname, eligible });
    },
  });

  const decision = await confirmer.confirm(context('Portal.Example'));
  assert.deepEqual(decision, { blocked: true, portalRecoveryEligible: true });
  assert.deepEqual(eligibility, [{ hostname: 'portal.example', eligible: true }]);
});
