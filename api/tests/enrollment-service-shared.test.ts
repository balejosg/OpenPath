import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  buildWindowsEnrollmentScript,
  hasEnrollmentRole,
} from '../src/services/enrollment-service-shared.js';

void test('enrollment-service-shared exposes role checks and windows script generation', () => {
  assert.equal(hasEnrollmentRole([{ role: 'teacher' }]), true);
  assert.equal(hasEnrollmentRole([{ role: 'student' }]), false);

  const script = buildWindowsEnrollmentScript({
    classroomId: 'classroom-1',
    enrollmentToken: 'token-1',
    firefoxExtensionInstallUrl: 'https://downloads.example/openpath.xpi',
    publicUrl: 'https://example.test',
  });

  assert.match(script, /Install-OpenPath\.ps1/);
  assert.match(script, /classroom-1/);
  assert.match(
    script,
    /\$FirefoxExtensionInstallUrl = 'https:\/\/downloads\.example\/openpath\.xpi'/
  );
  assert.match(script, /-FirefoxExtensionInstallUrl/);
  assert.match(script, /-FirefoxExtensionId/);
  assert.match(script, /-SkipPreflight/);
  assert.match(script, /metadata\.json/);
  assert.doesNotMatch(script, /\$ProgressPreference = 'SilentlyContinue'/);
  assert.match(script, /\$WarningPreference = 'SilentlyContinue'/);
  assert.match(script, /\$InformationPreference = 'SilentlyContinue'/);
  assert.match(script, /Test-OpenPathBootstrapFilesPresent/);
  assert.match(script, /\$bundleApplied = Test-OpenPathBootstrapFilesPresent/);
  assert.match(script, /foreach \(\$file in \$manifest\.files\)/);
  assert.doesNotMatch(script, /OpenPath Enrollment \(Windows\)/);
  assert.doesNotMatch(script, /Installation completed\. Current status:/);
  assert.doesNotMatch(script, /OpenPath\.ps1' status/);
});
