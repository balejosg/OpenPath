import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { Browser } from 'webextension-polyfill';

import { createNativeMessagingClient } from '../src/lib/native-messaging-client.js';
import type { PersistentNativeTransport } from '../src/lib/persistent-native-transport.js';
import type { RuntimeDependencyProber } from '../src/lib/runtime-dependency-prober.js';
import type { NativeResponse } from '../src/lib/native-response.types.js';
import {
  LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS,
  LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_STALE_TTL_MS,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS,
  LOCAL_RUNTIME_DEPENDENCY_OVERLAY_VERSION,
  LOCAL_RUNTIME_DEPENDENCY_QUEUE_SOURCE,
  LOCAL_RUNTIME_DEPENDENCY_QUEUE_VERSION,
  LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS,
  NATIVE_HOST_CAPABILITIES,
  RUNTIME_DEPENDENCY_ACTIONS,
  createRuntimeDependencyCacheKey,
  createRuntimeDependencyPendingKey,
  isPendingRuntimeDependencyResponse,
  isQueuedRuntimeDependencyResponse,
  isReadyRuntimeDependencyResponse,
  resolveRuntimeDependencyReadiness,
} from '../src/lib/runtime-dependency-protocol.js';

function createBrowserStub(sendResult: unknown): Browser {
  return {
    runtime: {
      connectNative: () =>
        ({
          onDisconnect: {
            addListener: () => undefined,
          },
        }) as never,
      lastError: undefined,
      sendNativeMessage: () => Promise.resolve(sendResult as never),
    },
  } as unknown as Browser;
}

function createRecordingBrowserStub(handler: (message: unknown) => unknown): {
  browser: Browser;
  messages: unknown[];
} {
  const messages: unknown[] = [];
  return {
    browser: {
      runtime: {
        connectNative: () =>
          ({
            onDisconnect: {
              addListener: () => undefined,
            },
          }) as never,
        lastError: undefined,
        sendNativeMessage: (_hostName: string, message: unknown) => {
          messages.push(message);
          return Promise.resolve(handler(message) as never);
        },
      },
    } as unknown as Browser,
    messages,
  };
}

await describe('native messaging client', async () => {
  await test('exports local runtime dependency protocol constants and cache semantics', () => {
    assert.deepEqual(RUNTIME_DEPENDENCY_ACTIONS, {
      allowLocal: 'allow-local-runtime-dependency',
      allowLocalBatch: 'allow-local-runtime-dependency-batch',
      checkLocal: 'check-local-runtime-dependency',
    });
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS, 25);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES, 20);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS, 60 * 1000);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_CACHE_STALE_TTL_MS, 30 * 60 * 1000);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS, 5 * 1000);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES, 100);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_QUEUE_VERSION, 1);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_OVERLAY_VERSION, 1);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_QUEUE_SOURCE, 'firefox-webrequest-local');
    assert.equal(
      createRuntimeDependencyCacheKey({
        anchorHost: 'Allowed.EXAMPLE',
        dependencyHost: 'CDN.EXAMPLE',
      }),
      'allowed.example|cdn.example'
    );
    assert.equal(
      createRuntimeDependencyPendingKey({
        anchorHost: 'Allowed.EXAMPLE',
        dependencyHost: 'CDN.EXAMPLE',
        requestType: 'Script',
      }),
      'allowed.example|cdn.example|script'
    );
    assert.equal(isQueuedRuntimeDependencyResponse({ success: true, queued: true }), true);
    assert.equal(
      isQueuedRuntimeDependencyResponse({ success: true, runtimeDependencyState: 'queued' }),
      true
    );
    assert.equal(
      isReadyRuntimeDependencyResponse({ success: true, runtimeDependencyState: 'ready' }),
      true
    );
    assert.equal(isReadyRuntimeDependencyResponse({ success: true }), false);
    assert.equal(isPendingRuntimeDependencyResponse({ success: true }), true);
    assert.equal(isPendingRuntimeDependencyResponse({ success: true, queued: true }), true);
    assert.equal(
      isPendingRuntimeDependencyResponse({ success: true, runtimeDependencyState: 'pending' }),
      true
    );
    assert.equal(isPendingRuntimeDependencyResponse({ success: false, error: 'denied' }), false);
    assert.equal(
      resolveRuntimeDependencyReadiness({ runtimeDependencyState: 'denied' }),
      'terminal'
    );
    assert.equal(
      resolveRuntimeDependencyReadiness({ runtimeDependencyState: 'error' }),
      'terminal'
    );
    assert.equal(resolveRuntimeDependencyReadiness(undefined), 'terminal');
  });

  await test('maps native check responses to popup-friendly fields', async () => {
    const client = createNativeMessagingClient({
      browserApi: createBrowserStub({
        success: true,
        results: [
          {
            domain: 'example.com',
            in_whitelist: true,
            policy_active: true,
            policy_decision: 'allowed',
            policy_reason: 'whitelist-domain',
            policy_version: 'v1',
            portal_recovery_eligible: true,
            resolves: true,
            resolved_ip: '127.0.0.1',
          },
        ],
      }),
      hostName: 'whitelist_native_host',
    });

    assert.deepEqual(await client.checkDomains(['example.com']), {
      success: true,
      results: [
        {
          domain: 'example.com',
          inWhitelist: true,
          policyActive: true,
          policyDecision: 'allowed',
          policyReason: 'whitelist-domain',
          policyVersion: 'v1',
          portalRecoveryEligible: true,
          resolves: true,
          resolvedIp: '127.0.0.1',
        },
      ],
    });
  });

  await test('reports host availability from ping responses', async () => {
    const client = createNativeMessagingClient({
      browserApi: createBrowserStub({ success: true }),
      hostName: 'whitelist_native_host',
    });

    assert.equal(await client.isAvailable(), true);
  });

  await test('requests captive portal recovery without browser-generated requestId', async () => {
    const { browser, messages } = createRecordingBrowserStub(() => ({
      success: true,
      action: 'recover-captive-portal-navigation',
      triggerHost: 'portal.example',
      tabId: 42,
      requestId: 'native-request-1',
      portalModeActive: true,
    }));
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    const response = await client.recoverCaptivePortalNavigation({
      triggerHost: 'portal.example',
      tabId: 42,
    });

    assert.equal(response.success, true);
    assert.equal(response.requestId, 'native-request-1');
    assert.deepEqual(messages, [
      {
        action: 'recover-captive-portal-navigation',
        operation: 'open',
        triggerHost: 'portal.example',
        tabId: 42,
      },
    ]);
    assert.equal('requestId' in (messages[0] as Record<string, unknown>), false);
  });

  await test('passes captive portal recovery hosts in the native recovery payload', async () => {
    const { browser, messages } = createRecordingBrowserStub(() => ({
      success: true,
      action: 'recover-captive-portal-navigation',
      triggerHost: 'login.wedu.example',
      tabId: 43,
      requestId: 'native-request-2',
      portalModeActive: true,
    }));
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    const response = await client.recoverCaptivePortalNavigation({
      triggerHost: 'login.wedu.example',
      portalRecoveryHosts: ['login.wedu.example', 'assets.wedu.example'],
      tabId: 43,
    });

    assert.equal(response.success, true);
    assert.deepEqual(messages, [
      {
        action: 'recover-captive-portal-navigation',
        operation: 'open',
        triggerHost: 'login.wedu.example',
        portalRecoveryHosts: ['login.wedu.example', 'assets.wedu.example'],
        tabId: 43,
      },
    ]);
    assert.equal('requestId' in (messages[0] as Record<string, unknown>), false);
  });

  await test('batches simultaneous local runtime dependency requests', async () => {
    const { browser, messages } = createRecordingBrowserStub((message) => {
      assert.deepEqual(message, {
        action: 'allow-local-runtime-dependency-batch',
        entries: [
          {
            anchorHost: 'www.reddit.com',
            dependencyHost: 'www.redditstatic.com',
            requestType: 'script',
          },
          {
            anchorHost: 'www.reddit.com',
            dependencyHost: 'emoji.redditmedia.com',
            requestType: 'image',
          },
        ],
      });
      return {
        success: true,
        action: 'allow-local-runtime-dependency-batch',
        results: [
          {
            success: true,
            action: 'allow-local-runtime-dependency',
            anchorHost: 'www.reddit.com',
            dependencyHost: 'www.redditstatic.com',
            requestType: 'script',
          },
          {
            success: true,
            action: 'allow-local-runtime-dependency',
            anchorHost: 'www.reddit.com',
            dependencyHost: 'emoji.redditmedia.com',
            requestType: 'image',
          },
        ],
      };
    });
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    const [scriptResult, imageResult] = await Promise.all([
      client.allowLocalRuntimeDependency({
        anchorHost: 'www.reddit.com',
        dependencyHost: 'www.redditstatic.com',
        requestType: 'script',
      }),
      client.allowLocalRuntimeDependency({
        anchorHost: 'www.reddit.com',
        dependencyHost: 'emoji.redditmedia.com',
        requestType: 'image',
      }),
    ]);

    assert.equal(messages.length, 1);
    assert.equal(scriptResult.success, true);
    assert.equal(imageResult.success, true);
  });

  await test('uses confirmed local runtime dependency cache without IPC', async () => {
    const { browser, messages } = createRecordingBrowserStub(() => ({
      success: true,
      action: 'allow-local-runtime-dependency-batch',
      results: [
        {
          success: true,
          action: 'allow-local-runtime-dependency',
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn.example',
          requestType: 'script',
          runtimeDependencyState: 'ready',
        },
      ],
    }));
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    assert.equal(
      (
        await client.allowLocalRuntimeDependency({
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn.example',
          requestType: 'script',
        })
      ).success,
      true
    );
    assert.deepEqual(
      await client.allowLocalRuntimeDependency({
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'xmlhttprequest',
      }),
      {
        success: true,
        action: 'allow-local-runtime-dependency',
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        runtimeDependencyState: 'ready',
        cached: true,
      }
    );
    assert.equal(messages.length, 1);
  });

  await test('bounds confirmed local runtime dependency cache entries', async () => {
    const { browser, messages } = createRecordingBrowserStub((message) => {
      const entries =
        typeof message === 'object' && message !== null && 'entries' in message
          ? (message as { entries?: unknown }).entries
          : undefined;
      assert.ok(Array.isArray(entries));
      return {
        success: true,
        action: 'allow-local-runtime-dependency-batch',
        results: entries.map((entry) => ({
          ...(entry as object),
          success: true,
          action: 'allow-local-runtime-dependency',
          runtimeDependencyState: 'ready',
        })),
      };
    });
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
      runtimeDependencyCacheMaxEntries: 2,
    });

    for (const dependencyHost of ['cdn-1.example', 'cdn-2.example', 'cdn-3.example']) {
      assert.equal(
        (
          await client.allowLocalRuntimeDependency({
            anchorHost: 'allowed.example',
            dependencyHost,
            requestType: 'script',
          })
        ).success,
        true
      );
    }

    assert.equal(
      (
        await client.allowLocalRuntimeDependency({
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn-1.example',
          requestType: 'image',
        })
      ).success,
      true
    );
    assert.equal(messages.length, 4);
  });

  await test('falls back to single local runtime dependency action when batch is unknown', async () => {
    const { browser, messages } = createRecordingBrowserStub((message) => {
      const action =
        typeof message === 'object' && message !== null && 'action' in message
          ? (message as { action?: unknown }).action
          : undefined;
      if (action === 'allow-local-runtime-dependency-batch') {
        return {
          success: false,
          error: 'Unknown action: allow-local-runtime-dependency-batch',
        };
      }
      return {
        success: true,
        action: 'allow-local-runtime-dependency',
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'script',
      };
    });
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    const result = await client.allowLocalRuntimeDependency({
      anchorHost: 'allowed.example',
      dependencyHost: 'cdn.example',
      requestType: 'script',
    });

    assert.equal(result.success, true);
    assert.deepEqual(messages, [
      {
        action: 'allow-local-runtime-dependency-batch',
        entries: [
          {
            anchorHost: 'allowed.example',
            dependencyHost: 'cdn.example',
            requestType: 'script',
          },
        ],
      },
      {
        action: 'allow-local-runtime-dependency',
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'script',
      },
    ]);
  });

  await test('does not cache failed local runtime dependency responses', async () => {
    const { browser, messages } = createRecordingBrowserStub(() => ({
      success: true,
      action: 'allow-local-runtime-dependency-batch',
      results: [
        {
          success: false,
          action: 'allow-local-runtime-dependency',
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn.example',
          requestType: 'script',
          error: 'OpenPath update task did not write expected domains',
        },
      ],
    }));
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    assert.equal(
      (
        await client.allowLocalRuntimeDependency({
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn.example',
          requestType: 'script',
        })
      ).success,
      false
    );
    assert.equal(
      (
        await client.allowLocalRuntimeDependency({
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn.example',
          requestType: 'script',
        })
      ).success,
      false
    );
    assert.equal(messages.length, 2);
  });

  await test('dedupes queued local runtime dependency responses only briefly', async () => {
    const originalNow = Date.now;
    let now = 1_000_000;
    Date.now = (): number => now;

    try {
      const { browser, messages } = createRecordingBrowserStub(() => ({
        success: true,
        action: 'allow-local-runtime-dependency-batch',
        results: [
          {
            success: true,
            action: 'allow-local-runtime-dependency',
            anchorHost: 'allowed.example',
            dependencyHost: 'cdn.example',
            requestType: 'script',
            queued: true,
          },
        ],
      }));
      const client = createNativeMessagingClient({
        browserApi: browser,
        hostName: 'whitelist_native_host',
      });

      assert.equal(
        (
          await client.allowLocalRuntimeDependency({
            anchorHost: 'allowed.example',
            dependencyHost: 'cdn.example',
            requestType: 'script',
          })
        ).queued,
        true
      );
      assert.deepEqual(
        await client.allowLocalRuntimeDependency({
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn.example',
          requestType: 'script',
        }),
        {
          success: true,
          action: 'allow-local-runtime-dependency',
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn.example',
          requestType: 'script',
          queued: true,
          deduped: true,
        }
      );
      assert.equal(messages.length, 1);

      now += 6_000;
      assert.equal(
        (
          await client.allowLocalRuntimeDependency({
            anchorHost: 'allowed.example',
            dependencyHost: 'cdn.example',
            requestType: 'script',
          })
        ).queued,
        true
      );
      assert.equal(messages.length, 2);
    } finally {
      Date.now = originalNow;
    }
  });

  await test('bounds queued local runtime dependency dedupe entries', async () => {
    const { browser, messages } = createRecordingBrowserStub((message) => {
      const entries =
        typeof message === 'object' && message !== null && 'entries' in message
          ? (message as { entries?: unknown }).entries
          : undefined;
      assert.ok(Array.isArray(entries));
      return {
        success: true,
        action: 'allow-local-runtime-dependency-batch',
        results: entries.map((entry) => ({
          ...(entry as object),
          success: true,
          action: 'allow-local-runtime-dependency',
          queued: true,
        })),
      };
    });
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
      runtimeDependencyCacheMaxEntries: 2,
    });

    for (const dependencyHost of ['queued-1.example', 'queued-2.example', 'queued-3.example']) {
      assert.equal(
        (
          await client.allowLocalRuntimeDependency({
            anchorHost: 'allowed.example',
            dependencyHost,
            requestType: 'script',
          })
        ).queued,
        true
      );
    }

    assert.equal(
      (
        await client.allowLocalRuntimeDependency({
          anchorHost: 'allowed.example',
          dependencyHost: 'queued-1.example',
          requestType: 'script',
        })
      ).queued,
      true
    );
    assert.equal(messages.length, 4);
  });

  await test('shares one in-flight native operation per dependency', async () => {
    let releaseNative!: () => void;
    const nativeGate = new Promise<void>((resolve) => {
      releaseNative = resolve;
    });
    let markFirstRequestSent!: () => void;
    const firstRequestSent = new Promise<void>((resolve) => {
      markFirstRequestSent = resolve;
    });
    const { browser, messages } = createRecordingBrowserStub(() => {
      markFirstRequestSent();
      return nativeGate.then(() => ({
        success: true,
        action: 'allow-local-runtime-dependency-batch',
        results: [
          {
            success: true,
            action: 'allow-local-runtime-dependency',
            anchorHost: 'allowed.example',
            dependencyHost: 'cdn.example',
            requestType: 'script',
            runtimeDependencyState: 'ready',
          },
        ],
      }));
    });
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    const firstRequest = client.allowLocalRuntimeDependency({
      anchorHost: 'allowed.example',
      dependencyHost: 'cdn.example',
      requestType: 'script',
    });
    await firstRequestSent;

    const secondRequest = client.allowLocalRuntimeDependency({
      anchorHost: 'allowed.example',
      dependencyHost: 'cdn.example',
      requestType: 'script',
    });
    releaseNative();

    const [firstResponse, secondResponse] = await Promise.all([firstRequest, secondRequest]);
    assert.equal(messages.length, 1);
    assert.equal(firstResponse.success, true);
    assert.equal(secondResponse.success, true);
    assert.equal(secondResponse.runtimeDependencyState, 'ready');
  });

  await test('keeps legacy acknowledgements out of the confirmed-ready cache', async () => {
    const originalNow = Date.now;
    let now = 2_000_000;
    Date.now = (): number => now;

    try {
      const { browser, messages } = createRecordingBrowserStub(() => ({
        success: true,
        action: 'allow-local-runtime-dependency-batch',
        results: [
          {
            success: true,
            action: 'allow-local-runtime-dependency',
            anchorHost: 'allowed.example',
            dependencyHost: 'cdn.example',
            requestType: 'script',
          },
        ],
      }));
      const client = createNativeMessagingClient({
        browserApi: browser,
        hostName: 'whitelist_native_host',
      });

      const firstResponse = await client.allowLocalRuntimeDependency({
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'script',
      });
      assert.equal(firstResponse.success, true);
      assert.equal(firstResponse.cached, undefined);

      const deduped = await client.allowLocalRuntimeDependency({
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'script',
      });
      assert.equal(deduped.deduped, true);
      assert.equal(deduped.cached, undefined);
      assert.equal(messages.length, 1);

      now += LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS + 1;
      await client.allowLocalRuntimeDependency({
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'script',
      });
      assert.equal(messages.length, 2);
    } finally {
      Date.now = originalNow;
    }
  });

  await test('confirms stale ready cache entries before treating them as ready again', async () => {
    const originalNow = Date.now;
    let now = 3_000_000;
    Date.now = (): number => now;

    try {
      const { browser, messages } = createRecordingBrowserStub((message) => {
        const action =
          typeof message === 'object' && message !== null && 'action' in message
            ? (message as { action?: unknown }).action
            : undefined;
        if (action === 'check-local-runtime-dependency') {
          return {
            success: true,
            action: 'check-local-runtime-dependency',
            ready: true,
            runtimeDependencyState: 'ready',
          };
        }
        return {
          success: true,
          action: 'allow-local-runtime-dependency-batch',
          results: [
            {
              success: true,
              action: 'allow-local-runtime-dependency',
              anchorHost: 'allowed.example',
              dependencyHost: 'cdn.example',
              requestType: 'script',
              runtimeDependencyState: 'ready',
            },
          ],
        };
      });
      const client = createNativeMessagingClient({
        browserApi: browser,
        hostName: 'whitelist_native_host',
      });

      await client.allowLocalRuntimeDependency({
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'script',
      });
      assert.equal(messages.length, 1);

      now += LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS + 1;
      const confirmedResponse = await client.allowLocalRuntimeDependency({
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'xmlhttprequest',
      });
      assert.equal(confirmedResponse.runtimeDependencyState, 'ready');
      assert.equal(confirmedResponse.confirmed, true);
      assert.equal(messages.length, 2);
      assert.deepEqual(messages[1], {
        action: 'check-local-runtime-dependency',
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
      });

      const freshResponse = await client.allowLocalRuntimeDependency({
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'script',
      });
      assert.equal(freshResponse.cached, true);
      assert.equal(messages.length, 2);
    } finally {
      Date.now = originalNow;
    }
  });

  await test('re-runs the allow flow when readiness confirmation fails', async () => {
    const originalNow = Date.now;
    let now = 4_000_000;
    Date.now = (): number => now;

    try {
      const { browser, messages } = createRecordingBrowserStub((message) => {
        const action =
          typeof message === 'object' && message !== null && 'action' in message
            ? (message as { action?: unknown }).action
            : undefined;
        if (action === 'check-local-runtime-dependency') {
          return {
            success: true,
            action: 'check-local-runtime-dependency',
            ready: false,
          };
        }
        return {
          success: true,
          action: 'allow-local-runtime-dependency-batch',
          results: [
            {
              success: true,
              action: 'allow-local-runtime-dependency',
              anchorHost: 'allowed.example',
              dependencyHost: 'cdn.example',
              requestType: 'script',
              runtimeDependencyState: 'ready',
            },
          ],
        };
      });
      const client = createNativeMessagingClient({
        browserApi: browser,
        hostName: 'whitelist_native_host',
      });

      await client.allowLocalRuntimeDependency({
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'script',
      });
      assert.equal(messages.length, 1);

      now += LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS + 1;
      const response = await client.allowLocalRuntimeDependency({
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
        requestType: 'script',
      });
      assert.equal(response.runtimeDependencyState, 'ready');
      assert.equal(response.confirmed, undefined);
      assert.deepEqual(
        messages.map((message) => (message as { action?: unknown }).action),
        [
          'allow-local-runtime-dependency-batch',
          'check-local-runtime-dependency',
          'allow-local-runtime-dependency-batch',
        ]
      );
    } finally {
      Date.now = originalNow;
    }
  });

  await test('warmUp calls connectNative once and resolves without throwing', async () => {
    let connectNativeCalls = 0;
    const browser: Browser = {
      runtime: {
        connectNative: () => {
          connectNativeCalls++;
          return {
            onDisconnect: {
              addListener: () => undefined,
            },
          } as never;
        },
        lastError: undefined,
        sendNativeMessage: () => Promise.resolve(undefined as never),
      },
    } as unknown as Browser;
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    await assert.doesNotReject(async () => {
      await client.warmUp();
    });
    assert.equal(connectNativeCalls, 1);
  });

  await test('warmUp resolves without throwing even when connectNative throws', async () => {
    const browser: Browser = {
      runtime: {
        connectNative: (): never => {
          throw new Error('native host not found');
        },
        lastError: undefined,
        sendNativeMessage: () => Promise.resolve(undefined as never),
      },
    } as unknown as Browser;
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    await assert.doesNotReject(async () => {
      await client.warmUp();
    });
  });

  await test('warmUp does not open a second connection when already connected', async () => {
    let connectNativeCalls = 0;
    const browser: Browser = {
      runtime: {
        connectNative: () => {
          connectNativeCalls++;
          return {
            onDisconnect: {
              addListener: () => undefined,
            },
          } as never;
        },
        lastError: undefined,
        sendNativeMessage: () => Promise.resolve(undefined as never),
      },
    } as unknown as Browser;
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
    });

    await client.warmUp();
    await client.warmUp();
    assert.equal(connectNativeCalls, 1);
  });
});

await describe('native messaging client persistent transport', async () => {
  const input = {
    anchorHost: 'www.reddit.com',
    dependencyHost: 'www.redditstatic.com',
    requestType: 'script',
  };

  function waitForMs(ms: number): Promise<void> {
    return new Promise((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  function createFakeTransportStub(
    options: {
      ready?: boolean;
      connecting?: boolean;
      capabilities?: string[];
      callImpl?: (message: Record<string, unknown>) => Promise<unknown>;
    } = {}
  ): {
    transport: PersistentNativeTransport;
    calls: Record<string, unknown>[];
    markedUnhealthy: string[];
  } {
    const ready = options.ready ?? true;
    const capabilitySet = new Set(
      options.capabilities ?? [
        NATIVE_HOST_CAPABILITIES.enqueue,
        NATIVE_HOST_CAPABILITIES.checkBatch,
        NATIVE_HOST_CAPABILITIES.idEcho,
        NATIVE_HOST_CAPABILITIES.autoReload,
      ]
    );
    const calls: Record<string, unknown>[] = [];
    const markedUnhealthy: string[] = [];
    const connecting = options.connecting ?? false;
    const transport: PersistentNativeTransport = {
      ensureConnected: () => Promise.resolve(ready),
      waitUntilReady: () => Promise.resolve(ready),
      isConnecting: () => connecting,
      isReady: () => ready,
      supports: (capability) => ready && capabilitySet.has(capability),
      getProtocolVersion: () => 2,
      getCapabilities: () => capabilitySet,
      call: (message) => {
        calls.push(message);
        return options.callImpl ? options.callImpl(message) : Promise.resolve({ success: true });
      },
      markUnhealthy: (reason) => {
        markedUnhealthy.push(reason);
      },
      shutdown: () => undefined,
    };
    return { transport, calls, markedUnhealthy };
  }

  function createFakeProberStub(): {
    prober: RuntimeDependencyProber;
    settle: (target: typeof input, response: NativeResponse) => boolean;
    count: () => number;
  } {
    const entries = new Map<string, { onSettled: (response: NativeResponse) => void }>();
    const keyOf = (target: typeof input): string => `${target.anchorHost}|${target.dependencyHost}`;
    const prober: RuntimeDependencyProber = {
      register: (regInput, onSettled) => {
        entries.set(keyOf(regInput), { onSettled });
      },
      has: (regInput) => entries.has(keyOf(regInput)),
      size: () => entries.size,
      stop: () => undefined,
    };
    return {
      prober,
      settle: (target: typeof input, response: NativeResponse): boolean => {
        const entry = entries.get(keyOf(target));
        if (!entry) return false;
        entries.delete(keyOf(target));
        entry.onSettled(response);
        return true;
      },
      count: () => entries.size,
    };
  }

  await test('enqueues over the port and releases the request when the prober observes ready', async () => {
    const { transport, calls } = createFakeTransportStub({
      callImpl: (message) => {
        if (message.action === 'allow-local-runtime-dependency-batch') {
          return Promise.resolve({
            success: true,
            results: [{ success: true, runtimeDependencyState: 'pending', ...input }],
          });
        }
        return Promise.resolve({ success: true });
      },
    });
    const fakeProber = createFakeProberStub();
    const client = createNativeMessagingClient({
      browserApi: createBrowserStub({ success: true }),
      hostName: 'whitelist_native_host',
      persistentTransport: transport,
      runtimeDependencyProber: fakeProber.prober,
    });
    const applied: unknown[] = [];
    client.onRuntimeDependencyApplied((appliedInput) => {
      applied.push(appliedInput);
    });

    const pendingPromise = client.allowLocalRuntimeDependency(input);
    await waitForMs(60);

    assert.equal(calls.length, 1);
    const batchCall = calls[0];
    assert.ok(batchCall, 'expected one persistent batch call');
    assert.equal(batchCall.action, 'allow-local-runtime-dependency-batch');
    assert.equal(batchCall.mode, 'enqueue');
    assert.equal(fakeProber.count(), 1);

    let settled = false;
    void pendingPromise.then(() => {
      settled = true;
    });
    await waitForMs(20);
    assert.equal(settled, false, 'a pending entry must keep the request open');

    assert.equal(
      fakeProber.settle(input, { success: true, runtimeDependencyState: 'ready' }),
      true
    );
    const response = await pendingPromise;
    assert.equal(response.runtimeDependencyState, 'ready');
    assert.deepEqual(applied, [input]);
  });

  await test('falls back to the one-shot path when the port call fails', async () => {
    const { transport, markedUnhealthy } = createFakeTransportStub({
      callImpl: () => Promise.reject(new Error('port broke')),
    });
    const { browser, messages } = createRecordingBrowserStub(() => ({
      success: true,
      results: [{ success: true, runtimeDependencyState: 'queued', ...input }],
    }));
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
      persistentTransport: transport,
    });

    const response = await client.allowLocalRuntimeDependency(input);

    assert.equal(response.success, true);
    assert.equal(messages.length, 1);
    assert.deepEqual(markedUnhealthy, ['dependency enqueue failed']);
  });

  await test('keeps the legacy flow when the host does not announce enqueue', async () => {
    const { transport, calls } = createFakeTransportStub({
      capabilities: [NATIVE_HOST_CAPABILITIES.checkBatch, NATIVE_HOST_CAPABILITIES.idEcho],
    });
    const { browser, messages } = createRecordingBrowserStub(() => ({
      success: true,
      results: [{ success: true, ...input }],
    }));
    const client = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
      persistentTransport: transport,
    });

    assert.equal(client.isPersistentTransportReady(), false);
    const response = await client.allowLocalRuntimeDependency(input);

    assert.equal(response.success, true);
    assert.equal(calls.length, 0);
    assert.equal(messages.length, 1);
    assert.equal(
      (messages[0] as { action?: string }).action,
      'allow-local-runtime-dependency-batch'
    );
  });

  await test('reports the transport as pending while the capability probe is in flight', () => {
    const connecting = createFakeTransportStub({ ready: false, connecting: true });
    const connectingClient = createNativeMessagingClient({
      browserApi: createBrowserStub({ success: true }),
      hostName: 'whitelist_native_host',
      persistentTransport: connecting.transport,
    });
    assert.equal(connectingClient.isPersistentTransportPending(), true);

    const ready = createFakeTransportStub();
    const readyClient = createNativeMessagingClient({
      browserApi: createBrowserStub({ success: true }),
      hostName: 'whitelist_native_host',
      persistentTransport: ready.transport,
    });
    assert.equal(readyClient.isPersistentTransportPending(), true);

    const idle = createFakeTransportStub({ ready: false });
    const idleClient = createNativeMessagingClient({
      browserApi: createBrowserStub({ success: true }),
      hostName: 'whitelist_native_host',
      persistentTransport: idle.transport,
    });
    assert.equal(idleClient.isPersistentTransportPending(), false);
  });

  await test('gates the auto-reload capability on the full enqueue protocol', () => {
    const partial = createFakeTransportStub({
      capabilities: [NATIVE_HOST_CAPABILITIES.enqueue, NATIVE_HOST_CAPABILITIES.idEcho],
    });
    const partialClient = createNativeMessagingClient({
      browserApi: createBrowserStub({ success: true }),
      hostName: 'whitelist_native_host',
      persistentTransport: partial.transport,
    });
    assert.equal(partialClient.isPersistentTransportReady(), true);
    assert.equal(partialClient.isAutoReloadCapable(), false);

    const full = createFakeTransportStub();
    const fullClient = createNativeMessagingClient({
      browserApi: createBrowserStub({ success: true }),
      hostName: 'whitelist_native_host',
      persistentTransport: full.transport,
    });
    assert.equal(fullClient.isAutoReloadCapable(), true);
  });

  await test('sends cheap periodic reads over the port and falls back to one-shot hosts', async () => {
    const { transport, calls } = createFakeTransportStub();
    const client = createNativeMessagingClient({
      browserApi: createBrowserStub({ success: true }),
      hostName: 'whitelist_native_host',
      persistentTransport: transport,
    });
    await client.sendCheapRead({ action: 'get-policy-version' });
    assert.equal(calls.length, 1);
    assert.equal(calls[0]?.action, 'get-policy-version');

    const notReady = createFakeTransportStub({ ready: false });
    const { browser, messages } = createRecordingBrowserStub(() => ({
      success: true,
      version: 'v1',
    }));
    const legacyClient = createNativeMessagingClient({
      browserApi: browser,
      hostName: 'whitelist_native_host',
      persistentTransport: notReady.transport,
    });
    const response = (await legacyClient.sendCheapRead({ action: 'get-policy-version' })) as {
      version?: string;
    };
    assert.equal(response.version, 'v1');
    assert.equal(messages.length, 1);
    assert.equal(notReady.calls.length, 0);
  });

  await test('a second request for the same pending dependency resolves with the same ready state', async () => {
    const { transport } = createFakeTransportStub({
      callImpl: (message) => {
        if (message.action === 'allow-local-runtime-dependency-batch') {
          return Promise.resolve({
            success: true,
            results: [{ success: true, runtimeDependencyState: 'pending', ...input }],
          });
        }
        return Promise.resolve({ success: true });
      },
    });
    const fakeProber = createFakeProberStub();
    const client = createNativeMessagingClient({
      browserApi: createBrowserStub({ success: true }),
      hostName: 'whitelist_native_host',
      persistentTransport: transport,
      runtimeDependencyProber: fakeProber.prober,
    });

    const first = client.allowLocalRuntimeDependency(input);
    await waitForMs(60);
    const second = client.allowLocalRuntimeDependency(input);
    await waitForMs(20);

    assert.equal(fakeProber.count(), 1, 'the prober must keep a single pending entry');
    fakeProber.settle(input, { success: true, runtimeDependencyState: 'ready' });

    const [firstResponse, secondResponse] = await Promise.all([first, second]);
    assert.equal(firstResponse.runtimeDependencyState, 'ready');
    assert.equal(secondResponse.runtimeDependencyState, 'ready');
  });
});
