import { test } from 'node:test';
import assert from 'node:assert/strict';

import TestSupportService from '../src/services/test-support.service.js';

void test('test-support service exports getMachineContextSnapshot and tickScheduleBoundaries', () => {
  assert.strictEqual(typeof TestSupportService.getMachineContextSnapshot, 'function');
  assert.strictEqual(typeof TestSupportService.tickScheduleBoundaries, 'function');
});
