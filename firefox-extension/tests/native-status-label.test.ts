import assert from 'node:assert';
import { describe, test } from 'node:test';

import { formatNativeHostStatusLabel } from '../src/lib/native-status-label.js';

void describe('native host status label', () => {
  void test('does not render an unknown version placeholder for available hosts', () => {
    assert.equal(formatNativeHostStatusLabel({ available: true }), 'Native host available');
    assert.equal(
      formatNativeHostStatusLabel({ available: true, version: '1.2.3' }),
      'Native host v1.2.3'
    );
    assert.equal(formatNativeHostStatusLabel({ available: false }), 'Native host unavailable');
  });
});
