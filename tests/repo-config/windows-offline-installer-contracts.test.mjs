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

test('offline installer build helpers enforce trailer format, payload inventory, and NSIS pin', () => {
  const placeholderGenerator = readText(
    'windows/offline-installer/scripts/generate-trailer-placeholder.mjs'
  );
  for (const marker of ['OPWSI1', 'OPWS', '65536', '52', '16']) {
    assert.ok(
      placeholderGenerator.includes(marker),
      `trailer placeholder generator should encode ${marker}`
    );
  }

  const manifestBuilder = readText('windows/offline-installer/scripts/build-payload-manifest.mjs');
  for (const requiredPayload of [
    'payloads/acrylic/Acrylic-Portable.zip',
    'payloads/firefox-esr/Firefox-Setup-esr.exe',
    'openpath-firefox-extension.xpi',
    'metadata.json',
    'chromium-managed',
    'VERSION',
  ]) {
    assert.ok(
      manifestBuilder.includes(requiredPayload),
      `payload manifest builder should require ${requiredPayload}`
    );
  }
  assert.match(
    manifestBuilder,
    /process\.exit\(1\)|throw new Error/,
    'payload manifest builder should fail closed on missing payloads'
  );

  const nsisHashes = JSON.parse(readText('windows/offline-installer/nsis-hashes.json'));
  assert.equal(nsisHashes.version, '3.10');
  assert.ok(
    Array.isArray(nsisHashes.acceptedMakensisSha256) &&
      nsisHashes.acceptedMakensisSha256.length > 0,
    'nsis-hashes.json should list accepted makensis.exe SHA-256 digests'
  );

  const verifyScript = readText('windows/offline-installer/scripts/verify-nsis.ps1');
  assert.match(verifyScript, /Get-FileHash/);
  assert.match(verifyScript, /exit 1/, 'verify-nsis.ps1 must exit non-zero on hash mismatch');

  const appendScript = readText('windows/offline-installer/scripts/append-trailer-placeholder.mjs');
  assert.match(
    appendScript,
    /trailer-placeholder\.bin/,
    'append step should concatenate the committed placeholder onto the compiled exe'
  );
  assert.match(appendScript, /OpenPath-Windows-Setup-Template\.exe/);

  const nsiSource = readText('windows/offline-installer/OpenPath-Windows-Setup.nsi');
  for (const marker of ['Install-OpenPath.ps1', '-OfflineConfigPath', 'payload-manifest.json']) {
    assert.ok(nsiSource.includes(marker), `NSIS source should reference ${marker}`);
  }
  assert.match(
    nsiSource,
    /File \/r \/x [\s\S]*offline-installer\\build/,
    'NSIS must exclude its build inputs and outputs from the packaged runtime'
  );
  assert.match(
    nsiSource,
    /SetOutPath "\$INSTDIR\\runtime"[\s\S]*File \/r "\$\{REPO_ROOT\}\\runtime\\\*\.\*"/,
    'runtime assets must be extracted beneath the runtime package directory'
  );
  assert.match(
    nsiSource,
    /SetOutPath "\$INSTDIR\\firefox-release"[\s\S]*firefox-release\\\*\.\*/,
    'signed Firefox artifacts must retain their package directory'
  );
  assert.match(
    nsiSource,
    /SetOutPath "\$INSTDIR\\chromium-managed"[\s\S]*chromium-managed\\\*\.\*/,
    'Chromium metadata must retain its package directory'
  );
  const manifestBuilderSource = readText(
    'windows/offline-installer/scripts/build-payload-manifest.mjs'
  );
  assert.match(
    manifestBuilderSource,
    /toManifestEntry\(filePath, treeRoot, `repo:\$\{tree\}`, packagePrefix\)/,
    'payload manifest paths must match the NSIS extraction roots'
  );
  assert.match(
    manifestBuilderSource,
    /offline-installer', 'build'/,
    'payload manifest must exclude the NSIS build directory'
  );
  const staging = readText('windows/lib/install/Installer.Staging.ps1');
  assert.match(staging, /Join-Path \$ScriptDir 'firefox-release'/);
  assert.match(staging, /Join-Path \$ScriptDir 'chromium-managed'/);
  assert.doesNotMatch(nsiSource, /classroompath/i, 'NSIS template must stay wrapper-agnostic');
});

test('Windows offline installer canary is read-only unless installation is explicit', () => {
  const canary = readText('tests/e2e/ci/run-windows-offline-installer-canary.ps1');

  for (const marker of [
    'Read-Trailer.ps1',
    'ExpectedClassroomId',
    'Get-FileHash',
    'trailer-validation-failed',
    '[switch]$Install',
    'OfflineConfigPath',
  ]) {
    assert.ok(canary.includes(marker), `Windows canary should include ${marker}`);
  }
  assert.match(canary, /if \(\$Install\)/, 'installation must be opt-in');
  assert.match(canary, /status = 'ok'/, 'canary should emit safe success JSON');
  assert.match(canary, /status = 'failed'/, 'canary should emit safe failure JSON');
  assert.doesNotMatch(canary, /EnrollmentToken|accessToken|Bearer/i);
});

test('NSIS extracts offline manifest and payloads under the installer root', () => {
  const nsiSource = readText('windows/offline-installer/OpenPath-Windows-Setup.nsi');
  const rootOutput = nsiSource.indexOf('SetOutPath "$INSTDIR"');
  const runtimeOutput = nsiSource.indexOf('SetOutPath "$INSTDIR\\runtime"');
  const payloadOutput = nsiSource.indexOf('SetOutPath "$INSTDIR\\payloads\\acrylic"');
  const manifestFile = nsiSource.indexOf('File /oname=payload-manifest.json');
  const versionFile = nsiSource.indexOf('File /oname=VERSION');
  const acrylicFile = nsiSource.indexOf('File /oname=Acrylic-Portable.zip');

  assert.ok(rootOutput >= 0, 'NSIS must establish the installer root output path');
  assert.ok(runtimeOutput > rootOutput, 'NSIS must switch to the runtime output path explicitly');
  assert.ok(
    payloadOutput > runtimeOutput,
    'NSIS must switch to the payload output path explicitly'
  );
  assert.ok(
    manifestFile > rootOutput && manifestFile < runtimeOutput,
    'payload-manifest.json must be copied to the installer root'
  );
  assert.ok(
    versionFile > rootOutput && versionFile < runtimeOutput,
    'VERSION must be copied to the installer root'
  );
  assert.ok(acrylicFile > payloadOutput, 'Acrylic must be copied below the payloads root');
  assert.match(
    nsiSource,
    /SetOutPath "\$INSTDIR\\payloads\\firefox-esr"[\s\S]*File \/oname=Firefox-Setup-esr\.exe/,
    'Firefox ESR must be copied below the payloads root'
  );
});

test('Windows release evidence executes the personalized NSIS executable and its offline retry path', () => {
  const executableLane = readText('tests/e2e/ci/run-windows-offline-installer-exe.ps1');
  for (const marker of [
    'Start-Process',
    "-ArgumentList @('/S')",
    'Read-Trailer.ps1',
    'pending-enrollment.json.dpapi',
    'Assert-EqualValue',
    'Invoke-OpenPathPendingEnrollmentRetry',
    'HttpListener',
    'netsh http add urlacl',
    'netsh http delete urlacl',
    '$urlAclAdded = $false',
    'https://localhost:',
    'pendingStateCleared = $true',
  ]) {
    assert.ok(executableLane.includes(marker), `Windows executable lane should include ${marker}`);
  }
  assert.match(
    executableLane,
    /Write-SafeEvidence[\s\S]*payloadManifestValidated = \$true/,
    'Windows executable evidence must report manifest validation without writing credentials'
  );
  assert.doesNotMatch(
    executableLane,
    /Write-SafeEvidence[\s\S]*(?:enrollmentToken|Bearer|accessToken)/i,
    'Windows executable evidence must not contain auth material'
  );

  const workflow = readText('.github/workflows/release-scripts.yml');
  const nsiSource = readText('windows/offline-installer/OpenPath-Windows-Setup.nsi');
  for (const marker of [
    'create-personalized-test-installer.mjs',
    'run-windows-offline-installer-exe.ps1',
    'Execute the personalized NSIS executable E2E',
    'Upload personalized NSIS E2E evidence',
  ]) {
    assert.ok(workflow.includes(marker), `release workflow should include ${marker}`);
  }

  const manifestBuild = workflow.indexOf('build-payload-manifest.mjs');
  const nsisCompile = workflow.indexOf('name: Compile NSIS template');
  const trailerAppend = workflow.indexOf('append-trailer-placeholder.mjs');
  assert.ok(manifestBuild >= 0, 'release workflow must build the manifest');
  assert.ok(nsisCompile >= 0, 'release workflow must compile NSIS');
  assert.ok(trailerAppend >= 0, 'release workflow must append the trailer');
  assert.ok(
    manifestBuild < nsisCompile && nsisCompile < trailerAppend,
    'NSIS must receive the payload manifest before compilation and append the trailer afterward'
  );
  assert.match(
    workflow,
    /script-file:\s*windows\/offline-installer\/OpenPath-Windows-Setup\.nsi/,
    'the NSIS action must compile the repository offline-installer script explicitly'
  );

  assert.match(
    nsiSource,
    /!define BUILD_DIR "\$\{REPO_ROOT\}\\windows\\offline-installer\\build"/,
    'NSIS build output must stay inside the repository build directory'
  );
  assert.match(
    nsiSource,
    /File "\/oname=scripts\\Read-Trailer\.ps1" "\$\{REPO_ROOT\}\\windows\\offline-installer\\scripts\\Read-Trailer\.ps1"/,
    'NSIS must load its trailer reader from an explicit repository path'
  );
});

test('NSIS stages trailer-reader dependencies before validating the trailer', () => {
  const nsiSource = readText('windows/offline-installer/OpenPath-Windows-Setup.nsi');
  const readTrailerSection = nsiSource.slice(
    nsiSource.indexOf('Section "ReadTrailer"'),
    nsiSource.indexOf('SectionEnd', nsiSource.indexOf('Section "ReadTrailer"'))
  );

  assert.match(
    readTrailerSection,
    /SetOutPath "\$INSTDIR\\lib\\internal"[\s\S]*File "\/oname=CapabilityStorage\.ps1" "\$\{REPO_ROOT\}\\windows\\lib\\internal\\CapabilityStorage\.ps1"/,
    'trailer validation must have its ACL dependency before the first NSIS section runs'
  );
  assert.match(
    readTrailerSection,
    /SetOutPath "\$INSTDIR\\lib\\install"[\s\S]*File "\/oname=Installer\.Offline\.ps1" "\$\{REPO_ROOT\}\\windows\\lib\\install\\Installer\.Offline\.ps1"/,
    'trailer validation must have its offline config dependency before the first NSIS section runs'
  );
  const trailerReader = readText('windows/offline-installer/scripts/Read-Trailer.ps1');
  assert.match(
    trailerReader,
    /offlineModuleCandidates[\s\S]*Join-Path \$PSScriptRoot '\.\.\\lib\\install\\Installer\.Offline\.ps1'/,
    'trailer reader must resolve dependencies from the extracted installer root'
  );
});

test('standalone Docker provisions the pinned template before exposing the API', () => {
  const compose = readText('api/docker-compose.yml');
  const runtimeTemplateDir = '/app/var/windows-offline-installer/templates';
  const runtimeArtifactsDir = '/app/var/windows-offline-installer/artifacts';

  assert.match(compose, /windows-offline-installer-provision:/);
  assert.match(compose, /node dist\/scripts\/provision-windows-offline-installer\.js/);
  assert.match(compose, /--verify-only/);
  assert.match(compose, /service_completed_successfully/);
  assert.match(
    compose,
    new RegExp(`OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR=${runtimeTemplateDir.replaceAll('/', '\\/')}`)
  );
  assert.match(
    compose,
    new RegExp(
      `OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR=${runtimeArtifactsDir.replaceAll('/', '\\/')}`
    )
  );

  for (const pin of [
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG',
  ]) {
    assert.match(compose, new RegExp(`${pin}=\\$\\{${pin}:\\?`));
  }

  assert.match(compose, new RegExp(`windows_offline_installer_templates:${runtimeTemplateDir}:ro`));
  assert.match(compose, new RegExp(`windows_offline_installer_artifacts:${runtimeArtifactsDir}`));
  const dockerfile = readText('api/Dockerfile');
  assert.match(
    dockerfile,
    /chmod 0700 \/app\/var\/windows-offline-installer\/artifacts/,
    'the artifact volume must be private to the runtime user'
  );
  assert.match(
    compose,
    /PUBLIC_URL=\$\{PUBLIC_URL:\?PUBLIC_URL is required for public installer links\}/
  );

  const docs = readText('docs/windows-offline-installer.md');
  assert.match(docs, /docker compose(?: -f api\/docker-compose\.yml)? up/);
  assert.match(docs, /provision.*before.*traffic|before.*provision.*traffic/i);
  assert.match(docs, /read-only|:ro/i);
  assert.match(docs, /persistent|volume/i);
});

test('release template workflow prepares signed Firefox artifacts through the canonical action', () => {
  const workflow = readText('.github/workflows/release-scripts.yml');
  const buildStep = workflow.indexOf('npm run build --workspace=@openpath/firefox-extension');
  const prepareAction = workflow.indexOf(
    'uses: ./.github/actions/prepare-firefox-release-artifacts'
  );

  assert.ok(buildStep >= 0, 'template workflow must build the Firefox extension first');
  assert.ok(
    prepareAction > buildStep,
    'template workflow must prepare signed artifacts after building the extension'
  );
  assert.doesNotMatch(
    workflow,
    /npm run build:firefox-release --workspace=@openpath\/firefox-extension/,
    'template workflow must not run the signed-artifact bundler before AMO signing'
  );
  assert.match(
    workflow,
    /web-ext-api-key:\s*\$\{\{ secrets\.WEB_EXT_API_KEY \}\}/,
    'template workflow must pass the AMO API key through the canonical action'
  );
  assert.match(
    workflow,
    /web-ext-api-secret:\s*\$\{\{ secrets\.WEB_EXT_API_SECRET \}\}/,
    'template workflow must pass the AMO API secret through the canonical action'
  );
});
