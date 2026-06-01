import assert from 'node:assert/strict';
import { test } from 'node:test';

import * as enrollmentBootstrapService from '../src/services/enrollment-bootstrap.service.js';
import { buildWindowsEnrollmentScript } from '../src/services/enrollment-service-shared.js';

void test('enrollment-bootstrap service exports expected bootstrap entrypoints', () => {
  assert.equal(typeof enrollmentBootstrapService.buildLinuxEnrollmentBootstrap, 'function');
  assert.equal(typeof enrollmentBootstrapService.buildWindowsEnrollmentBootstrap, 'function');
});

void test('windows enrollment script passes configured captive portal domains to installer', () => {
  const script = buildWindowsEnrollmentScript({
    publicUrl: 'https://api.example.test',
    classroomId: 'room_123',
    enrollmentToken: 'token-secret',
    captivePortalDomains: ['login.example.test', 'wifi.example.test'],
  });

  assert.match(
    script,
    /\$CaptivePortalDomains = @\("login\.example\.test", "wifi\.example\.test"\)/
  );
  assert.match(script, /\$InstallArgs \+= @\('-CaptivePortalDomains', \$CaptivePortalDomains\)/);
});
