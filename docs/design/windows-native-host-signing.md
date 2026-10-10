# Windows native host signing (Phase 8 design)

> Status: maintained
> Applies to: `windows/native-host/`, the offline installer payload, the Native
> Host Signing workflow and the classroom Smart App Control deployments
> Last verified: 2026-10-10
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
- The publisher pin (`Get-OpenPathNativeHostSignaturePin`) is **empty until
  Phase 8.1**; an empty pin fails closed with `signature-pin-not-configured`,
  the product compiles and records
  `signatureRejectedReason`/`signature-pin-not-configured`.
- A valid signed executable is copied to a temporary path, health-pinged as
  SYSTEM and swapped atomically (same path as the compiled host). The build
  manifest records `hostSource = 'signed-prebuilt'`; a rejected candidate never
  executes. A valid candidate for the current source also clears the
  compilation backoff because no compilation is involved.

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

| #   | Condition                                                                                                                     | Status                              | Evidence / gap                                                                                                                                                                                                                                                                                        |
| --- | ----------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | No malware                                                                                                                    | Met                                 | AGPL-3.0 classroom enforcement tool; no offensive tooling.                                                                                                                                                                                                                                            |
| 2   | OSI-approved license without commercial dual-licensing                                                                        | Met                                 | `LICENSE` (AGPL-3.0).                                                                                                                                                                                                                                                                                 |
| 3   | No proprietary components                                                                                                     | Met                                 | All sources in this repository; upstream payloads (Acrylic, Firefox ESR) are separate OSS and are not signed by us.                                                                                                                                                                                   |
| 4   | Maintained                                                                                                                    | Met                                 | Continuous development; public releases.                                                                                                                                                                                                                                                              |
| 5   | Released in the form to be signed                                                                                             | Met                                 | Windows offline installer and scripts releases exist; the signed host travels in them.                                                                                                                                                                                                                |
| 6   | Documented                                                                                                                    | Met                                 | `README.md`, `docs/`, release assets.                                                                                                                                                                                                                                                                 |
| 7   | Only own projects/binaries                                                                                                    | Met                                 | The signed executable is compiled from `windows/native-host/OpenPathNativeHost.cs` in this repository.                                                                                                                                                                                                |
| 8   | No hacking tools ("no fight the system")                                                                                      | Met                                 | Enforcement and diagnostics only; no vulnerability scanning/exploit features.                                                                                                                                                                                                                         |
| 9   | Privacy: describe, show during install, allow disabling transfer                                                              | Partially met - **decision needed** | The agent transfers data only to the administrator-configured server (enrollment, whitelist, health). README + `firefox-extension/PRIVACY.md` describe it. The installer does not _display_ the privacy policy; adding an install-time notice/prompt is a product change the maintainer must approve. |
| 10  | Announce system changes                                                                                                       | Met                                 | The installer documents its changes (DNS, firewall, browser policies, scheduled tasks) in `windows/DEPLOYMENT.md`.                                                                                                                                                                                    |
| 11  | Provide uninstallation                                                                                                        | Met                                 | `windows/Uninstall-OpenPath.ps1` + `uninstall.sh`.                                                                                                                                                                                                                                                    |
| 12  | MFA for SignPath and repository                                                                                               | Maintained by the user              | GitHub account-level.                                                                                                                                                                                                                                                                                 |
| 13  | Roles: Authors / Reviewers / Approvers                                                                                        | Met (documented)                    | README "Code signing policy" section; currently the maintainer (@balejosg) holds all three.                                                                                                                                                                                                           |
| 14  | Code signing policy on the home page with the exact sentence and roles                                                        | Met                                 | `README.md#code-signing-policy`.                                                                                                                                                                                                                                                                      |
| 15  | Privacy policy linked from the policy                                                                                         | Met                                 | README privacy section + `firefox-extension/PRIVACY.md`.                                                                                                                                                                                                                                              |
| 16  | Artifact configuration enforces product name/version                                                                          | Prepared (user-side)                | The assembly metadata (`AssemblyProduct=OpenPath`, `AssemblyVersion`/`AssemblyFileVersion`/`AssemblyInformationalVersion`) is pinned in the `.cs`; the SignPath artifact configuration with metadata restrictions must be created by the user after admission.                                        |
| 17  | All jobs before the request on GitHub-hosted runners                                                                          | Met                                 | The signing workflow only uses `windows-latest`.                                                                                                                                                                                                                                                      |
| 18  | Artifact uploaded with `actions/upload-artifact`, submitted by `signpath/github-action-submit-signing-request` by artifact id | Met                                 | Workflow steps + `tests/repo-config/native-host-signing-contracts.test.mjs`.                                                                                                                                                                                                                          |
| 19  | Each signing request approved manually; the wait must not block REL/CI                                                        | Met                                 | Dedicated workflow; bounded collect; REL/CI never wait.                                                                                                                                                                                                                                               |
| 20  | Product name attributes "OpenPath", one product version per build                                                             | Met                                 | `.cs` assembly attributes (contract-tested).                                                                                                                                                                                                                                                          |

Ongoing obligations: one approval per new source hash (the workflow reuses the
signed pair otherwise), and keeping the policy page (README) current.
