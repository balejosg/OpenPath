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
Get-ScheduledTaskInfo -TaskName "OpenPath-RuntimeDependencyWorker"
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

The reported black screen has no demonstrated cause in this repository. Do not
label `dwm`, `winlogon`, or another process causal from temporal proximity alone.
Capture local/effective policy and events first. Policy health is not GUI or
reboot evidence; those claims require the authorized disposable-VM harness.

Strict AppControl also reports transaction state. `appcontrol_transaction_busy`
means another OpenPath operation owns the machine lock;
`appcontrol_recovery_required` means a prepared/apply/rollback journal is
incomplete or invalid. Do not retry by widening strict rules or deleting the
journal. Inspect state files under
`C:\OpenPath\data\appcontrol-transactions`, preserve their hashes, and use the
central recovery operation. A `committed` config field without a corresponding
validated journal is not proof of a successful transition.

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

User-scoped AppLocker rules apply to the local `OpenPath-Restricted` group, which the installer keeps in sync with all enabled non-administrator local users. Local administrators are not members and are exempt.

**Administrator blocked by AppLocker (event 8004 on an admin session):** check whether the admin account is a member of `OpenPath-Restricted`:

```powershell
Get-LocalGroupMember -Group 'OpenPath-Restricted' | Select-Object Name, SID
```

The watchdog sync only adds members and never removes them, so a manually added admin stays until removed. Remove the admin from the group with `Remove-LocalGroupMember -Group 'OpenPath-Restricted' -Member '<admin-user>'`, or reinstall to rebuild the group. A fresh install also recreates the group if it was deleted by hand.

**Restricted group missing:** the watchdog attempts to recreate and synchronize
`OpenPath-Restricted`. The historical `BUILTIN\Users` fallback does not establish
healthy current targeting. Failed synchronization or post-repair verification
keeps health non-healthy. From an elevated shell with the AppControl module
loaded, inspect group membership and the effective policy before retrying
`Sync-OpenPathRestrictedGroup -CreateIfMissing $true`.

AppControl observations are available from
`Get-OpenPathNonAdminAppControlHealth`. Inspect `Healthy`, `ReasonCodes`, and
the individual policy/runtime booleans. A running `AppIDSvc` alone is not proof
of enforcement. OpenPath supports Group Policy AppLocker; effective-policy
inspection does not include CSP policy, and CSP-only management cannot satisfy
this health contract.

Health reports also carry a bounded `reasonCodes` array, alongside the legacy
`actions` text. For example, `appcontrol_effective_policy_invalid` identifies an
invalid effective boundary, while `watchdog_task_missing`,
`watchdog_task_disabled`, and `watchdog_task_not_runnable` identify scheduling
problems. These codes contain no usernames, paths, tokens, or exception text.
`status` observes the required boundary without repairing it; `health` runs the
watchdog's repair cycle and must verify the result before reporting healthy.
A missing watchdog cannot send its own heartbeat: server-side stale-report
detection remains necessary even when the last received report was healthy.

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
# Check the resident worker and its fallback task
Get-ScheduledTask -TaskName "OpenPath-RuntimeDependencyWorker"
Get-ScheduledTaskInfo -TaskName "OpenPath-RuntimeDependencyWorker"
Get-ScheduledTaskInfo -TaskName "OpenPath-RuntimeDependencyApply"

# Worker heartbeat (updated every few seconds while the worker runs)
Get-Content "C:\OpenPath\data\runtime-dependency-worker-state.json" -ErrorAction SilentlyContinue

# Per-user native host log: message timing, queue writes, readiness marks
Get-Content "$env:LOCALAPPDATA\OpenPath\native-host.log" -Tail 60 -ErrorAction SilentlyContinue

# Inspect the runtime dependency queue directory
Get-ChildItem "C:\OpenPath\data\runtime-dependency-queue" -ErrorAction SilentlyContinue

# Check overall agent status including enrollment state
.\OpenPath.ps1 status
```

The `OpenPath-RuntimeDependencyWorker` task is the fast path: it applies learned
dependencies in-process and heartbeats. If it is not `Running`, the native host
falls back to triggering `OpenPath-RuntimeDependencyApply` through Task
Scheduler (slower cold start) and the watchdog restarts the worker within a
minute. When investigating first-visit failures, check the heartbeat freshness
first, then the native host log stages (`stage=queue-written`,
`stage=worker-fresh`, `stage=readiness-observed`) against the fast-apply
metrics line in `C:\OpenPath\data\logs\openpath.log`
(`detectedQueueFiles=`, `dnsFlushMs=`, `dnsFlushOk=`, `appliedGeneration=`,
`mirrorSynced=`, `mirrorSyncMs=`).

Worker states in `runtime-dependency-worker-state.json`:

- `lastResult: "starting"` -- process up, no batch applied yet.
- `lastResult: "applying"` with `busySince` / `busyStage: "queue" |
"iteration-N" | "acrylic-reload" | "dns-flush" | "generation-stamp"` -- a
  batch is in flight. The native host treats a busy mark younger than 120 s as
  alive, so long batches do not trigger a duplicate schtasks apply.
- `lastResult: "applied"` / `"apply-failed"` / `"error"` with `lastApplyMs` and
  `lastError` -- outcome of the last batch.
- `heartbeatAt` / `heartbeatEpochMs` -- idle heartbeat (every few seconds);
  older than 10 s with no recent `busySince` is treated as a dead worker.

Per-iteration readiness markers in `openpath.log`:

- `Runtime dependency fast apply detected N queue file(s)` -- detection point.
- `Runtime dependency fast apply iteration N staged ready in X ms` -- the
  iteration's entries are ready at that moment (per-entry generations).
- `overlay generation stamped: appliedGeneration=N` -- the reload + DNS flush
  completed for that generation.
- `Acrylic configuration unchanged; skipping rewrite` / `AcrylicHosts.txt
unchanged; skipping rewrite` -- the hot path skipped redundant file writes.

Non-blocking (`mode: "enqueue"`) requests answer immediately with the per-entry
state; the per-user native host log records
`stage=queue-written ... mode=enqueue workerTriggered=true|false` when the
resident worker was not alive and the scheduled apply task had to be nudged.

Persistent native transport (Phase 2C):

- The Firefox background keeps one native host process per browser session
  (`connectNative`) instead of one process per message. The first `ping`
  advertises `protocolVersion` and `capabilities`; an old host (no
  capabilities) is served one-shot exactly as before.
- The per-user native host log no longer records one line per poll. Expect
  `stage=chatty-aggregate action=check-local-runtime-dependency count=N` once
  per minute (or per 500 messages) and a
  `stage=runtime-dependency-ready-transition` line the first time a dependency
  becomes ready in a session. Missing per-message lines are intentional.
- To roll the new transport back without touching the browser extension, set
  the retirement switch in `C:\OpenPath\data\config.json`:
  `"runtimeDependencyPersistentTransportDisabled": true` (or a string
  `"true"`). The host then stops announcing `runtime-dependency-enqueue` and
  `runtime-dependency-auto-reload`; restart Firefox so it re-probes. Linux uses
  `/etc/openpath/runtime-dependency-persistent-transport.conf` containing
  `disabled`.
- If a page reloads once by itself shortly after first loading a site, that is
  the single automatic reload that repairs a cancelled render-blocking resource
  (`script`/`stylesheet`/`font`) once the agent applies its exception. It never
  reloads twice for the same navigation and is skipped for POST navigations,
  stale navigations, the blocked screen and captive-portal flows.

### Compiled native host (Phase 5)

On installed machines the registered native messaging host is the compiled
`OpenPath-NativeHost.exe` (C# source `windows\native-host\OpenPathNativeHost.cs`),
because the classroom AppLocker boundary denies `powershell.exe`/`pwsh.exe` to
the restricted student. The PowerShell/cmd host remains as the fallback.

```powershell
# What is registered (path field): .exe = compiled host, .cmd = fallback
Get-Content 'C:\OpenPath\browser-extension\firefox\native\whitelist_native_host.json' -Raw

# Build manifest: source/executable hashes and health state
Get-Content 'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.manifest.json' -Raw

# Build diagnostics when the compiled host is unavailable
Get-Content 'C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.build.json' -Raw

# Force a rebuild (update recompiles when the source hash changed)
.\OpenPath.ps1 update

# Smart App Control / WDAC can block an unsigned locally compiled binary:
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue
Get-ChildItem "$env:WINDIR\System32\CodeIntegrity\CiPolicies\Active" -ErrorAction SilentlyContinue
```

The compiled host is only registered after a framed `ping` health check; a
compile or health failure keeps the previous host (executable or `.cmd`) and
writes `OpenPath-NativeHost.build.json` with the compiler output and the
Smart App Control state. The per-user log still starts with
`Native host initialization completed pid=...`, and the startup profile line
(`stage=startup-profile ... processToScriptMs= pingMs=`) reports the cold and
warm start budgets.

Protocol parity between both hosts is enforced by
`windows\tests\Windows.NativeHostParity.Tests.ps1` (framed reference sequence
against the PowerShell host and the compiled host, same fixture state).

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

### Runtime Dependency First-Visit Latency

The browser extension learns page dependencies (CDN hosts) through the native
host and the resident worker. Three log signals (Phase 2D) bound the first-visit
latency; read them before touching timeouts:

- **Native host startup profile** - the per-user native host log
  (`%LOCALAPPDATA%\OpenPath\native-host.log`) contains one line per host process:

  ```
  stage=startup-profile processToScriptMs=... loadsMs=state:...,actions:... pingMs=... firstEnqueueMs=... firstEnqueueAtMs=...
  ```

  - `processToScriptMs`: powershell.exe start to script start (cold process cost).
  - `loadsMs`: per-file dot-source/Import-Module times. Only the hot-path files
    (state, protocol, actions, runtime dependency policy/queue/overlay,
    redaction) should appear here; `RequestSetup`, `TaskRunner` and the captive
    portal support files load on demand and must not show up.
  - `pingMs`: process start to the first answered `ping` (target: <= 1.5 s on a
    settled system, <= 3.5 s freshly installed or at boot).
  - `firstEnqueueMs`: handler time of the first runtime dependency enqueue
    (target <= 150 ms; it must look like the second one).

- **Worker prewarm** - `openpath.log` contains:

  ```
  Runtime dependency worker prewarm stage=prewarm ms=... dnsFlushTypeMs=... sectionsMs=... policySetsMs=... overlayMs=... acrylicRenderMs=... ready=...
  ```

  It runs once at worker start. A large `dnsFlushTypeMs` means the Add-Type
  compile moved back onto the first flush; a large `policySetsMs`/`overlayMs`
  means the whitelist/protected sets or the overlay read are cold again.

- **Queue detection age** - the worker logs the oldest queue file age when it
  notices a batch:

  ```
  Runtime dependency worker detected 6 queue file(s) queueFileAgeMs=123
  ```

  `queueFileAgeMs` is measured from the queue file's last write to detection and
  should stay within ~300 ms. A larger value means the FileSystemWatcher event
  was missed (the loop falls back to its 250 ms sweep) or the worker process was
  starved; check CPU load with the worker pid (`Get-Process -Id <pid>`).

The native host port itself is persistent and does not break on a slow call: the
extension only reconnects after a real disconnect or when a liveness `ping`
times out with the host silent for 15 s. If dependency requests suddenly start
paying the per-request one-shot host cost again, look for
`Native host port disconnected` in the native host log and for the agent config
switch `runtimeDependencyPersistentTransportDisabled` in
`C:\OpenPath\data\config.json`.

#### Dependency learning while an update runs (Phase 7)

The startup update and the dependency fast apply share the Acrylic state. Two
locks split the responsibilities:

- `Global\OpenPathUpdateLock` serializes update **cycles** only (a second trigger
  exits with `Another OpenPath update is already running - skipping this cycle`);
- `Global\OpenPathAcrylicWriteLock` (writers lock) serializes the shared writers:
  the whitelist write, the native-host mirror, the overlay and AcrylicHosts/INI.
  The update takes it in short scopes; the fast apply takes it for its own apply
  and stamp.

Log lines to read, in order:

```
OpenPath update stage=<name> ms=<n> lock=cycle          # per-stage breakdown of the cycle
OpenPath update writers scope=<stage> ms=<n>            # how long the writers lock was held
Runtime dependency fast apply waited <n> ms for the Acrylic writers lock
Runtime dependency worker waiting 37 s for the Acrylic writers lock (retries=...)
OpenPath update stamped runtime dependency overlay appliedGeneration=N
```

- a short `fast apply waited` is normal (the update's write scopes are tens of
  milliseconds); a wait in the seconds means the writers lock is stuck: check for
  a long `writers scope=` line or a fast apply holding it while Acrylic restarts;
- `Runtime dependency worker waiting ...` is the escalation warning and only
  appears after 30 s of continuous contention; before that the worker just
  retries (it never drops a batch);
- the update stamps the overlay generation it applied only after its repair plan
  restarted Acrylic and flushed the DNS client cache; the fast apply then only
  confirms the generation. A redundant Acrylic restart after an update means the
  hosts write decision did not see equivalent content: check for
  `AcrylicHosts.txt effective content unchanged; skipping rewrite` (the
  `# Generated:` header is ignored on purpose).
- A whole-VM pause (hypervisor) shows up as the same >2 s gap in the guest
  sampler (`stall-samples.json` in the lab evidence) and is classified
  `vm-stall`; it is infrastructure, not the product.

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
