import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';

import { createFixtureClassroom } from './fixtures.js';
import { startTokenDeliveryHarness, type TokenDeliveryHarness } from './token-delivery-harness.js';

let harness: TokenDeliveryHarness;

void describe('Windows bootstrap delivery', { timeout: 30000 }, async () => {
  before(async () => {
    harness = await startTokenDeliveryHarness();
  });

  after(async () => {
    await harness.close();
  });

  await describe('Windows classroom bootstrap endpoints', async () => {
    let enrollmentToken = '';
    let classroomId = '';

    before(async () => {
      classroomId = await createFixtureClassroom({
        name: 'WindowsBootstrapClassroom',
        groupId: 'windows-bootstrap-group',
      });
      enrollmentToken = await harness.getEnrollmentToken(classroomId);
    });

    await test('should return Windows enrollment script with enrollment token auth', async () => {
      const response = await fetch(`${harness.apiUrl}/api/enroll/${classroomId}/windows.ps1`, {
        headers: { Authorization: `Bearer ${enrollmentToken}` },
      });

      assert.strictEqual(response.status, 200);
      assert.match(response.headers.get('content-type') ?? '', /text\/x-powershell/);

      const body = await response.text();
      assert.match(body, /Install-OpenPath\.ps1/);
      assert.match(body, /bootstrap\/manifest/);
      assert.match(body, /bootstrap\/bundle\.zip/);
      assert.match(body, /Expand-Archive/);
      assert.match(body, /-TimingOutputPath/);
      assert.match(body, /-EnrollmentToken/);
      assert.match(body, /-ClassroomId/);
      assert.match(body, /powershell\.exe.*Install-OpenPath\.ps1/s);
      assert.match(body, /\$installExitCode\s*=\s*\$LASTEXITCODE/);
      assert.match(body, /throw "Install-OpenPath\.ps1 exited with code \$installExitCode"/);
      assert.doesNotMatch(body, /\$ProgressPreference = 'SilentlyContinue'/);
      assert.match(body, /\$WarningPreference = 'SilentlyContinue'/);
      assert.match(body, /\$InformationPreference = 'SilentlyContinue'/);
      assert.doesNotMatch(body, /OpenPath Enrollment \(Windows\)/);
      assert.doesNotMatch(body, /Installation completed\. Current status:/);
      assert.doesNotMatch(body, /OpenPath\.ps1' status/);
    });

    await test('should reject Windows enrollment script with mismatched classroom', async () => {
      const otherClassroomId = await createFixtureClassroom({
        name: 'WindowsBootstrapMismatchClassroom',
        groupId: 'windows-bootstrap-mismatch-group',
      });

      const response = await fetch(`${harness.apiUrl}/api/enroll/${otherClassroomId}/windows.ps1`, {
        headers: { Authorization: `Bearer ${enrollmentToken}` },
      });

      assert.strictEqual(response.status, 403);
    });

    await test('should require enrollment token for bootstrap manifest', async () => {
      const response = await fetch(`${harness.apiUrl}/api/agent/windows/bootstrap/manifest`);
      assert.strictEqual(response.status, 401);
    });

    await test('should return bootstrap manifest and files for enrollment token', async () => {
      const manifestResponse = await fetch(
        `${harness.apiUrl}/api/agent/windows/bootstrap/manifest`,
        {
          headers: { Authorization: `Bearer ${enrollmentToken}` },
        }
      );

      assert.strictEqual(manifestResponse.status, 200);
      const manifest = (await manifestResponse.json()) as {
        success: boolean;
        bundle: { path: string; sha256: string; size: number; fileCount: number };
        files: { path: string; sha256: string; size: number }[];
      };

      assert.strictEqual(manifest.success, true);
      assert.equal(manifest.bundle.path, '/api/agent/windows/bootstrap/bundle.zip');
      assert.equal(manifest.bundle.sha256.length, 64);
      assert.ok(manifest.bundle.size > 0);
      assert.ok(manifest.bundle.fileCount >= manifest.files.length);
      assert.ok(manifest.files.some((file) => file.path === 'Install-OpenPath.ps1'));
      assert.ok(manifest.files.some((file) => file.path === 'runtime/browser-policy-spec.json'));
      assert.ok(manifest.files.some((file) => file.path === 'scripts/Pre-Install-Validation.ps1'));
      assert.ok(manifest.files.some((file) => file.path === 'scripts/Enroll-Machine.ps1'));

      const fileResponse = await fetch(
        `${harness.apiUrl}/api/agent/windows/bootstrap/files/Install-OpenPath.ps1`,
        {
          headers: { Authorization: `Bearer ${enrollmentToken}` },
        }
      );

      assert.strictEqual(fileResponse.status, 200);
      assert.match(await fileResponse.text(), /OpenPath DNS para Windows - Instalador/);

      const preflightResponse = await fetch(
        `${harness.apiUrl}/api/agent/windows/bootstrap/files/scripts/Pre-Install-Validation.ps1`,
        {
          headers: { Authorization: `Bearer ${enrollmentToken}` },
        }
      );

      assert.strictEqual(preflightResponse.status, 200);
      assert.match(await preflightResponse.text(), /OpenPath Pre-Installation Validation/);

      const bundleResponse = await fetch(
        `${harness.apiUrl}/api/agent/windows/bootstrap/bundle.zip`,
        {
          headers: { Authorization: `Bearer ${enrollmentToken}` },
        }
      );

      assert.strictEqual(bundleResponse.status, 200);
      assert.match(bundleResponse.headers.get('content-type') ?? '', /application\/zip/);
      const bundleBytes = Buffer.from(await bundleResponse.arrayBuffer());
      assert.equal(bundleBytes.subarray(0, 2).toString('utf8'), 'PK');
      const bundleText = bundleBytes.toString('latin1');
      assert.match(bundleText, /Install-OpenPath\.ps1/);
      assert.match(bundleText, /runtime\/browser-policy-spec\.json/);
      assert.match(bundleText, /scripts\/Enroll-Machine\.ps1/);
    });

    await test('should include Windows Firefox native host runtime files in the bootstrap manifest', async () => {
      const manifestResponse = await fetch(
        `${harness.apiUrl}/api/agent/windows/bootstrap/manifest`,
        {
          headers: { Authorization: `Bearer ${enrollmentToken}` },
        }
      );

      assert.strictEqual(manifestResponse.status, 200);
      const manifest = (await manifestResponse.json()) as {
        success: boolean;
        files: { path: string; sha256: string; size: number }[];
      };

      assert.strictEqual(manifest.success, true);
      assert.ok(manifest.files.some((file) => file.path === 'scripts/OpenPath-NativeHost.ps1'));
      assert.ok(manifest.files.some((file) => file.path === 'scripts/OpenPath-NativeHost.cmd'));
    });
  });
});
