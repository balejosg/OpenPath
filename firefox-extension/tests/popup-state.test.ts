import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  extractTabHostname,
  normalizeBlockedDomains,
  shouldEnableRequestAction,
  statusMeta,
} from '../src/lib/popup-state.js';

void test('popup-state utilities normalize tab hostname and request state', () => {
  assert.equal(extractTabHostname('https://example.test/page'), 'example.test');
  assert.equal(extractTabHostname(undefined), 'Unknown');
  assert.equal(statusMeta({ state: 'pending', updatedAt: 1 }).label, 'Pending');
  assert.equal(
    shouldEnableRequestAction({
      hasDomains: true,
      nativeAvailable: true,
      requestConfigured: true,
    }),
    true
  );
  assert.deepEqual(
    normalizeBlockedDomains({
      domains: {
        'example.test': {
          errors: ['blocked'],
          origin: null,
          timestamp: 1,
        },
      },
    }),
    {
      'example.test': {
        count: 1,
        timestamp: 1,
      },
    }
  );
});
