# OpenPath Windows Agent Troubleshooting

> Status: maintained
> Applies to: `windows/`
> Last verified: 2026-06-12
> Source of truth: `windows/TROUBLESHOOTING.md`

## First Checks

Run as Administrator from `C:\OpenPath\`:

```powershell
.\OpenPath.ps1 status
.\OpenPath.ps1 health
.\OpenPath.ps1 doctor browser
Get-Content C:\OpenPath\data\logs\openpath.log -Tail 100
```

`.\OpenPath.ps1 status` prints an `Overall:` line of `HEALTHY`, `DEGRADED`, `CRITICAL`, or `STALE_FAILSAFE`. The individual fields it checks are Acrylic service state, DNS resolution, sinkhole state, and firewall rule presence.

## Important Scheduled Tasks

```powershell
Get-ScheduledTask -TaskName "OpenPath-*"
Get-ScheduledTaskInfo -TaskName "OpenPath-Update"
Get-ScheduledTaskInfo -TaskName "OpenPath-Watchdog"
Get-ScheduledTaskInfo -TaskName "OpenPath-SSE"
Get-ScheduledTaskInfo -TaskName "OpenPath-CaptivePortalRecovery"
Get-ScheduledTaskInfo -TaskName "OpenPath-RuntimeDependencyApply"
Get-ScheduledTaskInfo -TaskName "OpenPath-AgentUpdate"
Get-ScheduledTaskInfo -TaskName "OpenPath-Startup"
```

`LastTaskResult` of `0` means success; `267009` (0x41301) means currently running; other non-zero values indicate the task exited with an error.

## Common Symptoms

### Pre-Install Validation Failures

Run the validation script before re-installing or diagnosing a broken install:

```powershell
.\scripts\Pre-Install-Validation.ps1
```

The script checks and reports `[PASS]`, `[WARN]`, or `[FAIL]` for each requirement:

| Check                                       | Severity | Remediation                                     |
| ------------------------------------------- | -------- | ----------------------------------------------- |
| PowerShell 5.1+                             | FAIL     | Upgrade Windows or install PowerShell           |
| Administrator privileges                    | FAIL     | Relaunch shell as Administrator                 |
| Windows 10/11 or Server 2016+               | FAIL     | Not supported on older Windows                  |
| Windows Firewall service (`MpsSvc`) running | FAIL     | `Start-Service MpsSvc`                          |
| DNS Client service (`Dnscache`) running     | FAIL     | `Start-Service Dnscache`                        |
| Task Scheduler service (`Schedule`) running | FAIL     | `Start-Service Schedule`                        |
| Active network adapter                      | WARN     | Connect to network before installing            |
| DNS resolution working                      | FAIL     | Check upstream DNS before installing            |
| Acrylic DNS Proxy installed                 | WARN     | Installer will install it automatically         |
| Chocolatey present                          | WARN     | Installer falls back to direct Acrylic download |
| 100 MB free on C:                           | FAIL     | Free disk space before installing               |

Exit code 1 means at least one FAIL; exit code 0 with warnings means installation can proceed but optional components need attention.

### Acrylic Service Issues

Acrylic DNS Proxy is the core DNS component. If it is not running, DNS will fail for all clients on the machine.

```powershell
# Check Acrylic service state
Get-Service -DisplayName '*Acrylic*'

# Restart Acrylic and trigger a whitelist update
.\OpenPath.ps1 restart

# Or restart Acrylic alone and then trigger an update manually
Restart-Service -DisplayName '*Acrylic*'
.\OpenPath.ps1 update
```

If Acrylic fails to start, check the Acrylic configuration and host files:

```
%ProgramFiles(x86)%\Acrylic DNS Proxy\AcrylicConfiguration.ini
%ProgramFiles(x86)%\Acrylic DNS Proxy\AcrylicHosts.txt
```

An oversized or malformed `AcrylicHosts.txt` can prevent Acrylic from loading. If the file was corrupted during an update, trigger a fresh update to regenerate it:

```powershell
.\OpenPath.ps1 update
```

### DNS Does Not Resolve

```powershell
# Check Acrylic service
Get-Service -DisplayName '*Acrylic*'

# Confirm Acrylic is listening on loopback port 53
nslookup microsoft.com 127.0.0.1

# Restart Acrylic and refresh the whitelist
.\OpenPath.ps1 restart
```

If `nslookup` to `127.0.0.1` fails but Acrylic is running, the DNS client adapter may not be pointing to loopback. Check adapter DNS server addresses:

```powershell
Get-DnsClientServerAddress -AddressFamily IPv4
```

If loopback (`127.0.0.1`) is not listed for the active adapter, the firewall or DNS rules may have been reset. Run:

```powershell
.\OpenPath.ps1 update
```

### Firewall Rules Missing or Inactive

```powershell
# List all OpenPath firewall rules
Get-NetFirewallRule -DisplayName "OpenPath-DNS-*"

# Check Windows Firewall service
Get-Service MpsSvc
```

Firewall rules use the `OpenPath-DNS` prefix. If all rules are missing or the sinkhole is not active, run a full update to regenerate and reapply policy:

```powershell
.\OpenPath.ps1 update
```

### Rules Changed Upstream but Machine Did Not Update

```powershell
# Trigger an immediate update
.\OpenPath.ps1 update

# Check SSE task last run time
Get-ScheduledTaskInfo -TaskName "OpenPath-SSE"

# Check SSE task state (should be Running for the persistent listener)
Get-ScheduledTask -TaskName "OpenPath-SSE"
```

The `OpenPath-SSE` task maintains a persistent SSE connection to the API. If it is not in the `Running` state, rule changes will only be applied on the 5-minute `OpenPath-Update` schedule. Restart it:

```powershell
Start-ScheduledTask -TaskName "OpenPath-SSE"
```

### AppLocker Diagnostics

AppLocker policy is applied only when the managed browser boundary is enabled. To inspect the current policy:

```powershell
# Show current effective AppLocker policy
Get-AppLockerPolicy -Effective | Format-List

# Check AppLocker event log for recent denials
Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL" -MaxEvents 50 |
    Where-Object { $_.Id -eq 8004 } |
    Select-Object TimeCreated, Message
```

Event ID 8004 is an AppLocker block event. If a legitimate application is being blocked, verify it is installed under an IT-managed location such as `Program Files` or `Program Files (x86)`. Applications in student-writable locations (`Downloads`, `Desktop`, `Temp`) are intentionally blocked.

### Browser Doctor Report

`doctor browser` runs `Get-OpenPathBrowserDoctorReport` from `lib\Browser.psm1` and prints a structured summary of browser extension readiness, native host registration, and managed policy state:

```powershell
.\OpenPath.ps1 doctor browser
```

Common findings and their remediation:

- **Firefox native host not registered**: run `.\OpenPath.ps1 update` to trigger a full update which re-registers the native host.
- **Extension not found in staged path**: verify `browser-extension\firefox-release\` or `browser-extension\chromium-managed\` is present in `C:\OpenPath\`.
- **Managed policy missing**: run `.\OpenPath.ps1 update`; if it persists, check the browser is installed in a managed location.

### Browser Unblock Request Not Working

If the browser blocked-page UI cannot send a request, the machine may be missing the runtime dependency queue or native host connection.

```powershell
# Check RuntimeDependencyApply task last run
Get-ScheduledTaskInfo -TaskName "OpenPath-RuntimeDependencyApply"

# Inspect the runtime dependency queue directory
Get-ChildItem "C:\OpenPath\data\runtime-dependency-queue" -ErrorAction SilentlyContinue

# Check overall agent status including enrollment state
.\OpenPath.ps1 status
```

If the machine is not enrolled, re-enroll:

```powershell
.\OpenPath.ps1 enroll -ApiUrl https://api.example.com -ClassroomId <id> -EnrollmentToken <token> -Unattended
```

### Captive Portal Recovery

When the agent detects a captive portal it activates a limited-access mode and writes marker files. The recovery flow is managed by the `OpenPath-CaptivePortalRecovery` scheduled task, which is triggered by the native host when the user completes portal authentication.

**Collect a diagnostic snapshot:**

```powershell
# Quick snapshot (skips HTTP probes, faster)
.\scripts\Collect-WeduCaptivePortalDiagnostics.ps1 -Quick

# Full snapshot including HTTP probes
.\scripts\Collect-WeduCaptivePortalDiagnostics.ps1
```

The script writes a `wedu-captive-portal-diagnostics-<stamp>.json` and `.zip` to the current directory. It captures:

- DNS probes for the portal host via `127.0.0.1` and the default resolver
- DNS probes for `detectportal.firefox.com` and `www.msftconnecttest.com`
- HTTP probes (unless `-Quick`)
- Snapshots of `C:\OpenPath\data\config.json`, `captive-portal-active.json`, `captive-portal-observation.json`, `data\logs\openpath.log`, and the Acrylic configuration files
- State of `OpenPath-CaptivePortalRecovery` and `OpenPath-Watchdog` tasks

**Common captive-portal symptoms and checks:**

```powershell
# Is captive portal mode active?
Test-Path "C:\OpenPath\data\captive-portal-active.json"

# What does the active marker contain?
Get-Content "C:\OpenPath\data\captive-portal-active.json" | ConvertFrom-Json

# Check adapter DNS - portal host must resolve via the network's DHCP DNS
Get-DnsClientServerAddress -AddressFamily IPv4

# Check if the portal host resolves via the network's DNS server
# (replace 10.x.x.x with the DHCP-assigned DNS server address)
nslookup <portal-host> 10.x.x.x
```

If the portal host resolves via the network DNS but not via `127.0.0.1`, Acrylic may be forwarding to a public upstream that does not know the portal. This is the root-cause pattern described in the WEDU lab: the network's DHCP DNS server is the only resolver that knows the portal hostname.

The `OpenPath-CaptivePortalRecovery` task handles recovery automatically when portal authentication succeeds. If recovery does not complete:

```powershell
# Check the task last run
Get-ScheduledTaskInfo -TaskName "OpenPath-CaptivePortalRecovery"

# Check the recovery result files
Get-ChildItem "C:\OpenPath\data\captive-portal-recovery-result" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 3 |
    ForEach-Object { Get-Content $_.FullName | ConvertFrom-Json }
```

### Watchdog or Integrity Fallback Triggered

```powershell
.\OpenPath.ps1 health

# Check watchdog fail counter
Get-Content "C:\OpenPath\data\watchdog-fails.txt" -ErrorAction SilentlyContinue

# Check for stale failsafe state
Test-Path "C:\OpenPath\data\stale-failsafe-state.json"

# Check integrity baseline
Test-Path "C:\OpenPath\data\integrity-baseline.json"

# Search log for watchdog and integrity events
Get-Content "C:\OpenPath\data\logs\openpath.log" |
    Select-String "WATCHDOG|INTEGRITY|FAIL_OPEN|STALE_FAILSAFE|TAMPERED" |
    Select-Object -Last 30
```

A `STALE_FAILSAFE` status means the cached whitelist is stale and the agent has fallen back to a saved safe state. Run a forced update to recover:

```powershell
.\OpenPath.ps1 update
```

### Self-Update Questions

```powershell
# Check for available update without applying
.\OpenPath.ps1 self-update --check

# Apply update
.\OpenPath.ps1 self-update

# Check last agent update time from config
(Get-Content "C:\OpenPath\data\config.json" | ConvertFrom-Json).lastAgentUpdateAt
```

The `OpenPath-AgentUpdate` scheduled task runs `self-update --silent` daily at 3 am (with a random delay of up to 45 minutes).

## Useful Files

- `C:\OpenPath\data\config.json` - runtime configuration (API URL, whitelist URL, enrollment state, version)
- `C:\OpenPath\data\logs\openpath.log` - agent log
- `C:\OpenPath\data\watchdog-fails.txt` - watchdog consecutive fail counter
- `C:\OpenPath\data\stale-failsafe-state.json` - present when stale failsafe is active
- `C:\OpenPath\data\integrity-baseline.json` - integrity hashes for critical files
- `C:\OpenPath\data\integrity-backup\` - backup copies used for integrity restoration
- `C:\OpenPath\data\captive-portal-active.json` - present when captive portal mode is active
- `C:\OpenPath\data\captive-portal-observation.json` - captive portal state observation log
- `C:\OpenPath\data\runtime-dependency-queue\` - queued browser-requested dependency hosts
- `%ProgramFiles(x86)%\Acrylic DNS Proxy\AcrylicConfiguration.ini` - Acrylic configuration
- `%ProgramFiles(x86)%\Acrylic DNS Proxy\AcrylicHosts.txt` - Acrylic host overrides (generated by OpenPath)
