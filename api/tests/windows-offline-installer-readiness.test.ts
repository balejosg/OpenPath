import assert from 'node:assert/strict';
import { test } from 'node:test';

import { checkWindowsOfflineInstallerReadiness } from '../src/lib/windows-offline-installer-readiness.js';

void test('readiness leaves the capability unconfigured when no offline installer pins exist', () => {
  assert.deepEqual(checkWindowsOfflineInstallerReadiness({ env: {} }), {
    ready: true,
    code: 'NOT_CONFIGURED',
  });
});
