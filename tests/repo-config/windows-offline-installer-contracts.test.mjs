import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readText } from './support.mjs';

function extractFunctionBody(text, functionName) {
  const pattern = new RegExp(`function ${functionName}\\s*\\{[\\s\\S]*?\\n\\}`, 'm');
  const match = text.match(pattern);
  assert.ok(match, `Expected function ${functionName} to exist`);
  return match[0];
}

test('installer exposes a strict -OfflineConfigPath entrypoint wired to the offline module', () => {
  const installer = readText('windows/Install-OpenPath.ps1');

  assert.match(
    installer,
    /\[string\]\$OfflineConfigPath = ""/,
    'Install-OpenPath.ps1 must accept -OfflineConfigPath for self-contained installs'
  );
  assert.match(
    installer,
    /Installer\.Offline\.ps1/,
    'Install-OpenPath.ps1 must dot-source the offline helper module'
  );
  assert.match(
    installer,
    /Read-OpenPathOfflineConfig/,
    'Install-OpenPath.ps1 must validate the offline configuration before mutating the system'
  );
});

test('offline helper module implements config validation, payload verification, and local acrylic install', () => {
  const offlineModule = readText('windows/lib/install/Installer.Offline.ps1');

  for (const functionName of [
    'Read-OpenPathOfflineConfig',
    'Assert-OpenPathOfflinePayloadManifest',
    'Install-AcrylicDNSFromLocalSource',
    'Get-OpenPathPendingEnrollmentStatePath',
    'Save-OpenPathPendingEnrollmentState',
    'Read-OpenPathPendingEnrollmentState',
    'Clear-OpenPathPendingEnrollmentState',
    'Test-OpenPathPendingEnrollmentExpired',
    'Invoke-OpenPathPendingEnrollmentRetry',
  ]) {
    assert.match(
      offlineModule,
      new RegExp(`function ${functionName}\\b`),
      `Installer.Offline.ps1 should define ${functionName}`
    );
  }

  assert.match(
    offlineModule,
    /OPWSI|schemaVersion/,
    'offline config validation should be tied to the versioned offline schema'
  );

  const localAcrylic = extractFunctionBody(offlineModule, 'Install-AcrylicDNSFromLocalSource');
  assert.doesNotMatch(
    localAcrylic,
    /https?:\/\//i,
    'offline Acrylic install must never download from a URL'
  );
  assert.doesNotMatch(
    localAcrylic,
    /choco/i,
    'offline Acrylic install must never fall back to Chocolatey'
  );
  assert.match(
    localAcrylic,
    /Assert-AcrylicDownloadHash/,
    'offline Acrylic install must verify the ZIP hash before extracting'
  );
});

test('offline payload manifest validation fails closed on missing or mismatched payloads', () => {
  const offlineModule = readText('windows/lib/install/Installer.Offline.ps1');
  const manifestCheck = extractFunctionBody(offlineModule, 'Assert-OpenPathOfflinePayloadManifest');

  assert.match(manifestCheck, /Get-FileHash/, 'manifest validation must hash staged payloads');
  assert.match(
    offlineModule,
    /Assert-OpenPathOfflinePayloadManifest/,
    'manifest validation entrypoint should exist for the installer pipeline'
  );
});

test('pending enrollment state is DPAPI-protected with restrictive ACLs and never logged', () => {
  const offlineModule = readText('windows/lib/install/Installer.Offline.ps1');

  const savePending = extractFunctionBody(offlineModule, 'Save-OpenPathPendingEnrollmentState');
  assert.match(
    savePending,
    /DataProtectionScope::?LocalMachine|\[System\.Security\.Cryptography\.DataProtectionScope\]::LocalMachine/,
    'pending enrollment token must use machine-scope DPAPI so SYSTEM can retry it'
  );
  assert.match(
    savePending,
    /Set-OpenPathCapabilityStorageAcl/,
    'pending enrollment state must apply the restrictive capability storage ACL'
  );
  assert.match(
    offlineModule,
    /pending-enrollment\.json\.dpapi/,
    'pending enrollment state must be stored as a .dpapi blob'
  );

  const retry = extractFunctionBody(offlineModule, 'Invoke-OpenPathPendingEnrollmentRetry');
  assert.match(
    retry,
    /Clear-OpenPathPendingEnrollmentState/,
    'successful pending-enrollment retry must clear the pending state file'
  );
  assert.match(
    retry,
    /EXPIRED/,
    'expired pending-enrollment tokens must transition the state to EXPIRED and drop the DPAPI blob'
  );
});

test('startup update cycle consumes pending enrollment without exposing the bearer token', () => {
  const updateRuntime = readText('windows/lib/Update.Runtime.psm1');

  assert.match(
    updateRuntime,
    /Invoke-OpenPathPendingEnrollmentRetry/,
    'update cycle must attempt pending-enrollment retry on startup/watchdog runs'
  );
  assert.match(
    updateRuntime,
    /Installer\.Offline\.ps1/,
    'update cycle should dot-source the installed offline helper module'
  );
});

test('offline staging makes browser artifacts mandatory instead of warning-only', () => {
  const staging = readText('windows/lib/install/Installer.Staging.ps1');

  assert.match(
    staging,
    /RequireCompleteStaging/,
    'staging runtime copy must support a mandatory-artifact mode for offline installs'
  );
});

test('uninstall removes pending enrollment state with the data directory', () => {
  const uninstall = readText('windows/Uninstall-OpenPath.ps1');

  assert.match(
    uninstall,
    /pending-enrollment/,
    'uninstall must explicitly remove pending enrollment state files'
  );
});

test('offline installer Pester suite exists and is registered in the aggregate run', () => {
  const aggregateSuite = readText('windows/tests/Windows.Tests.ps1');
  assert.match(
    aggregateSuite,
    /"Windows\.OfflineInstaller\.Tests\.ps1"/,
    'aggregate Windows suite should include the offline installer Pester coverage'
  );

  const pesterSuite = readText('windows/tests/Windows.OfflineInstaller.Tests.ps1');
  for (const marker of [
    'Read-OpenPathOfflineConfig',
    'Assert-OpenPathOfflinePayloadManifest',
    'Install-AcrylicDNSFromLocalSource',
    'Save-OpenPathPendingEnrollmentState',
    'Invoke-OpenPathPendingEnrollmentRetry',
    'Chocolatey',
    'EXPIRED',
  ]) {
    assert.match(
      pesterSuite,
      new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
      `Pester suite should cover ${marker}`
    );
  }
});
