# Windows native host signing (Phase 8 design)

> Status: maintained
> Applies to: `windows/native-host/`, the offline installer payload, the Native
> Host Signing workflow and the classroom Smart App Control deployments
> Last verified: 2026-10-13
> Source of truth: this document

## Problem

Windows Smart App Control (SAC) blocks unsigned executables. The compiled
Firefox native messaging host (`OpenPath-NativeHost.exe`) is built on the target
machine with the in-box .NET Framework compiler, so it is unsigned and SAC
denies it. With SAC enforced before installation the host never runs: Firefox
path/subdomain rules fail open, the request-access screen and approval
propagation stop working, runtime dependency learning is unavailable and
captive portal recovery has no bridge. The Phase 7 SAC lane reproduced the chain
end to end (`native_host_smart_app_control_blocked`).

OpenPath uses the free **SignPath Foundation** open-source signing program
(OV-level Authenticode; the visible publisher is _SignPath Foundation_). The
team applies for admission; until the project is accepted nothing is signed and
the product keeps working with a visible "SAC active, not supported" warning.

## Decision (Phase 8e, 2026-10-13): signing parked; SAC off is the requirement

No signing request has been made (confirmed with the maintainer on 2026-10-12)
and SignPath is not viable in the short term, so the channel stays implemented
but dormant (`native-host-signing.yml` compiles, uploads unsigned and ends with
a visible warning; the empty publisher pin fails closed). OpenPath instead
**requires Smart App Control (SAC) off** on classroom machines, and the
installer offers that as an explicit administrator decision (setup dialog,
`/DisableSmartAppControl`, `-DisableSmartAppControl`; see
`windows/DEPLOYMENT.md`, "Smart App Control"). Verified facts behind the
decision:

1. Microsoft Support, "App & browser control": "Smart App Control won't block
   anything while it's in evaluation mode"; Windows then turns it on or off by
   itself, and once decided (or changed by hand) it cannot return to evaluation
   without reinstalling or resetting Windows.
2. Clean Windows 11 Pro/Education installations start in evaluation ("In most
   cases Smart App Control will automatically turn on"); in organization-managed
   devices SAC "switches off within 48 hours" (Microsoft Support).
3. Microsoft Support, "What is Smart App Control": "There is currently no way
   to bypass Smart App Control protection for individual apps."
4. Microsoft Learn (App Control, updated 2026-10-08): an organization disables
   SAC with `VerifiedAndReputablePolicyState` (DWORD) `0` under
   `HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy` and then `CiTool.exe -r`;
   it can be re-enabled later without reinstalling.
5. With SAC enforced, the freshly compiled host is blocked (4551) (Phase 7
   product log; Phase 8/8b SAC scenes). An executable that already ran kept
   running for minutes; long-term behavior is not measured. With SAC enforced
   the positive control oscillates (blocked for minutes, allowed for others),
   so it is not an instant oracle; with SAC off nothing must be blocked.
6. Acrylic 2.2.1 (the pinned `Acrylic-Portable.zip`, sha256 `26a5601c...`) has
   no Authenticode signature on `AcrylicService.exe`, `AcrylicConsole.exe` or
   `AcrylicUI.exe`; in the 8b SAC scene it still ran with SAC on, probably by
   cloud reputation - not guaranteed.

What signing would add if it is ever obtained: a host that runs with SAC on
(per-app trust instead of a machine-wide posture change) and no dependency on
the administrator disabling SAC. H1 also shows the limit of the "signature
fixes it" reading: the Phase 8d health-ping failure was a UTF-8 preamble in
front of the frame (see the H1 section below), not a signing problem, and a
signed prebuilt receives the same preamble.

### Prepared signing policy (draft for a future application)

The text below was the README "Code signing policy" until Phase 8e. It is kept
here, as a draft, for a future SignPath application:

> **Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).**
>
> OpenPath uses the SignPath Foundation open-source code signing program for
> exactly one artifact: the compiled Windows native messaging host
> (`OpenPath-NativeHost.exe`) that the Windows agent installs under the
> browser-extension runtime root.
>
> - **What is signed:** only `OpenPath-NativeHost.exe`, built from
>   `windows/native-host/OpenPathNativeHost.cs` in this repository.
> - **How it is built:** the Native Host Signing workflow compiles the source
>   with the in-box .NET Framework compiler on GitHub-hosted runners, uploads
>   the executable as a GitHub Actions artifact and submits it to SignPath by
>   artifact id. Every signing request is approved manually by an Approver.
> - **What is not signed:** installers, scripts, the API and the browser
>   extension (the extension is signed separately through AMO).
> - **Roles:** Authors, Reviewers and Approvers - [@balejosg](https://github.com/balejosg).

## The signing channel (implemented in Phase 8)

`.github/workflows/native-host-signing.yml`:

1. Runs only on `main`, only on GitHub-hosted runners (all jobs), never on
   pull requests, and only with the `code-signing` environment.
2. Computes `sourceSha256 = sha256(windows/native-host/OpenPathNativeHost.cs)`.
3. Looks for `OpenPath-NativeHost-<sourceSha256>.exe` plus its `.signing.json`
   on the rolling `native-host-signing` release. **One signature per source
   hash**: when the pair exists the workflow stops without compiling or
   submitting, so manual approvals stay rare.
4. Otherwise compiles the C# source with the same function and compiler
   options the product uses, uploads the executable with
   `actions/upload-artifact@v7` and submits it to SignPath through
   `signpath/github-action-submit-signing-request` pinned by commit SHA, with
   `wait-for-completion: false`.
5. Collects the signed artifact with a bounded wait (SignPath PowerShell module
   `Get-SignedArtifact`), verifies `Get-AuthenticodeSignature` is `Valid` with a
   timestamp countersignature and publishes the pair on the rolling release
   with `--clobber` (idempotent). A timed-out collect is recoverable without a
   new approval: dispatch the workflow with the existing `signing_request_id`.
6. Without the secret/variables the workflow compiles, uploads the unsigned
   artifact, skips the signature with a visible warning and ends green.
7. The collect step installs the SignPath PowerShell module at one exact pinned
   version and reads the token and organization id from the environment; no
   `secrets.*` expression is interpolated into a `run:` script (Phase 8b R4).

Storage: the rolling GitHub release `native-host-signing`. Actions artifacts
expire; a release asset does not, and only the workflow creates it (the tag is
`native-host-signing`, outside the `v*` stable-tag namespace).

### Where the signed executable goes

| Channel                                                                   | Carries the signed host?                                                                                                                                                                                         |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Offline installer template (`windows-vX` template exe + payload manifest) | Yes: `scripts/fetch-native-host-signed-artifact.mjs` stages `windows/native-host/signed/` before the payload manifest is built; the manifest records `nativeHostSigned` and the file enters the `payloads` list. |
| `windows-v<version>.zip` scripts package                                  | Yes: the same staging step runs before the zip is created.                                                                                                                                                       |
| API self-update (`api/src/lib/server-asset-windows.ts`)                   | No change: it publishes the `.cs` source only. The signed executable is an install-time payload, not an update payload.                                                                                          |
| `OpenPath-AgentUpdate` scheduled task                                     | No: it downloads the update bundle built from the repo tree; on offline installs the staged `native-host/signed/` files are already on disk.                                                                     |

### Product-side verification (fail closed)

`windows/lib/internal/NativeHost.Build.ps1`:

- `Find-OpenPathNativeHostSignedCandidate` locates
  `native-host\signed\OpenPath-NativeHost.exe` + `.signing.json`. The **primary
  anchor is the payload manifest** (`payload-manifest.json` entry for
  `native-host/signed/OpenPath-NativeHost.exe`); when an offline install ships a
  manifest without that entry the candidate is rejected. Without a payload
  manifest (development checkouts, scripts zip) the staging metadata hash
  anchors the check.
- `Test-OpenPathNativeHostSignedExecutable` requires: sha256 == anchor hash,
  Authenticode `Valid`, a timestamp countersignature, signer subject and issuer
  equal to the pin, and the pinned description when one is declared.
- The publisher pin (`Get-OpenPathNativeHostSignaturePin`) is **empty until a
  signing channel is activated** (Phase 8e: parked, see the decision above); an
  empty pin fails closed with `signature-pin-not-configured`,
  the product compiles and records
  `signatureRejectedReason`/`signature-pin-not-configured`.
- A valid signed executable is copied to a temporary path, health-pinged as
  SYSTEM and swapped atomically (same path as the compiled host). The build
  manifest records `hostSource = 'signed-prebuilt'`; a rejected candidate never
  executes. A valid candidate for the current source also clears the
  compilation backoff because no compilation is involved.

### Smart App Control first execution and the retry backoff (Phase 8b)

With SAC, an unsigned executable's **first execution** decides whether it may
run at all. During a permissive window the launch succeeds and the decision
sticks per file hash; otherwise the kernel denies CreateProcess with the
AppControl 4551 error ("An Application Control policy has blocked this file").
The SAC lane reproduced both outcomes across a single scene (the positive
control flips between checkpoints), so a single first ping is not a stable
signal.

Product response (all in `NativeHost.Build.ps1`):

- A failed ping that is a `health-check-timeout` or the 4551 launch denial is
  retried **once inside the same ensure** with a longer timeout (45 s instead
  of 20 s; `pingAttempts = 2` in `OpenPath-NativeHost.build.json`). This covers
  the one-time CI evaluation and the non-repeatable first-launch denial; the
  previous healthy executable stays installed while the retry runs.
- When the retry also fails, the backoff depends on the cause:
  health failures grow 5 -> 15 -> 60 minutes (`healthAttempts`), compilation /
  source / unexpected failures keep a steady hour. After three health failures
  the schedule is one attempt per hour - never a compile loop - and a success
  or a new source hash resets the counters.
- A retry only helps if something retries: each **periodic** update cycle (the
  `OpenPath-Update` task every 5 minutes), the daily agent self-update task and
  install/enrollment call the `Invoke-OpenPathFirefoxNativeHostCompiledEnsure`
  entrypoint under that backoff. A healthy host costs a source hash and a
  manifest read (`BuildSkipped`). Phase 8c moved the cycle call out of the
  update lock and stopped the SSE cycles from calling it (see below).
- `Browser.psm1` re-exports `Invoke-OpenPathFirefoxNativeHostCompiledEnsure`
  and `Get-OpenPathFirefoxNativeHostCompiledHealth`: while they were private to
  `Browser.FirefoxNativeHost.psm1`, the `Get-Command`-guarded consumers (agent
  self-update, watchdog health report, installer SAC notice) silently skipped
  them.

### Hashing, host placement and SAC measurement (Phase 8c)

The E2E run 38144922322 showed the compiled host _healthy_ (`BuildSkipped`,
PID 7236) while the same machine's `build.json` ended `status=Failed`,
`attempts=16`, error "The term 'Get-FileHash' is not recognized", plus a false
`Restricted student users have no native host` ERROR. Cause: the forced update
runs as a Windows PowerShell 5.1 child of a pwsh 7 process, so it inherited
PowerShell 7's `PSModulePath`; `Get-FileHash` (Microsoft.PowerShell.Utility)
was not auto-loaded and the source hash failed before any compile, once per
harness cycle, with no backoff.

Product response:

- `Get-OpenPathNativeHostFileSha256` hashes the file stream with
  `System.Security.Cryptography.SHA256` (lowercase hex, same result as
  `Get-FileHash`) and every native host call site uses it
  (`NativeHost.Build.ps1`, `Browser.FirefoxNativeHost.psm1`); the command's
  availability is irrelevant. An unreadable source hash counts as one failed
  attempt per backoff hour (`native-host-source-hash-failed`).
- The ensure no longer runs inside `Global\OpenPathUpdateLock`: the periodic
  cycle calls `Invoke-OpenPathNativeHostPostCycleEnsure` after releasing the
  lock, and the stage line reads
  `OpenPath update stage=native-host ms=<n> lock=released`. SSE cycles never
  call the ensure; with the H1 shape (compile + 20 s + 45 s) an SSE approval
  used to wait 45 s on the lock and skip its cycle. All ensure callers share a
  non-blocking mutex (`Global\OpenPathNativeHostEnsureLock`): the loser logs
  "another ensure is already running" and skips.
- SAC windows oscillate (blocked right after apply -> both controls run minutes
  later -> blocked again) and `csc` is not deterministic: the same source
  produced hashes `ad79...` and `5f58...` in one scene, and SAC evaluates each
  executable on first launch. A recompile under the backoff can still recover a
  blocked host by chance, which is why the Phase 8e decision makes SAC
  **off** a deployment requirement instead of relying on a signature
  (`windows/DEPLOYMENT.md`, "Smart App Control").

### Manifest reconciliation, ping diagnosis and H1 (Phase 8d)

The Phase 8c E2E (38208889929) also showed a product gap independent of the
hash: the ensure recompiled the host but never touched
`whitelist_native_host.json`, which only `Register-OpenPathFirefoxNativeHost`
writes. After an install whose health ping failed, the manifest kept pointing at
the `.cmd` fallback; Firefox launched `powershell.exe`, AppLocker denied it for
the restricted student and the classroom stayed without a native host until a
new enrollment or agent version, even after the executable had recovered. The
same run proved the Phase 8c "0 no-host errors" count was measured on the last
200 log lines only (~1 minute of the run), so a real denial could hide.

Product response:

- The ensure (all callers, under its mutex) calls
  `Sync-OpenPathFirefoxNativeHostMessagingManifest` after the build attempt with
  any outcome: an existing manifest whose `path` no longer matches
  `Get-OpenPathNativeHostLaunchPath` is rewritten atomically (temp file plus
  move, no BOM) and the previous and new destinations are logged. A missing
  manifest is never created; the registry is untouched.
- Every compilation path shares the one non-blocking mutex: the installer,
  enrollment and self-update compile through
  `Invoke-OpenPathFirefoxNativeHostRegistrationBuild`; when the lock is held
  they skip the compile and write the manifest with the current launch path.
- `Test-OpenPathNativeHostExecutable` drains stderr asynchronously from launch,
  stops at a 0-byte stdout read (`health-check-exited` with the exit code) and
  records `StartMs`, `ElapsedMs`, `Pid`, `HasExited`, `ExitCode`, `CpuMs` and a
  redacted 2 KB stderr extract. `build.json` keeps the last two attempts under
  `lastPings` and each failed ping logs one WARN line.
- A failed health attempt is classified from that data: `exited` (exit code and
  stderr), `hung-no-cpu` (alive without CPU: blocked before managed code -
  kernel, antivirus or Code Integrity; check the CodeIntegrity/Defender events
  of the window) or `hung-cpu` (alive with CPU: host bug; check its
  native-host.log). The runner's clean first-execution exit (code 0, empty
  stderr, no CodeIntegrity/Defender event) is **not** a first-execution
  anomaly: Phase 8e H1 proved it is the UTF-8 preamble that .NET Framework's
  `Process.StandardInput` writes when the console input code page is 65001
  (`header=efbbbf22`). Both hosts discard one preamble at the start of stdin
  and the clean exit is no longer retried (Phase 8e E0.4).
- The E2E harness reports the final state from the complete `openpath.log` (with
  rotations), the manifest destination, the product health (child
  `Get-OpenPathFirefoxNativeHostCompiledHealth` with the machine PSModulePath,
  file fallback), `lastPings` and `fallback-state.json`, and emits a visible
  `::warning` when the classroom boundary is active and the student ends without
  the compiled host. It also collects the SYSTEM native-host.log, the native
  host lines of the full log, the CodeIntegrity/Defender events and a first-run
  probe (fresh copy of the installed source, 180 s then 30 s ping). The lane's
  `host-recovery` scene reproduces the failed-install state, keeps a student
  Firefox session and requires the periodic task to recover the manifest within
  6 minutes with a passing student probe; on the pre-8d template it is
  PRODUCT-RED.

### Installer signing: options

The offline template is personalized at download time
(`api/src/lib/windows-offline-installer-template.ts` changes bytes in the
appended trailer), which invalidates a signature placed on the template as a
whole. Options considered:

| Option                                       | How it works                                                                                                                      | Verdict                                                                                                                                                                                                                                                                                         |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| (a) Authenticode _tagging_                   | Sign the template and write the personalization into a data region the signature does not cover.                                  | Only viable if the 8.1 experiment below confirms the signature survives on Windows. Cheap if it works (single signed exe, unchanged UX); unsafe to assume: Authenticode validation may reject data appended after the certificate table, and the failure mode is silent on non-Windows tooling. |
| (b) Signed exe + adjacent configuration file | Ship the signed, unpersonalized setup exe and the personalization as a file beside it (download becomes a folder or a small zip). | **Recommended default.** No signature invalidation by construction; compatible with SignPath (one approval per installer release, not per download). Cost: the download UX changes from a single exe to an exe + config pair.                                                                   |
| (c) Per-download server-side signing         | Sign each personalized download on the server.                                                                                    | Rejected: SignPath requires a manual approval per signing request, so per-download signing is operationally impossible.                                                                                                                                                                         |

**Recommendation:** (b), unless the (a) experiment below succeeds and the team
prefers keeping the single-file UX. The experiment must be run on a Windows
machine with the actual template (it cannot be executed from the Linux
workspace):

1. Sign `OpenPath-Windows-Setup-Template.exe` with a test certificate.
2. `Get-AuthenticodeSignature` (same signer shown) and `signtool verify /pa`.
3. Append the trailer placeholder / personalize it exactly as the API does.
4. Re-run both checks: the signature must still verify with the **same
   signer**, otherwise (a) is discarded.

### If SignPath rejects the project

The product keeps the Phase 8 behavior: SAC active is not supported, with the
installer warning and the `native_host_smart_app_control_blocked` reason code.
Free alternatives:

- Ship the host per student? No: the boundary needs a machine-scoped
  executable; per-user copies are still unsigned.
- Redesign so the extension talks to the SYSTEM agent over loopback (no
  native-messaging executable for the student): a new architecture with its own
  security analysis (local HTTP on loopback, authentication between the
  extension and the agent, sandbox implications). Not analyzed further here.
- Use another free signing program (SignPath is currently the only free OV
  Authenticode channel for OSS; any alternative must be evaluated with the same
  "built from this repo on hosted runners" requirement).

## SignPath Foundation compliance (as of 2026-10-10)

Every condition from <https://signpath.org/terms.html> (condition, status,
evidence). Gaps that need a product decision are marked **decision needed**.

| #   | Condition                                                                                                                     | Status                 | Evidence / gap                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --- | ----------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | No malware                                                                                                                    | Met                    | AGPL-3.0 classroom enforcement tool; no offensive tooling.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| 2   | OSI-approved license without commercial dual-licensing                                                                        | Met                    | `LICENSE` (AGPL-3.0).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| 3   | No proprietary components                                                                                                     | Met                    | All sources in this repository; upstream payloads (Acrylic, Firefox ESR) are separate OSS and are not signed by us.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 4   | Maintained                                                                                                                    | Met                    | Continuous development; public releases.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| 5   | Released in the form to be signed                                                                                             | Met                    | Windows offline installer and scripts releases exist; the signed host travels in them.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| 6   | Documented                                                                                                                    | Met                    | `README.md`, `docs/`, release assets.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| 7   | Only own projects/binaries                                                                                                    | Met                    | The signed executable is compiled from `windows/native-host/OpenPathNativeHost.cs` in this repository.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| 8   | No hacking tools ("no fight the system")                                                                                      | Met                    | Enforcement and diagnostics only; no vulnerability scanning/exploit features.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 9   | Privacy: describe, show during install, allow disabling transfer                                                              | Met (Phase 8c)         | SignPath terms: "Software that collects user data and transfers it to systems not specified by the user must a) describe this behavior in a privacy policy, b) display this policy during installation and c) include installation options to disable these functions". The OpenPath agent transfers data **only to the server the installer specifies** (enrollment, whitelist sync, health reports and student requests), never to third parties, so the condition does not require a disable option; the `privacy-notice` phase shown by the installer (and recorded in the product log for unattended installs) is informative. README `#privacy` + `firefox-extension/PRIVACY.md` describe the transfers. The notice also names the Acrylic DNS Proxy payload, downloaded from its SourceForge open-source release when the package does not bundle it. |
| 10  | Announce system changes                                                                                                       | Met                    | The installer documents its changes (DNS, firewall, browser policies, scheduled tasks) in `windows/DEPLOYMENT.md`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| 11  | Provide uninstallation                                                                                                        | Met                    | `windows/Uninstall-OpenPath.ps1` + `uninstall.sh`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| 12  | MFA for SignPath and repository                                                                                               | Maintained by the user | GitHub account-level.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| 13  | Roles: Authors / Reviewers / Approvers                                                                                        | Met (documented)       | README "Code signing policy" section; currently the maintainer (@balejosg) holds all three.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 14  | Code signing policy on the home page with the exact sentence and roles                                                        | Met                    | `README.md#code-signing-policy`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| 15  | Privacy policy linked from the policy                                                                                         | Met                    | README privacy section + `firefox-extension/PRIVACY.md`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| 16  | Artifact configuration enforces product name/version                                                                          | Prepared (user-side)   | The assembly metadata (`AssemblyProduct=OpenPath`, `AssemblyVersion`/`AssemblyFileVersion`/`AssemblyInformationalVersion`) is pinned in the `.cs`; the SignPath artifact configuration with metadata restrictions must be created by the user after admission.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| 17  | All jobs before the request on GitHub-hosted runners                                                                          | Met                    | The signing workflow only uses `windows-latest`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| 18  | Artifact uploaded with `actions/upload-artifact`, submitted by `signpath/github-action-submit-signing-request` by artifact id | Met                    | Workflow steps + `tests/repo-config/native-host-signing-contracts.test.mjs`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 19  | Each signing request approved manually; the wait must not block REL/CI                                                        | Met                    | Dedicated workflow; bounded collect; REL/CI never wait.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| 20  | Product name attributes "OpenPath", one product version per build                                                             | Met                    | `.cs` assembly attributes (contract-tested).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |

Ongoing obligations: one approval per new source hash (the workflow reuses the
signed pair otherwise), and keeping the policy page (README) current.
