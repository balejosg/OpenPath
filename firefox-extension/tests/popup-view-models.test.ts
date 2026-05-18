import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  buildBlockedDomainListItems,
  buildRequestStatusPresentation,
} from '../src/lib/popup-view-models.js';

await describe('popup view models', async () => {
  await test('builds blocked domain items with retry metadata when applicable', () => {
    const items = buildBlockedDomainListItems({
      blockedDomainsData: {
        'b.example.com': {
          count: 1,
          timestamp: 2,
        },
        'a.example.com': {
          errors: ['NS_ERROR_UNKNOWN_HOST', 'NS_ERROR_NET_TIMEOUT'],
          timestamp: 1,
        },
      },
      currentTabId: 4,
      domainStatusesData: {
        'a.example.com': {
          message: 'Token is not valid for this hostname',
          state: 'localUpdateError',
          updatedAt: 10,
        },
        'b.example.com': {
          state: 'pending',
          updatedAt: 20,
        },
      },
    });

    assert.deepEqual(items, [
      {
        attempts: 2,
        hostname: 'a.example.com',
        retryHostname: 'a.example.com',
        statusClassName: 'status-update-error',
        statusLabel: 'Local update error',
        statusTitle: 'Token is not valid for this hostname',
      },
      {
        attempts: 1,
        hostname: 'b.example.com',
        statusClassName: 'status-pending',
        statusLabel: 'Pending',
        statusTitle: 'Pending',
      },
    ]);
  });

  await test('builds request status class mutations for popup notices', () => {
    assert.deepEqual(buildRequestStatusPresentation('success'), {
      classesToAdd: ['success'],
      classesToRemove: ['hidden', 'success', 'error', 'pending'],
    });
  });
});
