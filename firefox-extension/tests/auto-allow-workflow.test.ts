import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  createAutoAllowWorkflow,
  isAutoAllowRequestType,
  resolveAutoAllowState,
} from '../src/lib/auto-allow-workflow.js';

const AUTO_ALLOW_PAGE_RESOURCE_TYPES = [
  'xmlhttprequest',
  'fetch',
  'script',
  'stylesheet',
  'image',
  'object',
  'xslt',
  'ping',
  'beacon',
  'xml_dtd',
  'font',
  'media',
  'websocket',
  'csp_report',
  'imageset',
  'web_manifest',
  'speculative',
  'json',
  'other',
];

function createWorkflowFixture(
  overrides: Partial<Parameters<typeof createAutoAllowWorkflow>[0]> = {}
): {
  fixture: {
    inFlightAutoRequests: Map<string, Promise<void>>;
    refreshBlockedPathRulesCalls: number;
    requestLocalWhitelistUpdateCalls: number;
    sentMessages: unknown[];
  };
  statuses: Map<string, DomainStatus>;
  workflow: ReturnType<typeof createAutoAllowWorkflow>;
} {
  const statuses = new Map<string, DomainStatus>();
  const now = 1234567890;

  const fixture = {
    inFlightAutoRequests: new Map<string, Promise<void>>(),
    refreshBlockedPathRulesCalls: 0,
    requestLocalWhitelistUpdateCalls: 0,
    sentMessages: [] as unknown[],
  };

  const workflow = createAutoAllowWorkflow({
    getErrorMessage: (error) => (error instanceof Error ? error.message : String(error)),
    getRequestApiEndpoints: (config) =>
      [config.requestApiUrl, ...config.fallbackApiUrls].filter((url) => url.length > 0),
    getStoredDomainStatus: (_tabId, hostname) => statuses.get(hostname),
    inFlightAutoRequests: fixture.inFlightAutoRequests,
    loadRequestConfig: () =>
      Promise.resolve({
        enableRequests: true,
        fallbackApiUrls: [],
        requestApiUrl: 'https://api.example',
        requestTimeout: 1000,
      }),
    now: () => now,
    refreshBlockedPathRules: () => {
      fixture.refreshBlockedPathRulesCalls += 1;
      return Promise.resolve(true);
    },
    localWhitelistUpdateDebounceMs: 0,
    requestLocalWhitelistUpdate: () => {
      fixture.requestLocalWhitelistUpdateCalls += 1;
      return Promise.resolve(true);
    },
    sendNativeMessage: (message) => {
      fixture.sentMessages.push(message);
      if ((message as { action?: string }).action === 'get-hostname') {
        return Promise.resolve({ success: true, hostname: 'lab-pc-01' });
      }

      return Promise.resolve({ success: true, token: 'machine-token' });
    },
    setDomainStatus: (_tabId, hostname, status) => {
      statuses.set(hostname, status);
    },
    ...overrides,
  });

  return {
    fixture,
    statuses,
    workflow,
  };
}

async function waitForAssertion(assertion: () => void, timeoutMs = 1000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown;

  while (Date.now() <= deadline) {
    try {
      assertion();
      return;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
  }

  throw lastError;
}

await describe('auto allow workflow', async () => {
  await test('detects request types eligible for auto-allow', () => {
    for (const requestType of AUTO_ALLOW_PAGE_RESOURCE_TYPES) {
      assert.equal(isAutoAllowRequestType(requestType), true, requestType);
    }

    assert.equal(isAutoAllowRequestType('main_frame'), false);
    assert.equal(isAutoAllowRequestType('sub_frame'), false);
    assert.equal(isAutoAllowRequestType(undefined), false);
  });

  await test('resolves final states for auto-allow outcomes', () => {
    assert.equal(
      resolveAutoAllowState({
        apiSuccess: true,
        duplicate: false,
        localUpdateSuccess: true,
      }),
      'autoApproved'
    );
    assert.equal(
      resolveAutoAllowState({
        apiSuccess: true,
        duplicate: true,
        localUpdateSuccess: true,
      }),
      'duplicate'
    );
    assert.equal(
      resolveAutoAllowState({
        apiSuccess: true,
        duplicate: false,
        localUpdateSuccess: false,
      }),
      'localUpdateError'
    );
  });

  await test('marks a domain autoApproved after API and local update succeed', async () => {
    const requestBodies: unknown[] = [];
    const updatedHosts: string[][] = [];
    const { fixture, statuses, workflow } = createWorkflowFixture({
      fetchImpl: (_url, init) => {
        const body = typeof init?.body === 'string' ? init.body : '{}';
        requestBodies.push(JSON.parse(body));
        return Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'approved' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        );
      },
      requestLocalWhitelistUpdate: (hostnames) => {
        updatedHosts.push(hostnames);
        fixture.requestLocalWhitelistUpdateCalls += 1;
        return Promise.resolve(true);
      },
    });

    await workflow.autoAllowBlockedDomain(
      5,
      'example.com',
      'https://portal.school/app',
      'xmlhttprequest',
      'https://example.com/data.json'
    );

    assert.deepEqual(statuses.get('example.com'), {
      message: 'Auto-aprobado y actualizado',
      requestType: 'xmlhttprequest',
      state: 'autoApproved',
      updatedAt: 1234567890,
    });
    assert.deepEqual(requestBodies, [
      {
        domain: 'example.com',
        hostname: 'lab-pc-01',
        origin_page: 'https://portal.school/app',
        reason: 'auto-allow page-resource (xmlhttprequest)',
        target_url: 'https://example.com/data.json',
        diagnostic_context: {
          correlation_id: 'auto-5-example-com-xmlhttprequest-1234567890',
          request_type: 'xmlhttprequest',
          target_hostname: 'example.com',
        },
        token: 'machine-token',
      },
    ]);
    assert.deepEqual(updatedHosts, [['example.com']]);
    assert.equal(fixture.requestLocalWhitelistUpdateCalls, 1);
    assert.equal(fixture.refreshBlockedPathRulesCalls, 1);
  });

  await test('deduplicates concurrent auto-allow requests by page origin and hostname', async () => {
    let resolveLocalUpdate: ((value: boolean) => void) | undefined;
    const requestBodies: unknown[] = [];
    const updatedHosts: string[][] = [];
    const { fixture, workflow } = createWorkflowFixture({
      fetchImpl: (_url, init) => {
        const body = typeof init?.body === 'string' ? init.body : '{}';
        requestBodies.push(JSON.parse(body));
        return Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'approved' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        );
      },
      requestLocalWhitelistUpdate: (hostnames) => {
        updatedHosts.push(hostnames);
        fixture.requestLocalWhitelistUpdateCalls += 1;
        return new Promise<boolean>((resolve) => {
          resolveLocalUpdate = resolve;
        });
      },
    });

    const firstRequest = workflow.autoAllowBlockedDomain(
      5,
      'cdn.example.com',
      'https://portal.school/app',
      'script',
      'https://cdn.example.com/asset.js?attempt=1'
    );
    const secondRequest = workflow.autoAllowBlockedDomain(
      5,
      'cdn.example.com',
      'https://portal.school/app',
      'script',
      'https://cdn.example.com/asset.js?attempt=2'
    );

    await waitForAssertion(() => {
      assert.equal(requestBodies.length, 1);
      assert.deepEqual(updatedHosts, [['cdn.example.com']]);
      assert.equal(fixture.requestLocalWhitelistUpdateCalls, 1);
    });

    resolveLocalUpdate?.(true);
    await Promise.all([firstRequest, secondRequest]);
  });

  await test('waits for an in-flight pending local update before reusing domain status', async () => {
    let resolveLocalUpdate: ((value: boolean) => void) | undefined;
    const { fixture, workflow } = createWorkflowFixture({
      fetchImpl: () =>
        Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'approved' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        ),
      requestLocalWhitelistUpdate: () => {
        fixture.requestLocalWhitelistUpdateCalls += 1;
        return new Promise<boolean>((resolve) => {
          resolveLocalUpdate = resolve;
        });
      },
    });

    const firstRequest = workflow.autoAllowBlockedDomain(
      5,
      'cdn.example.com',
      'https://portal.school/app',
      'script',
      'https://cdn.example.com/asset.js?attempt=1'
    );

    await waitForAssertion(() => {
      assert.equal(fixture.requestLocalWhitelistUpdateCalls, 1);
    });

    let secondRequestResolved = false;
    const secondRequest = workflow
      .autoAllowBlockedDomain(
        5,
        'cdn.example.com',
        'https://portal.school/app',
        'script',
        'https://cdn.example.com/asset.js?attempt=2'
      )
      .then(() => {
        secondRequestResolved = true;
      });

    await waitForAssertion(() => {
      assert.equal(fixture.requestLocalWhitelistUpdateCalls, 1);
    });
    assert.equal(secondRequestResolved, false);

    resolveLocalUpdate?.(true);
    await Promise.all([firstRequest, secondRequest]);
    assert.equal(secondRequestResolved, true);
  });

  await test('does not repeat API calls for a host that was already auto-approved in the same tab', async () => {
    const requestBodies: unknown[] = [];
    const updatedHosts: string[][] = [];
    const { fixture, statuses, workflow } = createWorkflowFixture({
      fetchImpl: (_url, init) => {
        const body = typeof init?.body === 'string' ? init.body : '{}';
        requestBodies.push(JSON.parse(body));
        return Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'approved' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        );
      },
      requestLocalWhitelistUpdate: (hostnames) => {
        updatedHosts.push(hostnames);
        fixture.requestLocalWhitelistUpdateCalls += 1;
        return Promise.resolve(true);
      },
    });

    await workflow.autoAllowBlockedDomain(
      5,
      'cdn.example.com',
      'https://portal.school/app',
      'script',
      'https://cdn.example.com/asset.js?attempt=1'
    );
    await workflow.autoAllowBlockedDomain(
      5,
      'cdn.example.com',
      'https://portal.school/app',
      'script',
      'https://cdn.example.com/asset.js?attempt=2'
    );

    assert.equal(statuses.get('cdn.example.com')?.state, 'autoApproved');
    assert.equal(requestBodies.length, 1);
    assert.deepEqual(updatedHosts, [['cdn.example.com']]);
    assert.equal(fixture.requestLocalWhitelistUpdateCalls, 1);
  });

  await test('keeps pending API responses pending without refreshing the local whitelist', async () => {
    const { fixture, statuses, workflow } = createWorkflowFixture({
      fetchImpl: () =>
        Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'pending', id: 'req-1' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        ),
    });

    await workflow.autoAllowBlockedDomain(
      5,
      'example.com',
      'https://portal.school/app',
      'fetch',
      'https://example.com/data.json'
    );

    assert.deepEqual(statuses.get('example.com'), {
      message: 'Solicitud pendiente de aprobacion',
      requestType: 'fetch',
      state: 'pending',
      updatedAt: 1234567890,
    });
    assert.equal(fixture.requestLocalWhitelistUpdateCalls, 0);
    assert.equal(fixture.refreshBlockedPathRulesCalls, 0);
  });

  await test('batches local whitelist update for concurrent approved hosts', async () => {
    const updatedHosts: string[][] = [];
    const { fixture, workflow } = createWorkflowFixture({
      fetchImpl: (_url, _init) =>
        Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'approved' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        ),
      requestLocalWhitelistUpdate: (hostnames) => {
        updatedHosts.push(hostnames);
        fixture.requestLocalWhitelistUpdateCalls += 1;
        return Promise.resolve(true);
      },
      localWhitelistUpdateDebounceMs: 10,
    });

    await Promise.all([
      workflow.autoAllowBlockedDomain(
        5,
        'a.example.com',
        'https://portal.school/app',
        'script',
        'https://a.example.com/asset.js'
      ),
      workflow.autoAllowBlockedDomain(
        5,
        'b.example.com',
        'https://portal.school/app',
        'image',
        'https://b.example.com/pixel.png'
      ),
    ]);

    assert.deepEqual(updatedHosts, [['a.example.com', 'b.example.com']]);
    assert.equal(fixture.requestLocalWhitelistUpdateCalls, 1);
    assert.equal(fixture.refreshBlockedPathRulesCalls, 1);
  });

  await test('marks duplicate when the API reports an existing rule', async () => {
    const { statuses, workflow } = createWorkflowFixture({
      fetchImpl: () =>
        Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'duplicate' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        ),
    });

    await workflow.autoAllowBlockedDomain(5, 'example.com', null, 'fetch');

    assert.equal(statuses.get('example.com')?.state, 'duplicate');
    assert.equal(statuses.get('example.com')?.message, 'Regla ya existente');
  });

  await test('marks localUpdateError when the local refresh fails after API success', async () => {
    const { statuses, workflow } = createWorkflowFixture({
      fetchImpl: () =>
        Promise.resolve(
          new Response(JSON.stringify({ success: true, status: 'approved' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        ),
      requestLocalWhitelistUpdate: () => Promise.resolve(false),
    });

    await workflow.autoAllowBlockedDomain(5, 'example.com', null, 'fetch');

    assert.equal(statuses.get('example.com')?.state, 'localUpdateError');
    assert.equal(statuses.get('example.com')?.message, 'Regla creada; fallo actualizacion local');
  });

  await test('marks apiError when the API request fails', async () => {
    const { statuses, workflow } = createWorkflowFixture({
      fetchImpl: () =>
        Promise.resolve(
          new Response(JSON.stringify({ success: false, error: 'bad request' }), {
            status: 400,
            headers: { 'Content-Type': 'application/json' },
          })
        ),
    });

    await workflow.autoAllowBlockedDomain(5, 'example.com', null, 'fetch');

    assert.equal(statuses.get('example.com')?.state, 'apiError');
    assert.equal(statuses.get('example.com')?.message, 'bad request');
  });

  await test('retries local updates preserving the prior request type', async () => {
    const updatedHosts: string[][] = [];
    const { statuses, workflow } = createWorkflowFixture({
      requestLocalWhitelistUpdate: (hostnames) => {
        updatedHosts.push(hostnames);
        return Promise.resolve(true);
      },
    });
    statuses.set('example.com', {
      state: 'localUpdateError',
      updatedAt: 111,
      requestType: 'fetch',
    });

    const result = await workflow.retryLocalUpdate(5, 'example.com');

    assert.deepEqual(result, { success: true });
    assert.deepEqual(statuses.get('example.com'), {
      message: 'Actualizacion local completada',
      requestType: 'fetch',
      state: 'autoApproved',
      updatedAt: 1234567890,
    });
    assert.deepEqual(updatedHosts, [['example.com']]);
  });
});
