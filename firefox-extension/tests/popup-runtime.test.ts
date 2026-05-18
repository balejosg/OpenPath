import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { Tabs } from 'webextension-polyfill';

import {
  buildBlockedDomainsClipboardText,
  checkPopupNativeAvailability,
  clearPopupDomainsForTab,
  loadPopupDomainSnapshot,
  loadPopupDomainStatuses,
  resolveActivePopupTab,
} from '../src/lib/popup-runtime.js';

await describe('popup runtime', async () => {
  await test('loads a blocked-domain snapshot and nested statuses', async () => {
    const messages: unknown[] = [];

    const snapshot = await loadPopupDomainSnapshot(5, (message) => {
      messages.push(message);
      if ((message as { action?: string }).action === 'getBlockedDomains') {
        return Promise.resolve({
          domains: {
            'cdn.example.com': {
              errors: ['NS_ERROR_UNKNOWN_HOST'],
              origin: 'portal.school',
              timestamp: 1,
            },
          },
        });
      }

      return Promise.resolve({
        statuses: {
          'cdn.example.com': {
            state: 'pending',
            updatedAt: 2,
          },
        },
      });
    });

    assert.deepEqual(messages, [
      { action: 'getBlockedDomains', tabId: 5 },
      { action: 'getDomainStatuses', tabId: 5 },
    ]);
    assert.deepEqual(snapshot, {
      blockedDomainsData: {
        'cdn.example.com': {
          count: 1,
          origin: 'portal.school',
          timestamp: 1,
        },
      },
      domainStatusesData: {
        'cdn.example.com': {
          state: 'pending',
          updatedAt: 2,
        },
      },
    });
  });

  await test('returns empty statuses when loading fails', async () => {
    const statuses = await loadPopupDomainStatuses(5, () => Promise.reject(new Error('nope')));
    assert.deepEqual(statuses, {});
  });

  await test('builds clipboard text in hostname order', () => {
    assert.equal(
      buildBlockedDomainsClipboardText({
        'b.example.com': { count: 1, timestamp: 2 },
        'a.example.com': { count: 2, timestamp: 1 },
      }),
      'a.example.com\nb.example.com'
    );
  });

  await test('clears a popup tab through the background contract', async () => {
    let capturedMessage: unknown;

    await clearPopupDomainsForTab(7, (message) => {
      capturedMessage = message;
      return Promise.resolve({});
    });

    assert.deepEqual(capturedMessage, {
      action: 'clearBlockedDomains',
      tabId: 7,
    });
  });

  await test('checks native availability through the shared state helper', async () => {
    const state = await checkPopupNativeAvailability(() =>
      Promise.resolve({
        available: true,
        version: '1.2.3',
      })
    );

    assert.deepEqual(state, {
      available: true,
      className: 'status-indicator available',
      label: 'Native host v1.2.3',
    });
  });

  await test('resolves the active popup tab state', () => {
    assert.deepEqual(resolveActivePopupTab([]), {
      errorText: 'No active tab',
    });

    const tabs = [{ id: 9, url: 'https://portal.school/home' }] as Tabs.Tab[];
    assert.deepEqual(resolveActivePopupTab(tabs), {
      currentTabHostname: 'portal.school',
      currentTabId: 9,
    });
  });
});
