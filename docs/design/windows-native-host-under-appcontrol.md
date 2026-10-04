# Windows native host under the AppControl boundary

Status: implemented (Phase 5). The compiled host ships as C# source, is built on
the target machine and is registered behind a framed-ping health check; the
PowerShell/cmd host stays as the parity reference and the fallback.

## Problem

Every Firefox first visit in a classroom deployment runs with the OpenPath
non-admin AppLocker boundary installed. The boundary emits `BlockedWindowsTools`
as explicit DENY rules for the restricted SID (`OpenPath-Restricted`), including:

- `%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe`
- `%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`
- `%PROGRAMFILES%\PowerShell\7\pwsh.exe`

The registered Firefox native messaging host is launched by the browser **as
the signed-in student**, and its launcher was exactly that interpreter:

```
whitelist_native_host.json -> ...\OpenPath-NativeHost.cmd
OpenPath-NativeHost.cmd    -> powershell.exe -File OpenPath-NativeHost.ps1
```

The E1 evidence recorded by the lane (Phase 3A.3 H0) shows the deny events for
the student and no `initialization completed` line in the per-user host log,
with the managed XPI fetched and the add-on active. The lane reports
`native-host-blocked-by-appcontrol` as a product reason.

## Action inventory (complete)

Wire protocol: 4-byte little-endian length + UTF-8 JSON frames on stdin/stdout;
one persistent host process per browser session; `protocolVersion = 2`; optional
`id` echoed with its original JSON type. Framing/parse rules: `length <= 0` or
`> 1 MiB` ends the session; malformed JSON answers `{success:false, error}` and
keeps serving; a truncated frame ends the session.

| Action                                 | Request fields                                                                                           | Response fields                                                                                                                                                                                           | Files read                                                                              | Files written                                    | Processes                                                                                                                                                | Validator                                                                                         |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `ping`                                 | `id?`                                                                                                    | `success, action, message:'pong', version, protocolVersion, capabilities[]`                                                                                                                               | `native-state.json`, `data/config.json` (capability switches)                           | -                                                | -                                                                                                                                                        | none                                                                                              |
| `get-hostname`                         | `id?`                                                                                                    | `success, action, hostname`                                                                                                                                                                               | `native-state.json` (machineName, else `COMPUTERNAME`)                                  | -                                                | -                                                                                                                                                        | none                                                                                              |
| `get-machine-token`                    | `id?`                                                                                                    | `success, action, token` or `{success:false, error}`                                                                                                                                                      | `native-state.json` (`/w/<token>/` in whitelistUrl)                                     | -                                                | -                                                                                                                                                        | none                                                                                              |
| `get-config`                           | `id?`                                                                                                    | `success, action, apiUrl, requestApiUrl, fallbackApiUrls, hostname, machineToken, whitelistUrl`                                                                                                           | `native-state.json`                                                                     | -                                                | -                                                                                                                                                        | none                                                                                              |
| `get-blocked-paths`                    | `id?`                                                                                                    | `success, action, paths[], count, hash(sha256 of joined paths), mtime, source`                                                                                                                            | `whitelist.txt` (`## BLOCKED-PATHS`)                                                    | -                                                | -                                                                                                                                                        | none                                                                                              |
| `get-allowed-paths`                    | `id?`                                                                                                    | same shape (`## ALLOWED-PATHS`)                                                                                                                                                                           | `whitelist.txt`                                                                         | -                                                | -                                                                                                                                                        | none                                                                                              |
| `get-blocked-subdomains`               | `id?`                                                                                                    | `success, action, subdomains[], count, hash, mtime, source`                                                                                                                                               | `whitelist.txt`                                                                         | -                                                | -                                                                                                                                                        | none                                                                                              |
| `check`                                | `domains[]` (<= 50)                                                                                      | `success, action, results[{domain, in_whitelist, resolved_ip, policy_active, policy_decision, policy_reason, policy_version, portal_recovery_eligible, portal_recovery_signal}]`                          | `whitelist.txt`, `native-state.json`, marker/observation JSONs, config (portal domains) | -                                                | captive portal probe (HTTP, only for blocked-screen navigation / marker restore), recovery task trigger when the marker + Authenticated state require it | host data only; the SYSTEM worker applies nothing here                                            |
| `get-policy-version`                   | `id?`                                                                                                    | `success, action, version` (sha256 of `whitelist.txt` + 0x00 + `native-state.json`) or `{success:false, error:'policy-unavailable'}`                                                                      | whitelist + state                                                                       | -                                                | -                                                                                                                                                        | none                                                                                              |
| `update-whitelist`                     | `domains[]`                                                                                              | `success, action, message/error, domains[], elapsedMs` (+ runtime dependency timing fields when applicable)                                                                                               | whitelist, overlay, worker state                                                        | -                                                | `schtasks.exe /Run /TN OpenPath-Update` (only when a domain is missing)                                                                                  | SYSTEM task applies the whitelist                                                                 |
| `allow-local-runtime-dependency`       | `anchorHost, dependencyHost, requestType, mode?, id?`                                                    | `success, action, anchorHost, dependencyHost, requestType, queued, ready?, runtimeDependencyState?, requestPath?, queueWriteMs?, workerTriggered?, update*Ms, runtimeDependency*, updateTaskName, source` | whitelist, state, overlay, worker state                                                 | `data/runtime-dependency-queue/<guid>.json`      | `schtasks.exe /Run /TN OpenPath-RuntimeDependencyApply` (fallback `OpenPath-Update`) when the worker is not fresh                                        | host validates syntax + local policy; the SYSTEM worker revalidates every request before applying |
| `allow-local-runtime-dependency-batch` | `entries[]` (<= 20)                                                                                      | same per-entry results + `count, queuedCount`                                                                                                                                                             | as single                                                                               | as single                                        | as single                                                                                                                                                | as single                                                                                         |
| `check-local-runtime-dependency`       | `anchorHost, dependencyHost` or `entries[]`                                                              | `success, action, ready, runtimeDependencyState, expiresAt?` / batch `count, results[]`                                                                                                                   | overlay                                                                                 | -                                                | -                                                                                                                                                        | none                                                                                              |
| `recover-captive-portal-navigation`    | `operation('open'\|'reconcile'), triggerHost?, portalRecoveryHosts?, portalState?, source?, tabId?, id?` | `success, action, operation, state, portalModeActive, triggerHost, requestId, taskName, triggerMs, waitMs, recoveryQueueClassification, ...restore flags, allowedHosts[], ...`                            | marker, observation, result files, task scheduler                                       | `data/captive-portal-recovery-queue/<guid>.json` | `schtasks.exe /Run /TN OpenPath-CaptivePortalRecovery`                                                                                                   | SYSTEM task drives the portal transitions; the host only names allowlisted hosts                  |
| `report-extension-diagnostics`         | `events[]` (<= 50, 60 msgs/min)                                                                          | `success, action, written, dropped` (or `rateLimited:true`)                                                                                                                                               | -                                                                                       | per-user `native-host.log`                       | -                                                                                                                                                        | host sanitizer only                                                                               |
| unknown                                | any other `action`                                                                                       | `{success:false, error:'Unknown action: <action>'}`                                                                                                                                                       | -                                                                                       | -                                                | -                                                                                                                                                        | none                                                                                              |

Bootstrap: process start resolves the native root, OpenPath root, state and log
paths, writes `Native host initialization completed pid=<pid> log=<path>`, then
loops. Lazy loads (state, whitelist, config) are cheap; the captive-portal probe
module is only touched by portal/recovery flows. The compiled host performs no
script loading at all.

## Compiled host

Ship a small compiled native host (C# 5, in-box `csc.exe` v4.0.30319, only
`System.dll` besides mscorlib) whose executable lives under the OpenPath runtime
root:

- `windows/lib/AppControl.psm1` builds `$openPathRuntimePath = "$OpenPathRoot\*"`
  and adds it to `AllowPaths` / `AllowPathsByCollection` (`Exe` and `Script`) for
  the restricted SID in both the compatibility and the strict profile. A binary
  under `C:\OpenPath\...\OpenPath-NativeHost.exe` is allowed for
  `OpenPath-Restricted` while `powershell.exe` remains denied.
- Source: `windows/native-host/OpenPathNativeHost.cs`. No binaries in the repo.
- The same source compiles the parity candidate in the Windows Pester shards
  (`Windows.NativeHostParity.Tests.ps1`) and is compared action by action
  against the PowerShell host.

### Build, install, update and removal

`windows/lib/internal/NativeHost.Build.ps1` owns the lifecycle:

1. `Sync-OpenPathFirefoxNativeHostArtifacts` stages the source and the support
   files (the `.cs` is also an offline-installer payload because the manifest
   walks `windows/`).
2. `Build-OpenPathFirefoxNativeHostExecutable` computes the source sha256. If the
   manifest matches and the executable hash still matches, it skips (no compile
   on every update). Otherwise it compiles to `OpenPath-NativeHost.exe.<guid>.tmp`
   inside the protected native directory.
3. Health check: the temporary executable must answer one framed `ping` with a
   valid `pong` and `protocolVersion >= 2` before any swap.
4. Atomic swap, then `OpenPath-NativeHost.manifest.json` records source and
   executable hashes, the compiler result and `healthStatus: healthy`; build
   failures write `OpenPath-NativeHost.build.json` diagnostics.
5. `Register-OpenPathFirefoxNativeHost` points the native messaging manifest at
   the executable only through `Get-OpenPathNativeHostLaunchPath` (healthy
   manifest + matching executable hash); otherwise it keeps
   `OpenPath-NativeHost.cmd`. A failed build never leaves a manifest pointing at
   a missing or unhealthy executable.
6. Uninstall removes the executable, source, manifest, diagnostics and temp
   files; `Get-OpenPathCriticalFiles` includes the executable whenever present,
   so the integrity baseline covers it.

### Startup budget

Cold process start to a served `ping` is measured on the target VM (Framework
4.0, Windows 11 Education). The host writes a `stage=startup-profile` line with
`processToScriptMs`/`pingMs`; the lane aggregates the warm numbers. Budget:
<= 300 ms warm after the first start; cold start is measured and reported.

### Security

- Runs as the signed-in student, no new IPC (no pipes, sockets or HTTP servers);
  fixed paths under the OpenPath root.
- Strict validation before any request is queued: normalized hostnames (same
  regex as the SYSTEM worker), `requestType` shape, message-size cap, and the
  sensitive-field denylist (`url`, `headers`, `body`, `cookie`, ...). The SYSTEM
  worker revalidates every queued entry with
  `Update-OpenPathRuntimeDependencyOverlay` -> `Test-OpenPathRuntimeDependencyCandidate`.
- Captive-portal request ids are generated as 32-hex guids; the SYSTEM consumer
  rejects any other shape with `Test-OpenPathRecoveryRequestId` (path traversal
  guard, covered by `Windows.Watchdog.Tests.ps1`).
- Only fixed-argument `schtasks.exe /Run` triggers, exactly like the reference
  host. No dynamic code, no reflection, no interpreter chain.
- Smart App Control / WDAC can block an unsigned locally compiled executable.
  The host cannot ship an Authenticode signature; deployment therefore
  (a) keeps the PowerShell/cmd host as the registered fallback whenever the
  compiled binary is missing or fails health, and (b) records the SAC/WDAC state
  (`Get-OpenPathSmartAppControlState` in
  `windows/lib/internal/NativeHost.Build.ps1`) in the build diagnostics and the
  agent logs so a blocked binary is diagnosable. On machines that block
  unsigned binaries, the fallback keeps current behaviour; the long-term fix is
  signing the compiled host at build time.

## Alternatives considered and rejected

- **Allow `powershell.exe` for the restricted SID.** Reopens W-1(a). Rejected.
- **Copy `powershell.exe`/`pwsh.exe` under `C:\OpenPath`.** Same scripting-host
  surface. Rejected.
- **Move the host to `%PROGRAMFILES%`.** Explicit path denies still apply to a
  copied interpreter. Rejected.
- **Run the host in the SYSTEM session** (scheduled task + IPC). The browser
  needs the native messaging pipe in its own session. Rejected.

## Test plan

1. **Parity harness (`windows/tests/Windows.NativeHostParity.Tests.ps1`):**
   builds a fixture native root (staged support files + state + whitelist +
   config + overlay + marker) and runs the same framed sequence (all actions,
   error shapes, id echo, batch forms, recovery cases, malformed JSON, oversized
   frames) against the PowerShell reference and the compiled host; parsed
   responses must be equivalent with only timings/ids masked.
2. **Build/registration/uninstall contract tests**
   (`windows/tests/Windows.NativeHostBuild.Tests.ps1`): compile/health gating,
   manifest hash checks, fallback retention, launch-path selection, integrity
   coverage, uninstall list, and source-level security guards (no interpreter,
   no reflection, no optional assemblies).
3. **Boundary acceptance (lab, mandatory):** on an image installed with
   `enableNonAdminAppControl=true` (`StrictApplicationAllowlist`), run the host
   **as the restricted student** with a framed `ping` and assert a valid
   `pong`; assert `powershell.exe` is still denied for the same user (W-1(a)
   regression guard); assert `native-host.log` records `initialization
completed`; exercise the read actions against the served whitelist.
4. **First-visit lane:** `native-host-blocked-by-appcontrol` must disappear for
   a template that ships the compiled host, while the production template keeps
   reporting it until the fix lands.
