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
  assert.match(
    localAcrylic,
    /\[System\.IO\.Compression\.ZipFile\]::ExtractToDirectory/,
    'offline Acrylic install must use the Windows-compatible ZIP extractor'
  );
  assert.match(
    localAcrylic,
    /Copy-Item -LiteralPath \$extractedItem\.FullName/,
    'offline Acrylic install must stage root-level ZIP entries without wildcard parsing'
  );
});

test('offline payload manifest validation fails closed on missing or mismatched payloads', () => {
  const offlineModule = readText('windows/lib/install/Installer.Offline.ps1');
  const manifestCheck = extractFunctionBody(offlineModule, 'Assert-OpenPathOfflinePayloadManifest');

  assert.match(
    offlineModule,
    /function Get-OpenPathOfflinePayloadSha256\b/,
    'manifest validation must expose a dedicated payload hash provider'
  );
  assert.match(
    manifestCheck,
    /Get-OpenPathOfflinePayloadSha256/,
    'manifest validation must hash staged payloads through the provider'
  );
  assert.match(
    offlineModule,
    /\[System\.IO\.File\]::OpenRead\(\$Path\)/,
    'payload hash provider must use a literal .NET file stream'
  );
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
  assert.match(
    verifyScript,
    /GetEnvironmentVariable\('ProgramFiles\(x86\)'\)/,
    'verify-nsis.ps1 must inspect the standard Program Files (x86) environment location'
  );
  assert.ok(
    verifyScript.includes("Join-Path $programFilesX86 'NSIS\\makensis.exe'"),
    'verify-nsis.ps1 must inspect the standard Chocolatey NSIS installation path'
  );

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
  assert.match(
    nsiSource,
    /SetOutPath "\$INSTDIR"[\s\S]*File "\/oname=Install-OpenPath\.ps1" "\$\{REPO_ROOT\}\\windows\\Install-OpenPath\.ps1"/,
    'NSIS must materialize the offline entrypoint explicitly at the installer root'
  );
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
    'Create personalized NSIS executable',
    'Validate personalized trailer with PowerShell',
    'run-windows-offline-installer-exe.ps1',
    'Execute the personalized NSIS executable E2E',
    'Upload personalized NSIS E2E evidence',
  ]) {
    assert.ok(workflow.includes(marker), `release workflow should include ${marker}`);
  }
  assert.match(
    workflow,
    /name: Validate personalized trailer with PowerShell[\s\S]*Read-Trailer\.ps1/,
    'release workflow must validate the customized trailer with the canonical PowerShell reader before launching NSIS'
  );
  const trailerValidationStart = workflow.indexOf(
    'name: Validate personalized trailer with PowerShell'
  );
  const trailerValidationEnd = workflow.indexOf(
    'name: Execute the personalized NSIS executable E2E'
  );
  const trailerValidationBlock = workflow.slice(trailerValidationStart, trailerValidationEnd);
  const personalizedBuildStart = workflow.indexOf('name: Create personalized NSIS executable');
  assert.ok(
    personalizedBuildStart >= 0 && personalizedBuildStart < trailerValidationStart,
    'the personalized executable must be created before its PowerShell trailer validation'
  );
  assert.match(
    workflow.slice(personalizedBuildStart, trailerValidationStart),
    /create-personalized-test-installer\.mjs/,
    'the release workflow must create the personalized executable in its own step'
  );
  assert.match(
    trailerValidationBlock,
    /Test-Path -LiteralPath \$validationPath -PathType Leaf/,
    'PowerShell trailer validation must use the output file because a script exit code is not a native process exit code'
  );
  assert.match(
    trailerValidationBlock,
    /powershell\.exe[\s\S]*-File \$readerPath/,
    'preflight must exercise the same Windows PowerShell executable that NSIS launches'
  );
  assert.doesNotMatch(
    trailerValidationBlock,
    /\$readerExitCode\s*=\s*\$LASTEXITCODE/,
    'PowerShell trailer validation must not treat the native-process exit code as the script result'
  );

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
    workflow,
    /npm run build --workspace=@openpath\/shared/,
    'Windows trailer tests must build the shared runtime package before importing API helpers'
  );
  assert.doesNotMatch(
    workflow,
    /^\s+nsis-version:/m,
    'the NSIS action must not use the unsupported nsis-version input'
  );

  assert.match(
    executableLane,
    /failureStage\s*=\s*\$script:CurrentStage/,
    'Windows EXE evidence must preserve a safe failure stage for diagnosis'
  );
  assert.match(
    executableLane,
    /installerExitCode\s*=\s*\$installExitCode/,
    'Windows EXE evidence must preserve the installer exit code when available'
  );
  assert.match(
    executableLane,
    /installerStatus\s*=\s*Get-SafeInstallerStatus/,
    'Windows EXE evidence must preserve only the bounded NSIS stage status for diagnosis'
  );
  assert.match(
    executableLane,
    /ReadAllBytes[\s\S]*bytes\.Length\s*-ne\s*2[\s\S]*switch \(\$stage\)/,
    'Windows EXE evidence must decode only the fixed two-byte NSIS stage marker'
  );
  assert.match(
    executableLane,
    /Get-ChildItem[\s\S]*OpenPathOfflineSetup-\*-status\*\.txt[\s\S]*Get-SafeInstallerStatus/,
    'Windows EXE failure evidence must inspect all bounded stage markers without uploading paths or logs'
  );
  const failureEvidenceBlock = executableLane.slice(
    executableLane.lastIndexOf('catch {'),
    executableLane.lastIndexOf('finally {')
  );
  assert.doesNotMatch(
    failureEvidenceBlock,
    /Exception\.Message|Receive-Job|openpath\.log/,
    'Windows EXE failure evidence must not upload raw exception or installer logs'
  );

  assert.match(
    nsiSource,
    /!define BUILD_DIR "\$\{REPO_ROOT\}\\windows\\offline-installer\\build"/,
    'NSIS build output must stay inside the repository build directory'
  );
  assert.match(
    nsiSource,
    /SetOutPath "\$INSTDIR\\scripts"[\s\S]*File "\/oname=Read-Trailer\.ps1" "\$\{REPO_ROOT\}\\windows\\offline-installer\\scripts\\Read-Trailer\.ps1"/,
    'NSIS must load its trailer reader from an explicit repository path'
  );
  assert.match(
    nsiSource,
    /CopyFiles \/SILENT "\$EXEDIR\\\$EXEFILE" "\$INSTDIR"[\s\S]*-ExecutablePath "\$INSTDIR\\\$EXEFILE"/,
    'NSIS must pass an exact temporary copy of the running executable to the trailer reader'
  );
  assert.match(
    nsiSource,
    /OpenPathOfflineSetup-\$EXEFILE-status\.txt/,
    'NSIS must expose only a bounded stage status file for safe executable-lane diagnosis'
  );
  assert.match(
    nsiSource,
    /FileWriteByte/,
    'NSIS stage status must use an unambiguous bounded byte representation'
  );
  assert.match(
    nsiSource,
    /OpenPathOfflineSetup-\$EXEFILE-status-\$R1\.txt/,
    'NSIS must preserve one bounded stage marker per installer phase'
  );
  const readTrailerSection = nsiSource.slice(
    nsiSource.indexOf('Section "ReadTrailer"'),
    nsiSource.indexOf('SectionEnd', nsiSource.indexOf('Section "ReadTrailer"'))
  );
  const trailerResultOffset = readTrailerSection.indexOf("' $0");
  const trailerBranchOffset = readTrailerSection.indexOf(
    'IfFileExists "$INSTDIR\\offline-config.json" trailer_output_present trailer_output_missing'
  );
  const trailerEvidenceOffset = readTrailerSection.indexOf(
    'Push "${OFFLINE_STAGE_READ_TRAILER_EXIT}"'
  );
  const trailerExecOffset = readTrailerSection.indexOf(
    'ExecWait \'"$SYSDIR\\WindowsPowerShell\\v1.0\\powershell.exe"'
  );
  const trailerOutputCleanupOffset = readTrailerSection.indexOf(
    'Delete "$INSTDIR\\offline-config.json"'
  );
  assert.ok(trailerResultOffset >= 0, 'NSIS must capture the trailer reader result');
  assert.ok(trailerExecOffset >= 0, 'NSIS must invoke the canonical trailer reader');
  assert.ok(
    trailerOutputCleanupOffset >= 0 && trailerOutputCleanupOffset < trailerExecOffset,
    'NSIS must remove stale trailer output before invoking the reader'
  );
  assert.ok(trailerBranchOffset > trailerResultOffset, 'NSIS must branch on the trailer result');
  assert.ok(
    trailerEvidenceOffset > trailerBranchOffset,
    'NSIS must branch before an evidence helper can affect the result register'
  );
  assert.match(
    readTrailerSection,
    /IfFileExists "\$INSTDIR\\offline-config\.json" trailer_output_present trailer_output_missing/,
    'NSIS must require the canonical trailer reader output before continuing'
  );
  assert.match(
    readTrailerSection,
    /trailer_output_present:[\s\S]*OFFLINE_STAGE_READ_TRAILER_OUTPUT_PRESENT[\s\S]*Goto trailer_ok/,
    'NSIS must record a successful trailer output commit before continuing'
  );
  assert.match(
    readTrailerSection,
    /trailer_output_missing:[\s\S]*OFFLINE_STAGE_READ_TRAILER_OUTPUT_MISSING[\s\S]*Goto trailer_failed/,
    'NSIS must record a missing trailer output before failing closed'
  );
  assert.match(
    readTrailerSection,
    /ExecWait '"\$SYSDIR\\WindowsPowerShell\\v1\.0\\powershell\.exe" -NoProfile[^']*' \$0/,
    'NSIS must synchronously invoke the built-in Windows PowerShell executable with an explicit quoted path'
  );
  assert.doesNotMatch(
    readTrailerSection,
    /nsExec::ExecToLog/,
    'NSIS trailer validation must not collapse nsExec error strings into a numeric marker'
  );
  const runInstallerSection = nsiSource.slice(
    nsiSource.indexOf('Section "RunInstaller"'),
    nsiSource.indexOf('SectionEnd', nsiSource.indexOf('Section "RunInstaller"'))
  );
  assert.match(
    runInstallerSection,
    /ExecWait '"\$SYSDIR\\WindowsPowerShell\\v1\.0\\powershell\.exe" -NoProfile[^']*' \$1/,
    'NSIS must synchronously invoke the offline installer through the same explicit PowerShell path'
  );
  assert.doesNotMatch(
    runInstallerSection,
    /nsExec::ExecToLog/,
    'NSIS offline installation must not depend on plugin-specific error strings'
  );
  const normalizeStatusSource = nsiSource.slice(
    nsiSource.indexOf('Function NormalizeOfflineStatusByte'),
    nsiSource.indexOf('Function WriteOfflineStage')
  );
  assert.match(
    normalizeStatusSource,
    /StrCmp \$R0 "error"[\s\S]*Push "\$\{OFFLINE_STATUS_EXEC_ERROR\}"/,
    'NSIS evidence must encode launch failures with a reserved byte value'
  );
  assert.match(
    normalizeStatusSource,
    /StrCmp \$R0 "timeout"[\s\S]*Push "\$\{OFFLINE_STATUS_EXEC_TIMEOUT\}"/,
    'NSIS evidence must encode timeout failures with a reserved byte value'
  );
  assert.match(
    normalizeStatusSource,
    /StrCmp \$R0 "" offline_status_exec_error/,
    'NSIS evidence must classify an undefined process result as a launch failure'
  );
  assert.match(
    readTrailerSection,
    /ClearErrors[\s\S]*ExecWait[\s\S]*IfErrors trailer_exec_error/,
    'NSIS must inspect the ExecWait error flag before trusting its output variable'
  );
  assert.doesNotMatch(
    nsiSource,
    /-ExecutablePath "\$EXEPATH"/,
    'NSIS must not rely on the ambiguous EXEPATH variable for trailer validation'
  );
});

test('Windows personalized EXE evidence must traverse the real HTTP download contract', () => {
  const lane = readText('tests/e2e/ci/run-windows-personalized-offline-installer-e2e.ps1');
  for (const marker of [
    'Start-TestPostgres',
    'Start-Api',
    'backend-harness.ts bootstrap',
    'scripts/windows-offline-installer-canary.mjs',
    'OPENPATH_CANARY_OUTPUT_PATH',
    'downloadStatus',
    'replayStatus',
    'run-windows-offline-installer-exe.ps1',
    'Invoke-PhysicalExeE2E',
    'trailerValidated',
    'payloadManifestValidated',
    'pendingStateObserved',
    'pendingStateCleared',
  ]) {
    assert.ok(lane.includes(marker), `personalized HTTP-to-EXE lane should include ${marker}`);
  }
  assert.match(
    lane,
    /downloadSha256[\s\S]*Get-FileHash[\s\S]*downloadSize/,
    'the lane must verify the persisted download bytes independently'
  );
  const safeEvidenceStart = lane.indexOf('$success =');
  const safeEvidenceEnd = lane.indexOf('Write-SafeEvidence -Payload $success');
  assert.ok(safeEvidenceStart >= 0 && safeEvidenceEnd > safeEvidenceStart);
  assert.doesNotMatch(
    lane.slice(safeEvidenceStart, safeEvidenceEnd),
    /(?:OPENPATH_CANARY_ACCESS_TOKEN|enrollmentToken|Bearer)/i,
    'personalized HTTP-to-EXE evidence must not persist authentication material'
  );

  const workflow = readText('.github/workflows/release-scripts.yml');
  for (const marker of [
    'Execute personalized HTTP download-to-EXE E2E',
    'run-windows-personalized-offline-installer-e2e.ps1',
    'OPENPATH_E2E_TEMPLATE_COMMIT: ${{ github.sha }}',
    'Upload personalized HTTP-to-EXE E2E evidence',
  ]) {
    assert.ok(workflow.includes(marker), `release workflow should include ${marker}`);
  }
  assert.match(
    workflow,
    /Create personalized NSIS executable[\s\S]*Execute personalized HTTP download-to-EXE E2E/,
    'the real HTTP-to-EXE lane must run after the pinned template is built'
  );
});

test('real NSIS failures expose only a bounded installer phase for diagnosis', () => {
  const installer = readText('windows/Install-OpenPath.ps1');
  const offlineModule = readText('windows/lib/install/Installer.Offline.ps1');
  const nsiSource = readText('windows/offline-installer/OpenPath-Windows-Setup.nsi');

  assert.match(
    installer,
    /\[string\]\$FailureStatusPath = ""/,
    'the offline entrypoint should accept an optional safe failure-phase output path'
  );
  assert.match(
    installer,
    /Write-OpenPathInstallerFailureStatus[\s\S]*\$script:OpenPathInstallerCurrentPhase/,
    'installer failures should write only the current phase, never raw diagnostics'
  );
  assert.match(
    installer,
    /function Get-OpenPathInstallerFailurePhase[\s\S]*\$phase -notin @\('acrylic-install-local', 'enrollment-save-pending'\)[\s\S]*\$candidate[\s\S]*return \$candidate/,
    'installer failures should preserve bounded subphases without masking later phases'
  );
  assert.match(
    nsiSource,
    /-FailureStatusPath "\$INSTDIR\\OpenPathOfflineSetup-\$EXEFILE-installer-failure-phase\.txt"/,
    'NSIS should request the bounded failure-phase marker from the existing offline entrypoint'
  );
  assert.match(
    nsiSource,
    /CopyFiles \/SILENT "\$INSTDIR\\OpenPathOfflineSetup-\$EXEFILE-installer-failure-phase\.txt" "\$TEMP"/,
    'NSIS should publish only the bounded failure-phase marker to the evidence temp root'
  );
  assert.match(
    nsiSource,
    /Delete "\$TEMP\\OpenPathOfflineSetup-\$EXEFILE-installer-failure-phase\.txt"/,
    'NSIS should remove a stale installer failure-phase marker before a new run'
  );
  assert.match(
    installer,
    /function Set-OpenPathOfflinePayloadFailurePhase[\s\S]*hash-io[\s\S]*runtime\|extension\|pinned\|unknown[\s\S]*command\|parameter\|null\|access\|not-found\|other[\s\S]*\$Matches\[1\][\s\S]*offline-payload-verification-\$suffix/,
    'payload failures should expose only a bounded verification category for diagnosis'
  );
  assert.match(
    installer,
    /Set-OpenPathOfflinePayloadFailurePhase -ErrorRecord \$_/,
    'payload verification should classify its failure before the phase result is returned'
  );
  assert.match(
    offlineModule,
    /ValidatePattern\('\^\(manifest\|entry\|missing\|sha256\|size\|hash-io\|size-io\|io\|failed\)\(-\(repo\|windows\|runtime\|extension\|pinned\|unknown\)\(-\(command\|parameter\|null\|access\|not-found\|other\)\)\?\)\?\$'\)[\s\S]*Offline payload verification failed \[\$Category\]/,
    'payload verification should retain a structured, non-sensitive failure category'
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
    /\[string\]\$StatusPath/,
    'the trailer reader must accept an optional diagnostic marker path'
  );
  assert.match(
    trailerReader,
    /WriteAllBytes\([\s\S]*\$StatusPath[\s\S]*\[byte\[\]\]/,
    'the trailer reader diagnostic must be a bounded binary marker'
  );
  assert.match(
    trailerReader,
    /offlineModuleCandidates[\s\S]*Join-Path \$PSScriptRoot '\.\.\\lib\\install\\Installer\.Offline\.ps1'/,
    'trailer reader must resolve dependencies from the extracted installer root'
  );
  assert.match(
    readTrailerSection,
    /-StatusPath "\$INSTDIR\\OpenPathOfflineSetup-\$EXEFILE-trailer-status\.txt"/,
    'NSIS must keep the trailer marker private until the child has finished'
  );
  assert.match(
    readTrailerSection,
    /ExecWait[\s\S]*IfFileExists "\$INSTDIR\\OpenPathOfflineSetup-\$EXEFILE-trailer-status\.txt" trailer_marker_present trailer_marker_missing[\s\S]*CopyFiles \/SILENT "\$INSTDIR\\OpenPathOfflineSetup-\$EXEFILE-trailer-status\.txt" "\$TEMP"[\s\S]*IfFileExists "\$INSTDIR\\offline-config\.json"/,
    'NSIS must publish only the bounded trailer marker before deciding the output result'
  );
  assert.match(
    readTrailerSection,
    /IfFileExists "\$INSTDIR\\OpenPathOfflineSetup-\$EXEFILE-trailer-status\.txt" trailer_marker_present trailer_marker_missing/,
    'NSIS must preserve a bounded marker-state diagnostic when the child exits'
  );
  assert.match(
    readTrailerSection,
    /CopyFiles \/SILENT "\$EXEDIR\\\$EXEFILE" "\$INSTDIR"[\s\S]*-ExecutablePath "\$INSTDIR\\\$EXEFILE"/,
    'NSIS must validate a temporary copy because the running executable can be locked for sharing'
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
  assert.equal(
    compose.match(
      /OPENPATH_WINDOWS_OFFLINE_ARTIFACT_RETENTION_HOURS=\$\{OPENPATH_WINDOWS_OFFLINE_ARTIFACT_RETENTION_HOURS:-24\}/g
    )?.length,
    2,
    'provisioner and API must receive the same bounded artifact retention setting'
  );

  assert.match(compose, new RegExp(`windows_offline_installer_templates:${runtimeTemplateDir}:ro`));
  assert.match(compose, new RegExp(`windows_offline_installer_artifacts:${runtimeArtifactsDir}`));
  const dockerfile = readText('api/Dockerfile');
  assert.match(
    dockerfile,
    /HEALTHCHECK[\s\S]*127\.0\.0\.1:3000\/ready|HEALTHCHECK[\s\S]*localhost:3000\/ready/
  );
  assert.doesNotMatch(dockerfile, /HEALTHCHECK[\s\S]*\/health/);
  assert.match(
    dockerfile,
    /chmod 0700 \/app\/var\/windows-offline-installer\/artifacts/,
    'the artifact volume must be private to the runtime user'
  );
  assert.match(
    compose,
    /PUBLIC_URL=\$\{PUBLIC_URL:\?PUBLIC_URL is required for public installer links\}/
  );
  assert.match(
    compose,
    /127\.0\.0\.1:3000\/ready/,
    'Docker must use the readiness endpoint rather than liveness'
  );
  assert.doesNotMatch(
    compose,
    /healthcheck:[\s\S]*127\.0\.0\.1:3000\/health/,
    'Docker healthcheck must not classify liveness as readiness'
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
  assert.match(
    workflow,
    /OPENPATH_CHROMIUM_PACKAGER/,
    'template workflow must select an installed Chromium-compatible packager'
  );
  assert.match(
    workflow,
    /OPENPATH_CHROMIUM_REQUIRE_MANAGED[\s\S]*--require-managed/,
    'template workflow must fail closed when managed Chromium metadata cannot be built'
  );
  assert.match(
    workflow,
    /ProgramFiles\(x86\)[\s\S]*Microsoft\\Edge[\\/]Application[\\/]msedge\.exe/,
    'template workflow must inspect the standard hosted Edge installation path'
  );
});
