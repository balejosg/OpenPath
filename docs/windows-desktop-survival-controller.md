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
  evidence (`synthetic: false`, strict AppControl identity, boundary probes,
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
  record the AppLocker policy hash before and after the strict commit.
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
  rules are gone, stop the VM and restore the baseline.

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
| `msiAndScript`         | user-writable MSI package                  | denied (1625 policy block) |
| `packagedAppExecution` | unapproved packaged app (`calc.exe`)       | denied                     |

`criticalUnexpectedDenials` must remain empty: an approved surface that is
denied, or a denied surface that runs, fails the phase.

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
