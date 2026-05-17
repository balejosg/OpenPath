import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  buildVerifyResultViewModels,
  getBlockedHostnames,
  resolveNativeAvailabilityState,
  verifyPopupDomains,
} from '../src/lib/popup-native-actions.js';

await describe('popup native actions', async () => {
  await test('resolves native availability state for available and unavailable responses', () => {
    assert.deepEqual(
      resolveNativeAvailabilityState({
        available: true,
        version: '1.2.3',
      }),
      {
        available: true,
        className: 'status-indicator available',
        label: 'Host nativo v1.2.3',
      }
    );

    assert.deepEqual(resolveNativeAvailabilityState({ success: false }), {
      available: false,
      className: 'status-indicator unavailable',
      label: 'Host nativo no disponible',
    });
  });

  await test('sorts blocked hostnames before verification', () => {
    assert.deepEqual(
      getBlockedHostnames({
        'z.example.com': { count: 1, timestamp: 2 },
        'a.example.com': { count: 2, timestamp: 1 },
      }),
      ['a.example.com', 'z.example.com']
    );
  });

  await test('verifies popup domains through background messaging', async () => {
    let sentMessage: unknown;

    const result = await verifyPopupDomains({
      blockedDomainsData: {
        'b.example.com': { count: 1, timestamp: 2 },
        'a.example.com': { count: 2, timestamp: 1 },
      },
      isNativeAvailable: true,
      sendMessage: (message) => {
        sentMessage = message;
        return Promise.resolve({
          success: true,
          results: [{ domain: 'a.example.com', inWhitelist: true }],
        });
      },
    });

    assert.deepEqual(sentMessage, {
      action: 'checkWithNative',
      domains: ['a.example.com', 'b.example.com'],
    });
    assert.deepEqual(result, {
      ok: true,
      results: [{ domain: 'a.example.com', inWhitelist: true }],
    });
  });

  await test('returns a skipped result when no hostnames or native host are available', async () => {
    assert.deepEqual(
      await verifyPopupDomains({
        blockedDomainsData: {},
        isNativeAvailable: true,
        sendMessage: () => Promise.resolve({}),
      }),
      { ok: false, skipped: true }
    );

    assert.deepEqual(
      await verifyPopupDomains({
        blockedDomainsData: {
          'a.example.com': { count: 1, timestamp: 1 },
        },
        isNativeAvailable: false,
        sendMessage: () => Promise.resolve({}),
      }),
      { ok: false, skipped: true }
    );
  });

  await test('maps verify results to popup render view models', () => {
    assert.deepEqual(
      buildVerifyResultViewModels([
        {
          domain: 'allowed.example.com',
          inWhitelist: true,
          resolvedIp: '127.0.0.1',
        },
        {
          domain: 'blocked.example.com',
          in_whitelist: false,
          resolved_ip: '192.168.1.2',
        },
      ]),
      [
        {
          domain: 'allowed.example.com',
          resolvedIp: '127.0.0.1',
          statusClass: 'status-allowed',
          statusText: 'ALLOWED',
        },
        {
          domain: 'blocked.example.com',
          resolvedIp: '192.168.1.2',
          statusClass: 'status-blocked',
          statusText: 'BLOCKED',
        },
      ]
    );
  });
});
