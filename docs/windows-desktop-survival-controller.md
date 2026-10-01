# Windows desktop-survival controller

The release qualification for Windows requires an external disposable-VM
controller that runs `tests/e2e/ci/run-windows-desktop-survival.ps1` phases
outside the guest. This document covers the Proxmox-backed controller and its
two modes: transport dry-run and release acceptance.

## Components

| Path                                                                    | Purpose                                                            |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `tests/e2e/ci/controllers/proxmox-disposable-windows-controller.ps1`    | Controller CLI implementing the `DisposableWindowsTarget` contract |
| `tests/e2e/ci/controllers/ProxmoxWindowsLab.psm1`                       | Transport-injectable orchestrator plus the real Proxmox transport  |
| `tests/e2e/ci/controllers/proxmox-disposable-windows-release-lock.ps1`  | Owner-scoped lab-lock release for cancelled workflow runs          |
| `tests/e2e/ci/desktop-survival/Invoke-OpenPathDesktopSurvivalGuest.ps1` | In-guest harness executed through the QEMU guest agent             |
| `windows/tests/Windows.ProxmoxWindowsLab.Tests.ps1`                     | Unit tests with a fake transport (no hypervisor access)            |

## Lab configuration

The inventory lives outside the repository in an operator-owned file. The CLI
reads `OPENPATH_DESKTOP_LAB_CONFIG`, defaulting to
`~/.config/openpath/desktop-survival-lab.json` (mode `0600`, never commit it).

```json
{
  "schemaVersion": 1,
  "mode": "acceptance",
  "sshHost": "<proxmox-ssh-alias>",
  "sshCommand": "ssh",
  "scpCommand": "scp",
  "hostAddress": "<proxmox-address>",
  "lockFile": "/run/openpath-desktop-survival.lock",
  "hostStagingRoot": "/var/tmp/openpath-desktop-survival",
  "httpPort": 18081,
  "timeoutSeconds": 1800,
  "restoreBaseline": true,
  "studentUserName": "alumno",
  "adminUserName": "opadmin",
  "scenarios": {
    "win11-pro-profileless-empty": {
      "vmid": 0,
      "baselineSnapshot": "<snapshot-name>",
      "expectedEditionId": "Professional",
      "initialProfileExisted": false,
      "imageIdentity": "<operator image label>"
    }
  }
}
```

- `mode: "transport-dry-run"` performs artifact transport and boot-id checks
  only. Observations are marked `dryRun: true` / `acceptanceEligible: false`
  and can never qualify a release.
- `mode: "acceptance"` runs the full matrix below and emits release-eligible
  evidence (`synthetic: false`, compatibility AppControl identity, boundary probes,
  rollback verification).
- `restoreBaseline` defaults to `true`. Set it to `false` only when the target
  VM holds a snapshot chain that must not be touched; the controller then never
  rolls back and only stops the VM during cleanup.
- `guestSecret` is optional. When absent the controller generates a per-run
  credential and rotates the two lab accounts inside the disposable guest.

## Acceptance matrix

The suite runs four scenarios through the controller, sequentially, each against
its own baseline snapshot:

| Scenario                            | Edition      | Student profile at baseline |
| ----------------------------------- | ------------ | --------------------------- |
| `win11-pro-profileless-empty`       | Professional | absent                      |
| `win11-pro-existing-empty`          | Professional | present and empty           |
| `win11-education-profileless-empty` | Education    | absent                      |
| `win11-education-existing-empty`    | Education    | present and empty           |

Per scenario the controller performs:

- **prepare**: restore baseline, boot, verify guest/edition, transport the exact
  template and personalized candidate (hash-verified on the host and inside the
  guest), upload the in-guest harness, install the candidate as SYSTEM, and
  record the AppLocker policy hash before and after the compatibility commit.
  Prepare fails closed when the committed policy lacks the Everyone `%WINDIR%`
  Windows runtime base: the Window Manager (`DWM.EXE`) and font driver
  (`FONTDRVHOST.EXE`) run as service SIDs that are neither administrators nor
  SYSTEM, so that gap denies them at every boot and no interactive session can
  come up.
- **observe**: enable the admin autologon, reboot, capture the admin desktop,
  enable the student autologon, reboot, require a real first student interactive
  logon (Security 4624 type 2/10) and capture the student desktop, then run the
  restricted-student boundary probes and fixture checks in the student's
  interactive session.
- **afterReboot**: clear autologon, reboot, capture the login screen, then
  repeat the admin and student interactive sessions and the boundary probes
  after the reboot.
- **cleanup**: run the installed `Uninstall-OpenPath.ps1`, verify that the
  runtime, the restricted group, the scheduled tasks and the OpenPath AppLocker
  rules are gone, stop the VM and restore the baseline. The VM is stopped and
  rolled back in a `finally` block even when a guest cleanup step fails, so a
  dead guest never stays powered on while the next scenario waits for the lock.

When an interactive-session wait expires, the controller captures a
`session-timeout-<phase>-<step>` console screendump and a bounded
`session-timeout-<phase>-<step>.diagnostics.json` (session list, explorer
owners, memory, non-informational AppLocker events from the four channels, and
the watchdog log tail). The phase error carries the last per-attempt error and
references both artifacts.

Since Phase 3A the lock protocol is implemented once in
`tests/e2e/ci/controllers/proxmox-lab-lock.sh`: `owner` + `created` +
`heartbeat`, staleness decided **only** by the heartbeat age, a live lock is
waited for instead of being stolen, and every replacement records the previous
owner in `<lock_dir>.replacements.log`. Manual sessions renew their heartbeat
with `proxmox-lab-lock.ps1`; see
[`docs/windows-first-visit-lab.md`](windows-first-visit-lab.md#lab-lock-phase-3a-g3).

A cancelled workflow run releases its lab lock through
`proxmox-disposable-windows-release-lock.ps1`, which only releases lock owners
that belong to the current run/attempt and never touches another run's lock.
The lock is a remote directory (`lockFile`, for example
`/run/openpath-desktop-survival.lock`) whose `created` and `owner` files are
written per phase by `EnsureLock`; a lock whose `created` timestamp is older
than the config's `timeoutSeconds` (default 1800 s) is stale and is deleted
when the next acquisition attempts it. Later runs also reclaim a dead run's
lock before the Windows Desktop Survival phases start: the workflow step
`Reclaim lab lock from finished runs` runs the same script with
`-ReclaimFinishedOwners`, which reads the current owner and reclaims it only
when it has the canonical `<runId>/<runAttempt>/<scenario>` shape and the
owning workflow run is no longer active. An earlier attempt of the current run
belongs to a cancelled or failed attempt and is reclaimed like any finished
owner, so a re-run clears its own leftover lock; the current attempt is treated
as active. Owners from manual lab sessions, still-active runs, and the current
attempt are left untouched, and an unknown run state fails closed as active.

The scenario object required by
`scripts/lib/windows-desktop-survival-evidence.mjs` is attached to the cleanup
observation; every phase observation carries `synthetic: false`, the run
identity, the source commit and the correlation nonce.

## Boundary probes and fixtures

Probes run as the restricted student in the student's interactive session
through a one-shot scheduled task (`/it`), and each probe records whether the
process actually started:

| Fixture                | Probe                                      | Expected                   |
| ---------------------- | ------------------------------------------ | -------------------------- |
| `exeAndDll`            | approved browser (Firefox)                 | allowed                    |
| `exeAndDll`            | in-box signed Win32 binary (`charmap.exe`) | allowed                    |
| -                      | unapproved browser (Edge)                  | denied                     |
| -                      | user-writable executable copy              | denied                     |
| `msiAndScript`         | user-writable PowerShell script            | denied (marker absent)     |
| -                      | user-writable MSI package (raw evidence)   | unmanaged in compatibility |
| `packagedAppExecution` | in-box packaged app (`calc.exe`)           | allowed                    |

`criticalUnexpectedDenials` must remain empty: an approved surface that is
denied, or a denied surface that runs, fails the phase. Probe evidence records
non-informational AppLocker events from the EXE and DLL, MSI and Script, and
Packaged app-Execution channels.

## Controller contract

`DisposableWindowsTarget` invokes the controller once per phase:

```text
-PayloadPath -OutputPath -Mode Prepare|Observe|AfterReboot|Cleanup
-RunId -RunAttempt -ScenarioId -CorrelationNonce
```

Exit codes: `0` passed (correlated observation written), `1` phase failed,
`2` `BLOCKED_PLATFORM_VALIDATION` (missing lab configuration, unmapped scenario,
unsupported mode, transport unavailable). A bare exit `2` is never accepted as
blocked: the adapter requires a correlated blocked observation on disk.

## Running a dry-run

```powershell
$env:OPENPATH_DESKTOP_LAB_CONFIG = "$HOME/.config/openpath/desktop-survival-lab.json"
$controller = "$PWD/tests/e2e/ci/controllers/proxmox-disposable-windows-controller.ps1"
foreach ($mode in 'Prepare', 'Observe', 'AfterReboot', 'Cleanup') {
    pwsh -NoProfile -File tests/e2e/ci/run-windows-desktop-survival.ps1 `
        -Mode $mode -RunId 'dryrun-<timestamp>' -RunAttempt 1 `
        -ScenarioId 'win11-pro-profileless-empty' -ArtifactsRoot '<evidence-root>' `
        -TemplatePath '<template.exe>' -PersonalizedExePath '<personalized.exe>' `
        -ControllerCommand $controller `
        -ControllerPayloadPath '<evidence-root>/<run>/1/<scenario>/controller-payload.json'
}
```

Artifacts are downloaded from the exact CI run being qualified:

```sh
gh run download <run-id> -R balejosg/OpenPath --name windows-offline-template --dir <dir>
gh run download <run-id> -R balejosg/OpenPath --name windows-personalized-http-candidate --dir <dir>
```

The adapter transports `templatePath/templateSha256` and
`personalizedExePath/personalizedExeSha256` into the controller payload; the
controller re-verifies the bytes locally and again inside the guest.

## Verification

```powershell
Invoke-Pester -Path windows/tests/Windows.ProxmoxWindowsLab.Tests.ps1
Invoke-Pester -Path windows/tests/Windows.DisposableWindowsTarget.Tests.ps1
```

The unit tests never touch a hypervisor. The real transport is exercised only
by the operator dry-run or acceptance run against an authorized disposable VM.
