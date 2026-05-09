import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  buildSubmitBlockedDomainInput,
  createBackgroundMessageHandler,
} from '../src/lib/background-message-handler.js';
import { SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION } from '../src/lib/blocked-screen-contract.js';

function createHandlerFixture(
  overrides: Partial<Parameters<typeof createBackgroundMessageHandler>[0]> = {}
): ReturnType<typeof createBackgroundMessageHandler> {
  return createBackgroundMessageHandler({
    clearBlockedDomains: () => undefined,
    evaluateBlockedPathDebug: ({ type, url }) => ({ cancel: type === 'fetch', url }),
    evaluateBlockedSubdomainDebug: ({ type, url }) => ({
      cancel: type === 'xmlhttprequest',
      url,
    }),
    forceBlockedPathRulesRefresh: () => Promise.resolve({ success: true }),
    forceBlockedSubdomainRulesRefresh: () => Promise.resolve({ success: true }),
    getBlockedDomainsForTab: (tabId) => ({ [`tab-${tabId.toString()}`]: { errors: [] } }),
    getDomainStatusesForTab: (tabId) => ({ [`tab-${tabId.toString()}`]: { state: 'detected' } }),
    getErrorMessage: (error) => (error instanceof Error ? error.message : String(error)),
    getMachineToken: () => Promise.resolve({ success: true, token: 'machine-token' }),
    getNativeBlockedPathsDebug: () => Promise.resolve({ success: true, paths: ['example.com/*'] }),
    getNativeBlockedSubdomainsDebug: () =>
      Promise.resolve({ success: true, subdomains: ['ads.example.org'] }),
    getPathRulesDebug: () => ({
      success: true,
      version: 'v1',
      count: 1,
      rawRules: ['example.com/*'],
      compiledPatterns: ['*://example.com/*'],
    }),
    getSubdomainRulesDebug: () => ({
      success: true,
      version: 'v1',
      count: 1,
      rawRules: ['ads.example.org'],
    }),
    getOpenPathDiagnostics: (domains) =>
      Promise.resolve({
        success: true,
        extensionOrigin: 'moz-extension://unit-test/',
        manifestVersion: '2.0.0',
        nativeAvailable: true,
        nativeCheck: {
          success: true,
          results: domains.map((domain) => ({
            domain,
            inWhitelist: false,
            policyActive: true,
            resolves: false,
          })),
        },
        pathRules: {
          success: true,
          version: 'v1',
          count: 1,
          rawRules: ['example.com/*'],
          compiledPatterns: ['*://example.com/*'],
        },
        subdomainRules: {
          success: true,
          version: 'v1',
          count: 1,
          rawRules: ['ads.example.org'],
        },
      }),
    getSystemHostname: () => Promise.resolve({ success: true, hostname: 'lab-pc-01' }),
    isNativeHostAvailable: () => Promise.resolve(true),
    retryLocalUpdate: () => Promise.resolve({ success: true }),
    submitBlockedDomainRequest: (input) =>
      Promise.resolve({
        success: true,
        status: 'pending',
        ...(input.domain !== undefined ? { domain: input.domain } : {}),
      }),
    triggerWhitelistUpdate: () => Promise.resolve({ success: true }),
    verifyDomains: (domains) =>
      Promise.resolve({
        success: true,
        results: domains.map((domain) => ({ domain, inWhitelist: true })),
      }),
    ...overrides,
  });
}

await describe('background message handler', async () => {
  await test('builds submit payload without display-only fields', () => {
    assert.deepEqual(
      buildSubmitBlockedDomainInput({
        action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
        domain: 'example.com',
        error: 'NS_ERROR_UNKNOWN_HOST',
        origin: 'portal.school',
        reason: 'needed for class',
        tabId: 5,
      }),
      {
        domain: 'example.com',
        error: 'NS_ERROR_UNKNOWN_HOST',
        origin: 'portal.school',
        reason: 'needed for class',
      }
    );
  });

  await test('returns path-rule debug payloads through the injected provider', async () => {
    const handler = createHandlerFixture();

    const response = await handler({ action: 'getBlockedPathRulesDebug', tabId: 1 }, {});

    assert.deepEqual(response, {
      success: true,
      version: 'v1',
      count: 1,
      rawRules: ['example.com/*'],
      compiledPatterns: ['*://example.com/*'],
    });
  });

  await test('returns subdomain-rule debug payloads through the injected provider', async () => {
    const handler = createHandlerFixture();

    const response = await handler({ action: 'getBlockedSubdomainRulesDebug', tabId: 1 }, {});

    assert.deepEqual(response, {
      success: true,
      version: 'v1',
      count: 1,
      rawRules: ['ads.example.org'],
    });
  });

  await test('returns blocked-domain and domain-status snapshots for the tab', async () => {
    const handler = createHandlerFixture();

    assert.deepEqual(await handler({ action: 'getBlockedDomains', tabId: 7 }, {}), {
      domains: {
        'tab-7': { errors: [] },
      },
    });
    assert.deepEqual(await handler({ action: 'getDomainStatuses', tabId: 7 }, {}), {
      statuses: {
        'tab-7': { state: 'detected' },
      },
    });
  });

  await test('clears blocked-domain state through the injected store', async () => {
    let clearedTabId: number | undefined;
    const handler = createHandlerFixture({
      clearBlockedDomains: (tabId) => {
        clearedTabId = tabId;
      },
    });

    const response = await handler({ action: 'clearBlockedDomains', tabId: 4 }, {});

    assert.equal(clearedTabId, 4);
    assert.deepEqual(response, { success: true });
  });

  await test('returns native blocked-path debug failures as structured errors', async () => {
    const handler = createHandlerFixture({
      getNativeBlockedPathsDebug: () => Promise.reject(new Error('native debug failed')),
    });

    const response = await handler({ action: 'getNativeBlockedPathsDebug', tabId: 1 }, {});

    assert.deepEqual(response, {
      success: false,
      error: 'native debug failed',
    });
  });

  await test('maps blocked-path evaluation requests through the injected evaluator', async () => {
    const handler = createHandlerFixture();

    const response = await handler(
      {
        action: 'evaluateBlockedPathDebug',
        tabId: 1,
        type: 'fetch',
        url: 'https://example.com/private',
      },
      {}
    );

    assert.deepEqual(response, {
      success: true,
      outcome: {
        cancel: true,
        url: 'https://example.com/private',
      },
    });
  });

  await test('maps blocked-subdomain evaluation requests through the injected evaluator', async () => {
    const handler = createHandlerFixture();

    const response = await handler(
      {
        action: 'evaluateBlockedSubdomainDebug',
        tabId: 1,
        type: 'xmlhttprequest',
        url: 'https://ads.example.org/pixel',
      },
      {}
    );

    assert.deepEqual(response, {
      success: true,
      outcome: {
        cancel: true,
        url: 'https://ads.example.org/pixel',
      },
    });
  });

  await test('returns extension diagnostics for canary boundary checks', async () => {
    const handler = createHandlerFixture();

    const response = await handler(
      {
        action: 'getOpenPathDiagnostics',
        domains: ['blocked.example'],
        tabId: 1,
      },
      {}
    );

    assert.deepEqual(response, {
      success: true,
      extensionOrigin: 'moz-extension://unit-test/',
      manifestVersion: '2.0.0',
      nativeAvailable: true,
      nativeCheck: {
        success: true,
        results: [
          {
            domain: 'blocked.example',
            inWhitelist: false,
            policyActive: true,
            resolves: false,
          },
        ],
      },
      pathRules: {
        success: true,
        version: 'v1',
        count: 1,
        rawRules: ['example.com/*'],
        compiledPatterns: ['*://example.com/*'],
      },
      subdomainRules: {
        success: true,
        version: 'v1',
        count: 1,
        rawRules: ['ads.example.org'],
      },
    });
  });

  await test('returns extension diagnostic failures as structured errors', async () => {
    const handler = createHandlerFixture({
      getOpenPathDiagnostics: () => Promise.reject(new Error('diagnostics failed')),
    });

    const response = await handler(
      {
        action: 'getOpenPathDiagnostics',
        domains: 'not-a-list',
        tabId: 1,
      },
      {}
    );

    assert.deepEqual(response, {
      success: false,
      error: 'diagnostics failed',
    });
  });

  await test('accepts page activity wake-up messages without native side effects', async () => {
    const handler = createHandlerFixture({
      getMachineToken: () => Promise.reject(new Error('should not be called')),
      getOpenPathDiagnostics: () => Promise.reject(new Error('should not be called')),
      getSystemHostname: () => Promise.reject(new Error('should not be called')),
      isNativeHostAvailable: () => Promise.reject(new Error('should not be called')),
      triggerWhitelistUpdate: () => Promise.reject(new Error('should not be called')),
    });

    const response = await handler(
      {
        action: 'openpathPageActivity',
        url: 'https://allowed.example/app',
        tabId: 1,
      },
      {}
    );

    assert.deepEqual(response, { success: true });
  });

  await test('verifies domains through both message aliases and reports failures', async () => {
    const handler = createHandlerFixture();
    const failingHandler = createHandlerFixture({
      verifyDomains: () => Promise.reject(new Error('verify failed')),
    });

    assert.deepEqual(
      await handler({ action: 'checkWithNative', domains: ['example.com'], tabId: 1 }, {}),
      {
        success: true,
        results: [{ domain: 'example.com', inWhitelist: true }],
      }
    );
    assert.deepEqual(await handler({ action: 'verifyDomains', domains: 'invalid', tabId: 1 }, {}), {
      success: true,
      results: [],
    });
    assert.deepEqual(
      await failingHandler({ action: 'verifyDomains', domains: ['example.com'], tabId: 1 }, {}),
      {
        success: false,
        results: [],
        error: 'verify failed',
      }
    );
  });

  await test('checks native availability through both message aliases', async () => {
    const handler = createHandlerFixture();
    const unavailableHandler = createHandlerFixture({
      isNativeHostAvailable: () => Promise.resolve(false),
    });
    const failingHandler = createHandlerFixture({
      isNativeHostAvailable: () => Promise.reject(new Error('native unavailable')),
    });

    assert.deepEqual(await handler({ action: 'isNativeAvailable', tabId: 1 }, {}), {
      available: true,
      success: true,
    });
    assert.deepEqual(await unavailableHandler({ action: 'checkNative', tabId: 1 }, {}), {
      available: false,
      success: false,
    });
    assert.deepEqual(await failingHandler({ action: 'checkNative', tabId: 1 }, {}), {
      available: false,
      success: false,
    });
  });

  await test('returns hostname and machine-token failures as structured errors', async () => {
    const handler = createHandlerFixture({
      getMachineToken: () => Promise.reject(new Error('token failed')),
      getSystemHostname: () => Promise.reject(new Error('hostname failed')),
    });

    assert.deepEqual(await handler({ action: 'getHostname', tabId: 1 }, {}), {
      success: false,
      error: 'hostname failed',
    });
    assert.deepEqual(await handler({ action: 'getMachineToken', tabId: 1 }, {}), {
      success: false,
      error: 'token failed',
    });
  });

  await test('validates blocked-domain submissions before delegating', async () => {
    const handler = createHandlerFixture();

    const response = await handler(
      {
        action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
        tabId: 1,
      },
      {}
    );

    assert.deepEqual(response, {
      success: false,
      error: 'domain and reason are required',
    });
  });

  await test('delegates blocked-domain submission with the normalized request input', async () => {
    let capturedInput: unknown;
    const handler = createHandlerFixture({
      submitBlockedDomainRequest: (input) => {
        capturedInput = input;
        return Promise.resolve({ success: true, status: 'pending' });
      },
    });

    const response = await handler(
      {
        action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
        tabId: 1,
        domain: 'example.com',
        reason: 'needed for class',
        origin: 'portal.school',
      },
      {}
    );

    assert.deepEqual(capturedInput, {
      domain: 'example.com',
      reason: 'needed for class',
      origin: 'portal.school',
    });
    assert.deepEqual(response, { success: true, status: 'pending' });
  });

  await test('reports blocked-domain submission failures as structured errors', async () => {
    const handler = createHandlerFixture({
      submitBlockedDomainRequest: () => Promise.reject(new Error('submit failed')),
    });

    const response = await handler(
      {
        action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
        tabId: 1,
        domain: 'example.com',
        reason: 'needed for class',
      },
      {}
    );

    assert.deepEqual(response, {
      success: false,
      error: 'submit failed',
    });
  });

  await test('returns a recent successful blocked-domain submission for replacement blocked pages', async () => {
    const handler = createHandlerFixture({
      submitBlockedDomainRequest: (input) =>
        Promise.resolve({
          success: true,
          id: 'request-1',
          status: 'pending',
          ...(input.domain !== undefined ? { domain: input.domain } : {}),
        }),
    });

    await handler(
      {
        action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
        tabId: 1,
        domain: 'example.com',
        reason: 'needed for class',
      },
      {}
    );

    const response = await handler(
      {
        action: 'getRecentBlockedDomainRequestStatus',
        tabId: 1,
        domain: 'example.com',
      },
      {}
    );

    assert.deepEqual(response, {
      success: true,
      request: {
        success: true,
        id: 'request-1',
        status: 'pending',
        domain: 'example.com',
      },
    });
  });

  await test('does not cache failed or expired blocked-domain submission statuses', async () => {
    const realNow = Date.now;
    let now = 1_000;
    Date.now = (): number => now;
    try {
      const handler = createHandlerFixture({
        submitBlockedDomainRequest: () =>
          Promise.resolve({
            success: false,
            error: 'rejected',
          }),
      });

      await handler(
        {
          action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
          tabId: 1,
          domain: 'failed.example',
          reason: 'needed for class',
        },
        {}
      );
      assert.deepEqual(
        await handler(
          {
            action: 'getRecentBlockedDomainRequestStatus',
            tabId: 1,
            domain: 'failed.example',
          },
          {}
        ),
        { success: true, request: null }
      );

      const expiringHandler = createHandlerFixture();
      await expiringHandler(
        {
          action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
          tabId: 1,
          domain: 'expired.example',
          reason: 'needed for class',
        },
        {}
      );
      now += 121_000;
      assert.deepEqual(
        await expiringHandler(
          {
            action: 'getRecentBlockedDomainRequestStatus',
            tabId: 1,
            domain: 'expired.example',
          },
          {}
        ),
        { success: true, request: null }
      );
    } finally {
      Date.now = realNow;
    }
  });

  await test('validates recent blocked-domain status messages', async () => {
    const handler = createHandlerFixture();

    const response = await handler(
      {
        action: 'getRecentBlockedDomainRequestStatus',
        tabId: 1,
      },
      {}
    );

    assert.deepEqual(response, {
      success: false,
      error: 'domain is required',
    });
  });

  await test('triggers native refresh operations and reports failures', async () => {
    const handler = createHandlerFixture();
    const failingHandler = createHandlerFixture({
      triggerWhitelistUpdate: () => Promise.reject(new Error('update failed')),
    });

    assert.deepEqual(await handler({ action: 'triggerWhitelistUpdate', tabId: 1 }, {}), {
      success: true,
    });
    assert.deepEqual(await failingHandler({ action: 'triggerWhitelistUpdate', tabId: 1 }, {}), {
      success: false,
      error: 'update failed',
    });
    assert.deepEqual(await handler({ action: 'refreshBlockedPathRules', tabId: 1 }, {}), {
      success: true,
    });
    assert.deepEqual(await handler({ action: 'refreshBlockedSubdomainRules', tabId: 1 }, {}), {
      success: true,
    });
  });

  await test('reports hostname validation errors for retryLocalUpdate', async () => {
    let retryInput: { tabId: number; hostname: string } | undefined;
    const handler = createHandlerFixture({
      retryLocalUpdate: (tabId, hostname) => {
        retryInput = { tabId, hostname };
        return Promise.resolve({ success: true });
      },
    });

    const response = await handler({ action: 'retryLocalUpdate', tabId: 1 }, {});

    assert.deepEqual(response, {
      success: false,
      error: 'hostname is required',
    });
    assert.deepEqual(
      await handler({ action: 'retryLocalUpdate', tabId: 2, hostname: 'example.com' }, {}),
      { success: true }
    );
    assert.deepEqual(retryInput, { tabId: 2, hostname: 'example.com' });
  });

  await test('reports unknown actions without side effects', async () => {
    const handler = createHandlerFixture();

    const response = await handler({ action: 'notSupported', tabId: 1 }, {});

    assert.deepEqual(response, { error: 'Unknown action' });
  });
});
