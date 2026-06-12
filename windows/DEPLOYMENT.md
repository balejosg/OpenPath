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

Before deploying to real student machines, validate the AppLocker policy on a pilot device using a non-admin account. See `windows/README.md` for the full browser boundary warning.

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

| Task name                         | Script                                     | Purpose                                       |
| --------------------------------- | ------------------------------------------ | --------------------------------------------- |
| `OpenPath-Update`                 | `scripts\Update-OpenPath.ps1`              | Periodic whitelist fetch and apply            |
| `OpenPath-Watchdog`               | `scripts\Test-DNSHealth.ps1`               | DNS health check and auto-recovery            |
| `OpenPath-Startup`                | `scripts\Update-OpenPath.ps1`              | Apply whitelist at machine startup            |
| `OpenPath-SSE`                    | `scripts\Start-SSEListener.ps1`            | Push listener for instant rule changes        |
| `OpenPath-AgentUpdate`            | `OpenPath.ps1 self-update --silent`        | Daily agent self-update (3 am +/- 45 min)     |
| `OpenPath-RuntimeDependencyApply` | `scripts\Apply-RuntimeDependencyQueue.ps1` | Fast-apply browser-requested dependency hosts |
| `OpenPath-CaptivePortalRecovery`  | `scripts\Recover-CaptivePortal.ps1`        | Captive portal detection and recovery         |

List tasks and their last-run status:

```powershell
Get-ScheduledTask -TaskName "OpenPath-*"
```

## Browser-Extension Artifact Staging

The installer stages browser-extension artifacts when the corresponding directories are present in the source package:

- **Firefox Release**: requires `browser-extension\firefox-release\metadata.json` and `openpath-firefox-extension.xpi`, or supply `-FirefoxExtensionId` and `-FirefoxExtensionInstallUrl` to configure policy-based auto-install.
- **Managed Chromium**: requires `browser-extension\chromium-managed\metadata.json`; policy is applied via Group Policy or Intune-managed registry keys documented in [`firefox-extension/README.md`](../firefox-extension/README.md).
- **Unmanaged Chromium**: store URLs are written to `config.json` and surfaced as `.url` shortcuts; no forced install.

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
