# OpenPath Windows Agent

> Status: maintained
> Applies to: `windows/`
> Last verified: 2026-04-13
> Source of truth: `windows/README.md`

The Windows agent enforces OpenPath policy with Acrylic DNS Proxy, Windows Firewall, scheduled tasks, browser policy rollout, and an operator CLI entrypoint at `OpenPath.ps1`.

## Installation

Run as Administrator:

```powershell
.\Install-OpenPath.ps1 -WhitelistUrl "http://your-server:3000/export/group.txt"
```

Supported classroom-oriented install patterns include:

```powershell
.\Install-OpenPath.ps1 -ApiUrl "https://api.example.com" -ClassroomId "<classroom-id>" -EnrollmentToken "<token>" -Unattended
.\Install-OpenPath.ps1 -WhitelistUrl "http://your-server:3000/export/group.txt" -SkipPreflight
.\Install-OpenPath.ps1 -WhitelistUrl "http://your-server:3000/export/group.txt" -Verbose
```

The installer stages browser-extension artifacts when present and registers scheduled tasks for update, watchdog, startup, SSE, and agent self-update flows.

## Operational Commands

`OpenPath.ps1` currently supports:

- `status`
- `update`
- `health`
- `doctor`
- `self-update`
- `enroll`
- `rotate-token`
- `restart`
- `help`

Examples:

```powershell
.\OpenPath.ps1 status
.\OpenPath.ps1 doctor browser
.\OpenPath.ps1 self-update --check
```

## Runtime Shape

Installed structure centers on `C:\OpenPath\` and includes:

- `OpenPath.ps1`
- `Install-OpenPath.ps1`
- `Uninstall-OpenPath.ps1`
- `Rotate-Token.ps1`
- `lib\*.psm1`
- `scripts\Update-OpenPath.ps1`, `scripts\Start-SSEListener.ps1`, `scripts\Test-DNSHealth.ps1`, `scripts\Enroll-Machine.ps1`
- `data\config.json`, `data\logs\`, local whitelist state
- `browser-extension\firefox`, `browser-extension\firefox-release`, `browser-extension\chromium-managed`, `browser-extension\chromium-unmanaged`

## Browser Distribution Notes

- Firefox Release auto-install requires a signed distribution via `firefoxExtensionId` + `firefoxExtensionInstallUrl` or staged `browser-extension\firefox-release\metadata.json` plus `openpath-firefox-extension.xpi`.
- Managed Chromium rollout depends on staged `browser-extension\chromium-managed\metadata.json` and the API routes documented in [`../firefox-extension/README.md`](../firefox-extension/README.md).
- Unmanaged Chromium guidance uses store URLs in `config.json` and `.url` shortcuts rather than forced install.

## Verification

```powershell
.\scripts\Pre-Install-Validation.ps1
Get-ScheduledTask -TaskName "OpenPath-*"
Get-NetFirewallRule -DisplayName "OpenPath-*"
nslookup example.com 127.0.0.1
Get-Content C:\OpenPath\data\logs\openpath.log -Tail 100
```

## Browser Enforcement Validation

Target-platform browser-boundary validation is a destructive-lab activity, not
a normal local development check. Run it only after the Windows browser
enforcement prerequisites are already committed:

- Phase 1: non-admin AppLocker browser boundary.
- Phase 3: managed browser readiness fails closed.
- Phase 4: DNS, DoH, and resolver egress controls.

Prepare a reversible runner lab before executing probes:

```text
reset runner
snapshot VM
enroll disposable staging student
run probes
delete disposable staging IDs
rollback VM
restore runner services
run smoke
```

Use report mode first. It writes the probe plan and prerequisites without
starting browsers, copying runtimes, creating probe scripts, or running network
commands:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ..\tests\e2e\ci\windows-browser-enforcement.ps1 -Scope Report
```

From a standard non-admin student account, run the executable and network
boundary probes only with the explicit execution flags:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ..\tests\e2e\ci\windows-browser-enforcement.ps1 `
  -Scope Student `
  -ExecuteProbes `
  -PrepareProbeFiles `
  -BlockedPathUrl "https://blocked.127.0.0.1.sslip.io/game" `
  -BlockedHost "blocked.127.0.0.1.sslip.io"
```

The student probe covers managed Firefox blocked-path launch, Edge and Chrome
only when managed, Brave/Opera/Vivaldi/Tor launch denial, portable browser
denial from Downloads and Desktop, PowerShell and batch denial from Downloads,
Python or Node copied into Downloads when available, Google search-game
blocking, `1.1.1.1` DoH-by-IP failure, and the Cloudflare `curl --resolve`
bypass command.

From an elevated administrator shell, run the admin validation section:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ..\tests\e2e\ci\windows-browser-enforcement.ps1 `
  -Scope Admin `
  -ExecuteProbes
```

The admin probe proves the operator can run management tools, inspect
AppLocker policy, find OpenPath recovery entrypoints, and that the AppLocker
administrator allow-all rule remains intact.

`run-windows-student-flow.ps1` can invoke the student probe after the SSE
student-policy pass, but it is opt-in so ordinary student-policy runs stay
light:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ..\tests\e2e\ci\run-windows-student-flow.ps1 -RunBrowserEnforcementProbes
```

Equivalently set `OPENPATH_WINDOWS_BROWSER_ENFORCEMENT_PROBES=1` for the
runner process. Do not claim the Windows browser-boundary target-platform
symptom cleared from report mode, admin-only evidence, or any run against
partial Phase 1, Phase 3, or Phase 4 enforcement.
