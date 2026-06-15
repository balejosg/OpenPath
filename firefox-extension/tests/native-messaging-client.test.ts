import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { Browser } from 'webextension-polyfill';

import { createNativeMessagingClient } from '../src/lib/native-messaging-client.js';
import {
  LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS,
  LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_MAX_ENTRIES,
  LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS,
  LOCAL_RUNTIME_DEPENDENCY_OVERLAY_VERSION,
  LOCAL_RUNTIME_DEPENDENCY_QUEUE_SOURCE,
  LOCAL_RUNTIME_DEPENDENCY_QUEUE_VERSION,
  LOCAL_RUNTIME_DEPENDENCY_QUEUED_DEDUPE_TTL_MS,
  RUNTIME_DEPENDENCY_ACTIONS,
  createRuntimeDependencyCacheKey,
  createRuntimeDependencyPendingKey,
  isQueuedRuntimeDependencyResponse,
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
    });
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS, 150);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_BATCH_MAX_ENTRIES, 20);
    assert.equal(LOCAL_RUNTIME_DEPENDENCY_CACHE_TTL_MS, 30 * 60 * 1000);
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
