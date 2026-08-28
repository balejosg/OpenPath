# Windows Offline Installer Capability

> Status: maintained
> Applies to: OpenPath API and Windows agent
> Last verified: 2026-08-28
> Source of truth: `api/src/routes/windows-offline-installer.ts`,
> `api/src/services/windows-offline-installer-download-refs.service.ts`,
> `api/src/services/windows-offline-installer-artifact.service.ts`, and
> `api/src/services/windows-offline-installer-provision.service.ts`

OpenPath provides a generic, authenticated way to create a personalized Windows
offline installer. A caller with teacher access to a classroom uses the public
tRPC procedure, receives safe metadata, and follows the short-lived download URL:

```text
Classroom -> Enroll -> Windows -> Download Windows installer (.exe)
```

OpenPath owns the template, payload format, artifact lifecycle, authorization,
and download route. A wrapper may provide the surrounding classroom UI, but it
must call the public SPA/tRPC surface and must not import API internals or add
OpenPath concepts for a particular SaaS product.

## Public API contract

Authenticated teachers call:

```text
POST /trpc/windowsOfflineInstaller.generate
Authorization: Bearer <access-token>
Content-Type: application/json

{"classroomId":"<classroom-id>"}
```

The success response contains only this metadata:

```json
{
  "fileName": "OpenPath-Aula-1-Windows-Setup.exe",
  "version": "4.1.0",
  "sha256": "<64 lowercase hex characters>",
  "tokenExpiresAt": "2026-08-25T12:00:00.000Z",
  "downloadUrl": "https://api.example.test/api/windows-offline-installer/download?ref=<opaque-reference>",
  "downloadExpiresAt": "2026-08-25T10:10:00.000Z"
}
```

Every generation creates a new opaque reference. The response never exposes a
filesystem path, raw enrollment token, JWT, internal credential, or template
location. Existing authentication, classroom authorization, and enrollment
ticket primitives remain the source of authorization and enrollment data.

The binary route is:

```text
GET /api/windows-offline-installer/download?ref=<opaque-reference>
```

The route validates request syntax before it looks up a reference. It returns
`200` with an attachment only when the reference is valid, the artifact exists,
and its size and SHA-256 match the database record:

| Condition                            |           Status | Meaning                                                          |
| ------------------------------------ | ---------------: | ---------------------------------------------------------------- |
| Missing `ref`                        |            `400` | Request syntax error; no reference lookup is performed.          |
| Malformed `ref`                      |            `400` | Request syntax error; no reference lookup is performed.          |
| Unknown, well-formed `ref`           |            `404` | The opaque reference does not exist in storage.                  |
| Invalid, well-formed `ref`           |            `404` | The stored reference cannot be resolved as a usable reference.   |
| Expired `ref`                        |            `410` | Terminal state of a reference that was previously valid.         |
| Exhausted `ref`                      |            `410` | Terminal state after the bounded attempt budget was used.        |
| Consumed `ref`                       |            `410` | Terminal state after a complete transfer consumed the reference. |
| Valid `ref` with a verified artifact | `200 attachment` | The executable is streamed with download headers.                |

Missing or malformed values are syntactic request errors. Unknown or invalid
well-formed values are references that cannot be found or resolved. Expired,
exhausted, and consumed values are terminal states of a previously valid
reference. If a valid reference points to a missing or mismatched personalized
artifact, the route fails closed with `404 Installer artifact unavailable`; that
artifact-integrity failure is separate from the reference-state mapping above.

Successful responses include `Content-Type: application/octet-stream`, an
attachment `Content-Disposition` filename, `Cache-Control: no-store`,
`X-Content-Type-Options: nosniff`, and `Content-Length`. The bounded attempt is
reserved before opening the file, but the reference is consumed only after the
complete stream finishes. An interrupted transfer releases its active-transfer
slot while retaining the reference's remaining bounded retry budget; the
interrupted attempt is still counted. Concurrent transfers are allowed when
they already reserved distinct attempts within that budget. The first complete
transfer makes the reference consumed (`410` for later requests), while any
already-active bounded transfers may finish; the last completion removes the
artifact from the private directory. Active transfers use expiring leases, so a
restart can recover abandoned reservations without allowing a slow legitimate
stream to be deleted early. Cleanup removes consumed, expired, and exhausted
references only after their leases are gone. The maintenance lifecycle runs
once before the API listens and periodically while it lives; it passes
`OPENPATH_WINDOWS_OFFLINE_ARTIFACT_RETENTION_HOURS` to the orphan scan. Recent
unreferenced files remain within that bounded retention window, while older
personalized artifacts are removed. The template root is never scanned.

`GET /health` is liveness only and remains `200` while a dependency is degraded.
`GET /ready` is the deployment readiness endpoint: it returns `200` only when
the configured capability and dependencies are ready, otherwise `503`. Its
response contains status codes only, never filesystem paths, tokens, or secrets.

## Pinned template and storage

Provision the exact template before starting API traffic. There is no request-
time `latest` lookup, branch resolution, or GitHub fetch. The immutable template
root and writable artifact root are separate. The private artifact root contains
personalized files such as:

```text
<artifactsDir>/<opaque-derived-name>.exe
```

The published template uses this layout inside the exact version/commit
directory:

```text
<templateDir>/<version>/<commit>/
  .current
  generations/
    generation-<uuid>/
      OpenPath-Windows-Setup-Template.exe
      OpenPath-Windows-Setup-Template.exe.sha256
      OpenPath-Windows-Setup-Template.exe.provenance.json
```

Required configuration is documented in
[`ENVIRONMENT_VARIABLES.md`](ENVIRONMENT_VARIABLES.md). The important pins are
the exact template version, full commit SHA, release tag, and SHA-256 digest.
TTL and retry settings are bounded by the API configuration parser: enrollment
tokens are at most 24 hours, download references at most 60 minutes and 10
attempts, and artifact retention at most seven days.

Provision or verify the cache from the OpenPath repository:

```bash
npm run provision:windows-offline-installer --workspace=@openpath/api
npm run provision:windows-offline-installer --workspace=@openpath/api -- --verify-only
```

Provisioning first resolves the exact GitHub tag to its exact full source commit,
then downloads only the exact configured release assets and sidecar, verifies
the expected and actual SHA-256 values, and writes the local provenance manifest
into a staging directory on the template volume. The complete bundle is
validated before it becomes visible. Each published generation is immutable and
contains the executable, its `.sha256` sidecar, and its `.provenance.json`
manifest together.

After validation, staging is renamed to a complete
`generations/generation-<uuid>/` directory on the same filesystem. The
provisioner writes `.current` through a temporary pointer file whose textual
content names exactly one generation, syncs it, and atomically renames it over
`.current` in the same version/commit directory. Replacing `.current` is the
single observable publication commit. Readers resolve that pointer and load the
executable, sidecar, and provenance only from the selected generation; they
never combine files from different generations.

If preparation of a new generation fails, the existing `.current` pointer is
not replaced or removed, so a previously valid generation remains valid. If a
pointer replacement fails before it commits, the same fallback applies. If no
valid generation has been published yet, the loader remains unavailable and
API/readiness fail closed. A later explicit provisioning run can publish a new
complete generation; it does not repair a published bundle by replacing its
`.exe`, `.sha256`, and `.provenance.json` files independently. The RW
provisioner rejects symlinked template paths. The API maintenance process never
scans or writes the template root because its supported volume is `:ro`.

`--verify-only` is local-only: it does not download, provision, repair, clean up,
or mutate files. It verifies the configured pointer and complete published
bundle. API startup performs the local readiness check after migrations and
before listening; readiness reads the published state, caches required file
identities, and fails closed for a missing, malformed, or incomplete pointer or
bundle. Readiness never provisions or repairs the template.

If a process crashes during publication, a staging root, a temporary `.current`
pointer, or a non-current generation may remain. On a later normal provisioning
pass, stale staging roots and pointer files, abandoned non-current generations,
and reclaimable publish locks are eligible for bounded-age cleanup; the current
generation is preserved. If `.current` is missing or malformed, cleanup
conservatively preserves generations rather than guessing which one to publish,
and API/readiness continue to fail closed until a valid publication exists. This
is recovery/cleanup of abandoned filesystem entries, not a promise of rollback
or automatic repair.

### Standalone Docker deployment

The supported standalone deployment runs the provisioning job before the API:

```bash
export PUBLIC_URL=https://openpath.example.test
export OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION=4.1.0
export OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT=<40-lowercase-hex-commit>
export OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256=<64-lowercase-hex-digest>
export OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG=scripts-v4.1.0-<commit-prefix>
export OPENPATH_WINDOWS_OFFLINE_ARTIFACT_RETENTION_HOURS=24
docker compose -f api/docker-compose.yml up
```

The compose contract uses `/app/var/windows-offline-installer/templates` as the
shared template root and `/app/var/windows-offline-installer/artifacts` as the
private artifact root. The one-shot provisioner mounts the template volume
read-write, provisions and verifies the exact pin, and must complete before the
API starts. The API mounts the template volume read-only (`:ro`) and the
artifacts volume read-write with a private runtime-user-only root; both are
named persistent volumes. `PUBLIC_URL` and all four template pins are required
by compose so a public deployment cannot
silently start with an unusable offline-installer action.

## UI and wrapper integration

The OpenPath SPA exposes `WindowsOfflineInstallerAction` through the public SPA
surface. The Windows option is first in the enrollment modal. Generation starts
only after the user clicks the visible download action; the page does not mount
with an automatic download or persistent `href`. Each explicit click generates
a fresh reference and immediately starts that download through an ephemeral
anchor; the reference is never left reusable in the DOM. The user can see
version/hash/expiry metadata, retry a failed generation, and use the PowerShell
fallback when appropriate. Strings and error states are localized in English
and Spanish.

## Canary and Windows evidence

The authenticated API canary checks generation, `200` attachment download, byte
hash, and replay `410` within two seconds. It never prints the access token,
reference, URL, or response payload:

```bash
OPENPATH_CANARY_BASE_URL=https://api.example.test \
OPENPATH_CANARY_ACCESS_TOKEN='<redacted>' \
OPENPATH_CANARY_CLASSROOM_ID='<classroom-id>' \
npm run canary:windows-offline-installer
```

The release workflow also runs the real executable lane on an isolated Windows
runner. It customizes the template, launches the personalized NSIS executable
unattended, validates the extracted payload manifest and pending DPAPI state,
then starts a local HTTPS enrollment fixture and calls the existing retry path.
This is the evidence required to claim that the generated `.exe` executes; it
does not introduce a second Windows runtime.

The automatic Release Installation Scripts workflow runs the end-to-end
HTTP-to-EXE lane in a separate fresh `windows-personalized-http-e2e` Windows
job after the pinned template artifact is built. It starts the real API and
PostgreSQL, creates a classroom, generates a fresh artifact/reference,
downloads the executable through the download route, verifies the response and
SHA-256, asserts replay `410`, and passes that downloaded file to the physical
executable lane. The separate runner is intentional: the existing physical
installer test changes Windows policy, so it must not affect the process that
starts the HTTP-to-EXE test. Only safe status, size, hash, and boolean evidence
is uploaded; credentials and references stay in process memory.

For quick target-platform evidence, the read-only PowerShell helper validates the
trailer, classroom ID, optional API URL, and file hash. It does not install or
modify the machine unless `-Install` is explicitly supplied:

```powershell
pwsh -NoProfile -File .\tests\e2e\ci\run-windows-offline-installer-canary.ps1 `
  -ExecutablePath .\OpenPath-Aula-1-Windows-Setup.exe `
  -ExpectedClassroomId '<classroom-id>' `
  -ExpectedApiUrl 'https://api.example.test'
```

The real release lane can be invoked from the repository root after the Windows
template build has produced a personalized executable:

```powershell
pwsh -NoProfile -File .\tests\e2e\ci\run-windows-offline-installer-exe.ps1 `
  -ExecutablePath .\OpenPath-Classroom-Windows-Setup.exe `
  -ExpectedClassroomId '<classroom-id>' `
  -ExpectedApiUrl 'https://localhost:18443' `
  -EvidencePath .\windows-offline-installer-exe-evidence.json
```

Do not report target-platform evidence from local Linux tests alone. The local
contract and HTTP tests prove the API lifecycle; the release Windows executable
lane is required to claim that the generated installer executes on Windows.
