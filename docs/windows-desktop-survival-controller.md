# Windows desktop-survival controller (transport dry-run)

The release qualification for Windows requires an external disposable-VM
controller that runs `tests/e2e/ci/run-windows-desktop-survival.ps1` phases
outside the guest. This document covers the Proxmox-backed controller and its
phase-1 scope: transport, protocol, exact-artifact transfer and correlated
observations.

Phase 1 is **not** release evidence. Acceptance still requires the four-scenario
Windows 11 Professional/Education matrix with interactive desktop probes,
externally observed login screens and a full install/reboot/uninstall cycle.
Observations produced here are marked `dryRun: true` and `acceptanceEligible:
false`, so `scripts/validate-windows-desktop-survival-evidence.mjs` rejects
them by construction.

## Components

| Path                                                                 | Purpose                                                            |
| -------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `tests/e2e/ci/controllers/proxmox-disposable-windows-controller.ps1` | Controller CLI implementing the `DisposableWindowsTarget` contract |
| `tests/e2e/ci/controllers/ProxmoxWindowsLab.psm1`                    | Transport-injectable orchestrator plus the real Proxmox transport  |
| `windows/tests/Windows.ProxmoxWindowsLab.Tests.ps1`                  | Unit tests with a fake transport (no hypervisor access)            |

## Lab configuration

The inventory lives outside the repository in an operator-owned file. The CLI
reads `OPENPATH_DESKTOP_LAB_CONFIG`, defaulting to
`~/.config/openpath/desktop-survival-lab.json` (mode `0600`, never commit it).

```json
{
  "schemaVersion": 1,
  "mode": "transport-dry-run",
  "sshHost": "<proxmox-ssh-alias>",
  "sshCommand": "ssh",
  "scpCommand": "scp",
  "hostAddress": "<proxmox-address>",
  "lockFile": "/run/openpath-desktop-survival.lock",
  "hostStagingRoot": "/var/tmp/openpath-desktop-survival",
  "httpPort": 18081,
  "timeoutSeconds": 1800,
  "restoreBaseline": true,
  "scenarios": {
    "win11-pro-profileless-empty": {
      "vmid": 0,
      "baselineSnapshot": "<snapshot-name>",
      "expectedEditionId": "Professional",
      "initialProfileExisted": false
    }
  }
}
```

`restoreBaseline` defaults to `true`. Set it to `false` only when the target VM
holds a snapshot chain that must not be touched; the controller then never rolls
back and only stops the VM during cleanup.

## Controller contract

`DisposableWindowsTarget` invokes the controller once per phase:

```text
-PayloadPath -OutputPath -Mode Prepare|Observe|AfterReboot|Cleanup
-RunId -RunAttempt -ScenarioId -CorrelationNonce
```

Exit codes: `0` passed (correlated observation written), `1` phase failed,
`2` `BLOCKED_PLATFORM_VALIDATION` (missing lab configuration, unmapped scenario,
acceptance mode, transport unavailable). A bare exit `2` is never accepted as
blocked: the adapter requires a correlated blocked observation on disk.

Per-phase behaviour:

- **Prepare**: acquire lock, validate local artifacts against the payload
  identity, boot the VM (optional baseline restore), record OS identity and boot
  id, publish both artifacts over temporary HTTP staging, download them in the
  guest and verify SHA256 there.
- **Observe**: require the prepared state, unchanged boot id, guest readiness
  and guest artifact hashes.
- **AfterReboot**: request a reboot, require a different boot id, capture a
  console screendump and re-verify guest artifacts.
- **Cleanup**: always remove host/guest staging, stop the VM, release the lock;
  restore the baseline only when `restoreBaseline` is enabled.

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
by the operator dry-run against an authorized disposable VM.
