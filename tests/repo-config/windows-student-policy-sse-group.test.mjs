import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  selectWindowsStudentPolicySseGroup,
  validateWindowsStudentPolicySseGroup,
} from '../../scripts/select-windows-student-policy-sse-group.mjs';

test('Windows student-policy SSE selector maps narrow request lifecycle changes', () => {
  assert.equal(
    selectWindowsStudentPolicySseGroup([
      'api/src/services/request-command-requests.service.ts',
      'firefox-extension/src/lib/popup-request-actions.ts',
    ]),
    'request-lifecycle'
  );
});

test('Windows student-policy SSE selector maps narrow path-blocking changes', () => {
  assert.equal(
    selectWindowsStudentPolicySseGroup([
      'firefox-extension/src/lib/path-blocking.ts',
      'firefox-extension/src/lib/background-path-rules.ts',
    ]),
    'path-blocking'
  );
});

test('Windows student-policy SSE selector maps narrow exemption and schedule changes', () => {
  assert.equal(
    selectWindowsStudentPolicySseGroup([
      'api/src/services/classroom-exemption-command.service.ts',
      'api/src/services/schedule-command-update.service.ts',
    ]),
    'exemptions'
  );
});

test('Windows student-policy SSE selector falls back to full for mixed or broad changes', () => {
  assert.equal(
    selectWindowsStudentPolicySseGroup([
      'firefox-extension/src/lib/path-blocking.ts',
      'api/src/services/request-command-requests.service.ts',
    ]),
    'full'
  );
  assert.equal(selectWindowsStudentPolicySseGroup(['windows/install.ps1']), 'full');
  assert.equal(selectWindowsStudentPolicySseGroup(['package-lock.json']), 'full');
  assert.equal(
    selectWindowsStudentPolicySseGroup(['tests/selenium/student-policy-harness.ts']),
    'full'
  );
  assert.equal(
    selectWindowsStudentPolicySseGroup(['api/src/services/groups-rules.service.ts']),
    'full'
  );
});

test('Windows student-policy SSE selector honors explicit valid overrides', () => {
  assert.equal(
    selectWindowsStudentPolicySseGroup(['windows/install.ps1'], { override: 'path-blocking' }),
    'path-blocking'
  );
  assert.equal(
    selectWindowsStudentPolicySseGroup(['firefox-extension/src/lib/background-listeners.ts'], {
      override: 'full',
    }),
    'full'
  );
});

test('Windows student-policy SSE selector rejects invalid explicit overrides', () => {
  assert.throws(
    () => validateWindowsStudentPolicySseGroup('fast'),
    /student_policy_sse_group must be one of/
  );
});
