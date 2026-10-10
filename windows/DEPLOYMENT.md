# OpenPath Windows Agent Deployment

> Status: maintained
> Applies to: `windows/`
> Last verified: 2026-06-12
> Source of truth: `windows/DEPLOYMENT.md`

## Supported Delivery Paths

### 1. GitHub Release Zip

The Windows agent is packaged as part of the `release-scripts` workflow (`.github/workflows/release-scripts.yml`). On every push to `main` that touches `windows/`, `VERSION`, or the workflow itself, the pipeline:

1. Runs `pre-install-validation.sh` to sanity-check the package structure.
2. Gates on a same-commit CI, E2E, and Installer Contracts evidence check (`scripts/require-release-quality-gate.mjs`).
3. Packages the agent with `zip -r -q windows-v${VERSION}.zip windows/ runtime/ VERSION`.
4. Publishes a pre-release GitHub Release tagged `scripts-v${VERSION}-${SHORT_SHA}`.

The release asset is named `windows-v<version>.zip`. It contains:

- `windows/` - all PowerShell scripts, library modules, and helper scripts
- `runtime/` - shared runtime assets
- `VERSION` - version string

**Install from the release zip (Administrator PowerShell):**

```powershell
Invoke-WebRequest -Uri "https://github.com/<owner>/openpath/releases/download/<tag>/windows-v<version>.zip" -OutFile "windows.zip"
Expand-Archive -Path "windows.zip" -DestinationPath "."
cd windows
.\Install-OpenPath.ps1 -WhitelistUrl "https://api.example.com/w/<token>/whitelist.txt"
```

**Verify the download:**

Each release publishes a companion `windows-v<version>.zip.sha256` asset containing the SHA256
checksum in standard `sha256sum` format. Verify before extracting:

PowerShell (compare Get-FileHash output against the published checksum):

```powershell
# Download the checksum file
Invoke-WebRequest -Uri "https://github.com/<owner>/openpath/releases/download/<tag>/windows-v<version>.zip.sha256" -OutFile "windows.zip.sha256"

# Read the expected hash from the checksum file (first token on the line)
$expected = (Get-Content "windows.zip.sha256" -Raw).Trim().Split()[0].ToUpper()

# Compute the actual hash of the downloaded zip
$actual = (Get-FileHash "windows.zip" -Algorithm SHA256).Hash

if ($actual -eq $expected) { Write-Host "Checksum OK" } else { Write-Error "Checksum mismatch: expected $expected, got $actual" }
```

Linux / macOS (using sha256sum):

```bash
sha256sum -c windows-v<version>.zip.sha256
```

**Note on code signing:** Release zips are currently unsigned. The PowerShell scripts inside the
zip are not Authenticode-signed because an operator-procured code-signing certificate is still
pending. As a result, `-ExecutionPolicy Bypass` (or an equivalent execution-policy override) is
still required when running the installer. Authenticode signing and winget distribution will be
enabled once the certificate is provisioned.

### 2. Source Install (Development / Direct)

For direct source installs from a repository checkout, run as Administrator from the `windows/` directory:

```powershell
.\Install-OpenPath.ps1 -WhitelistUrl "https://api.example.com/w/<token>/whitelist.txt"
```

Additional supported flags are documented in `windows/Install-OpenPath.ps1` header comments. Some useful combinations:

```powershell
# Skip the Acrylic install step (already installed)
.\Install-OpenPath.ps1 -WhitelistUrl "..." -SkipAcrylic

# Skip the pre-install preflight check
.\Install-OpenPath.ps1 -WhitelistUrl "..." -SkipPreflight

# Verbose output (enables Write-Verbose and Write-Information)
.\Install-OpenPath.ps1 -WhitelistUrl "..." -Verbose
```

### 3. Enrollment Modes

Two enrollment flows are supported. Both are initiated through `Install-OpenPath.ps1` (or post-install via `scripts/Enroll-Machine.ps1` / `.\OpenPath.ps1 enroll`).

**Registration-token mode** - long-lived token, requires a classroom name:

```powershell
.\Install-OpenPath.ps1 `
  -ApiUrl "https://api.example.com" `
  -Classroom "Aula1" `
  -RegistrationToken "<long-lived-token>"
```

**Enrollment-token mode** - short-lived token, classroom identified by ID:

```powershell
.\Install-OpenPath.ps1 `
  -ApiUrl "https://api.example.com" `
  -ClassroomId "<classroom-id>" `
  -EnrollmentToken "<short-lived-token>" `
  -Unattended
```

When `-Unattended` is set alongside a classroom-mode install, the managed browser boundary (`-EnforceManagedBrowserBoundary`) is enabled by default. Pass `-EnforceManagedBrowserBoundary:$false` to suppress it.

Tokens can also be supplied via environment variables:

- `OPENPATH_ENROLLMENT_TOKEN` - used when `-EnrollmentToken` is omitted
- `OPENPATH_TOKEN` - used when `-RegistrationToken` is omitted

Post-install re-enrollment:

```powershell
.\OpenPath.ps1 enroll -ApiUrl https://api.example.com -ClassroomId <id> -EnrollmentToken <token> -Unattended
```

### 4. MDM / Intune Deployment Pattern

For MDM-managed deployments, wrap the installer in a detection/installation script pair. A typical pattern:

1. Stage the release zip to a network share or distribute it as an Intune Win32 app package.
2. Run the installer as SYSTEM with `-Unattended` and supply the enrollment token via the `OPENPATH_ENROLLMENT_TOKEN` environment variable (set it in the MDM deployment policy, not in the script).
3. Use `-EnforceManagedBrowserBoundary` together with `-ApprovedStudentBrowsers` to control which browsers AppLocker permits.

Web-generated offline installers select `ManagedBrowserCompatibility` with no
additional catalog, matching the product default: installed and
Microsoft-signed applications keep working while portable, user-writable, and
unapproved-browser execution stays blocked. Distribution remains blocked until
the same template and personalized executable have complete Windows Desktop
Survival evidence on every supported Windows client edition; local or staging
checks do not replace an externally observed login, desktop session, and
reboot.

The release lane validates that bundle from the exact workflow run and attempt
after downloading binary artifacts by their artifact IDs. It does not ask the
generic external-workflow gate to wait for its own Desktop Survival job. If the
authorized disposable-VM controller is unavailable, the job reports
`BLOCKED_PLATFORM_VALIDATION` and no release is eligible. A fake controller,
AppLocker policy evaluation, or Server runner cannot substitute for client
desktop/reboot evidence.

Before deploying to real student machines, validate the AppLocker policy on a pilot device using a non-admin account. See `windows/README.md` for the full browser boundary warning.

### 5. Offline Installer (Air-Gapped / Restricted Networks)

OpenPath provides the generic authenticated generation and download lifecycle for machines that
cannot reach the API during installation. The SPA calls
`windowsOfflineInstaller.generate({ classroomId })`, then the operator activates the visible
download link. The API returns a short-lived, bounded-retry URL and verifies the generated bytes
against their SHA-256 before streaming them. See
[`docs/windows-offline-installer.md`](../docs/windows-offline-installer.md) for the server
configuration, provisioning command, public response, route statuses, and canary.

The resulting self-contained installer carries the enrollment token inside its own file. The
executable is a standard NSIS setup with an
`OPWSI1` trailer appended after the NSIS payload: a fixed-size binary slot holding the API URL,
classroom id, enrollment token, captive-portal domains, and approved browsers, followed by a
fixed epilogue. The trailer is read from the raw bytes of the downloaded file, so HTTP proxies
and download managers cannot break it.

OpenPath ships the generic template
(`windows/offline-installer/OpenPath-Windows-Setup.nsi`), the trailer reader
(`offline-installer/scripts/Read-Trailer.ps1`), and the offline runtime
(`windows/lib/install/Installer.Offline.ps1`). The offline runtime defers enrollment to first
boot: it stages a DPAPI-protected pending state readable only by SYSTEM, registers a startup
retry task, and transitions `PENDING -> ENROLLED` once connectivity exists. An expired embedded
token moves the machine to `EXPIRED`; re-install with a fresh installer.

Contract details live in `shared/src/windows-offline-installer.ts` (magic bytes, slot sizes,
Zod schemas) and `api/src/lib/windows-offline-installer.ts` (append/parse). Repo-config tests in
`tests/repo-config/windows-offline-installer-contracts.test.mjs` pin the format.

## Package and Runtime Artifacts

After installation the agent occupies `C:\OpenPath\` with the following layout:

- `OpenPath.ps1` - operator CLI
- `Install-OpenPath.ps1` - installer
- `Uninstall-OpenPath.ps1` - uninstaller
- `Rotate-Token.ps1` - token rotation helper
- `lib\*.psm1` - runtime library modules
- `scripts\Update-OpenPath.ps1` - whitelist fetch and apply
- `scripts\Test-DNSHealth.ps1` - watchdog health check
- `scripts\Start-SSEListener.ps1` - SSE push listener
- `scripts\Enroll-Machine.ps1` - enrollment helper
- `scripts\Apply-RuntimeDependencyQueue.ps1` - fast-apply runtime dependency queue
- `scripts\Recover-CaptivePortal.ps1` - captive portal recovery task
- `data\config.json` - persisted runtime configuration
- `data\logs\openpath.log` - agent log
- `browser-extension\firefox\`, `browser-extension\firefox-release\`, `browser-extension\chromium-managed\`, `browser-extension\chromium-unmanaged\` - staged extension artifacts

Acrylic DNS Proxy is installed to `C:\Program Files (x86)\Acrylic DNS Proxy\`. Its configuration and host overrides live at:

- `%ProgramFiles(x86)%\Acrylic DNS Proxy\AcrylicConfiguration.ini`
- `%ProgramFiles(x86)%\Acrylic DNS Proxy\AcrylicHosts.txt`

## Scheduled Tasks

The installer registers the following Task Scheduler tasks under the `OpenPath` prefix (verified from `windows/lib/internal/ScheduledTaskCatalog.ps1`):

| Task name                          | Script                                      | Purpose                                                                                                                                         |
| ---------------------------------- | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `OpenPath-Update`                  | `scripts\Update-OpenPath.ps1`               | Periodic whitelist fetch and apply                                                                                                              |
| `OpenPath-Watchdog`                | `scripts\Test-DNSHealth.ps1`                | DNS health check and auto-recovery                                                                                                              |
| `OpenPath-Startup`                 | `scripts\Update-OpenPath.ps1`               | Apply whitelist at machine startup                                                                                                              |
| `OpenPath-SSE`                     | `scripts\Start-SSEListener.ps1`             | Push listener for instant rule changes                                                                                                          |
| `OpenPath-AgentUpdate`             | `OpenPath.ps1 self-update --silent`         | Daily agent self-update (3 am +/- 45 min)                                                                                                       |
| `OpenPath-RuntimeDependencyApply`  | `scripts\Apply-RuntimeDependencyQueue.ps1`  | Fast-apply browser-requested dependency hosts (fallback path)                                                                                   |
| `OpenPath-RuntimeDependencyWorker` | `scripts\Start-RuntimeDependencyWorker.ps1` | Resident SYSTEM worker: watches the dependency queue and applies batches in-process (heartbeats to `data\runtime-dependency-worker-state.json`) |
| `OpenPath-CaptivePortalRecovery`   | `scripts\Recover-CaptivePortal.ps1`         | Captive portal detection and recovery                                                                                                           |

List tasks and their last-run status:

```powershell
Get-ScheduledTask -TaskName "OpenPath-*"
```

## Browser-Extension Artifact Staging

The installer stages browser-extension artifacts when the corresponding directories are present in the source package:

- **Firefox Release**: requires `browser-extension\firefox-release\metadata.json` and `openpath-firefox-extension.xpi`, or supply `-FirefoxExtensionId` and `-FirefoxExtensionInstallUrl` to configure policy-based auto-install.
- **Managed Chromium**: requires `browser-extension\chromium-managed\metadata.json`; policy is applied via Group Policy or Intune-managed registry keys documented in [`firefox-extension/README.md`](../firefox-extension/README.md).
- **Unmanaged Chromium**: store URLs are written to `config.json` and surfaced as `.url` shortcuts; no forced install.

## Compiled Native Host (AppControl classrooms)

Classroom installs enforce the non-admin AppLocker boundary, which denies
`powershell.exe`/`pwsh.exe` to the restricted student and therefore blocked the
PowerShell native messaging host. The installer now compiles the shipped C#
source on the target machine and registers the executable after a framed `ping`
health check; the PowerShell/cmd host remains the fallback.

Artifacts under `browser-extension\firefox\native\`:

- `OpenPath-NativeHost.exe` - compiled host (generated on the machine, never shipped);
  source payload at `C:\OpenPath\native-host\OpenPathNativeHost.cs`.
- `OpenPath-NativeHost.manifest.json` - source/executable hashes and health state.
- `OpenPath-NativeHost.build.json` - build diagnostics (compiler output, Smart App Control state).
- `OpenPath-NativeHost.cmd` - PowerShell fallback; the Firefox manifest `path`
  points at the `.exe` only when the manifest is healthy and the executable hash
  still matches.

The build uses the in-box `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`
(no SDK, no NuGet, no network). Compile or health failures keep the previous
executable or the `.cmd` fallback and are recorded in the diagnostics file.
Uninstall removes the executable, source, manifest and diagnostics; the
integrity baseline covers the executable whenever present. An unsigned locally
compiled binary can be blocked by Smart App Control in enforcement; the build
diagnostics record that state and the fallback keeps working. See
[`docs/design/windows-native-host-under-appcontrol.md`](../docs/design/windows-native-host-under-appcontrol.md)
and [`docs/extension-native-host-contract.md`](../docs/extension-native-host-contract.md).

### Smart App Control deployments

With SAC enforced, the PowerShell/cmd fallback does not exist for the
restricted student (`powershell.exe`/`pwsh.exe` are denied by the AppLocker
boundary), so an unsigned compiled host means **no native host at all**. The
product prefers a prebuilt Authenticode-signed executable when the install
payload carries one (`native-host\signed\OpenPath-NativeHost.exe` plus its
`OpenPath-NativeHost.signing.json`, anchored on the payload manifest sha256 and
the publisher pin); otherwise it compiles, and only a valid signature is ever
executed. The signing channel is documented in
[`docs/design/windows-native-host-signing.md`](../docs/design/windows-native-host-signing.md).

What the administrator sees:

- If SAC is enforced and no valid host is available, the installer finishes
  with a warning listing the features that will not work for restricted
  students: whitelist path/subdomain rules in Firefox, the request-access
  screen and approval propagation, runtime dependency learning and captive
  portal recovery.
- The watchdog health report carries the product reason code
  (`native_host_smart_app_control_blocked`, `native_host_signature_invalid`,
  `native_host_compile_failed`, `native_host_health_ping_failed`,
  `native_host_compiled_unavailable`) and turns the report DEGRADED.
- `C:\OpenPath\browser-extension\firefox\native\fallback-state.json` records the
  last logged availability state (reason, status, boundary flag) so repeated
  refreshes do not spam the log; the log line is an ERROR only when the
  classroom boundary is active.
- The install never changes the SAC state and never aborts because of it.

Before the signing channel is activated (Phase 8.1), an SAC-enforced classroom
is expected to stay in this "SAC active, not supported" state; the diagnostic
paths above make it visible without breaking the rest of the deployment.

```powershell
# Registered launch path (.exe = compiled host, .cmd = fallback)
(Get-Content 'C:\OpenPath\browser-extension\firefox\native\whitelist_native_host.json' -Raw | ConvertFrom-Json).path
# Build state
Get-Content 'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.manifest.json' -Raw
Get-Content 'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.build.json' -Raw -ErrorAction SilentlyContinue
# Force a rebuild after changing the source
.\OpenPath.ps1 update
```

## Deployment Verification

After installation, verify:

```powershell
# Run the pre-install validation script to confirm requirements are still met
.\scripts\Pre-Install-Validation.ps1

# Check scheduled task registration
Get-ScheduledTask -TaskName "OpenPath-*"

# Check firewall rules
Get-NetFirewallRule -DisplayName "OpenPath-DNS-*"

# Confirm Acrylic is intercepting DNS
nslookup example.com 127.0.0.1

# Check agent status
.\OpenPath.ps1 status

# Tail the log
Get-Content C:\OpenPath\data\logs\openpath.log -Tail 100
```

A healthy `.\OpenPath.ps1 status` output shows:

```
Overall: HEALTHY
Acrylic service: Running
DNS resolving: True
Sinkhole active: True
Firewall active: True
```
