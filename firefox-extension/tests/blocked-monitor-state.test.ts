import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createBlockedMonitorState } from '../src/lib/blocked-monitor-state.js';

void test('blocked-monitor-state stores blocked domains and serializes them by tab', () => {
  const badgeCalls: { text?: string; color?: string }[] = [];
  const state = createBlockedMonitorState(
    {
      setBadgeBackgroundColor: ({ color }) => {
        badgeCalls.push({ color });
      },
      setBadgeText: ({ text }) => {
        badgeCalls.push({ text });
      },
    },
    {
      extractHostname: (url) => new URL(url).hostname,
      now: () => 123,
    }
  );

  state.addBlockedDomain(7, 'example.test', 'blocked', 'https://origin.test/page');

  assert.deepEqual(state.getBlockedDomainsForTab(7), {
    'example.test': {
      errors: ['blocked'],
      origin: 'origin.test',
      timestamp: 123,
    },
  });
  assert.equal(badgeCalls.length > 0, true);
});

void test('blocked-monitor-state stores detected status as a localization key', () => {
  const state = createBlockedMonitorState(
    {
      setBadgeBackgroundColor: () => undefined,
      setBadgeText: () => undefined,
    },
    {
      extractHostname: (url) => new URL(url).hostname,
      now: () => 123,
    }
  );

  state.addBlockedDomain(7, 'example.test', 'blocked');

  assert.deepEqual(state.getDomainStatusesForTab(7)['example.test'], {
    hostname: 'example.test',
    state: 'detected',
    updatedAt: 123,
    messageKey: 'popupStatusDetected',
  });
});
