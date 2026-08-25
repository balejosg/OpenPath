# Windows Offline Installer Capability

> Status: maintained
> Applies to: OpenPath API and Windows agent
> Last verified: 2026-08-25
> Source of truth: `api/src/services/windows-offline-installer-artifact.service.ts`

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

It returns `200` with the executable only when the reference is valid, the
artifact exists, and its size and SHA-256 match the database record. It returns:

| Condition                                         | Status |
| ------------------------------------------------- | -----: |
| Missing or malformed `ref`                        |  `400` |
| Unknown reference                                 |  `404` |
| Expired, exhausted, or already consumed reference |  `410` |

Successful responses include `Content-Type: application/octet-stream`, an
attachment `Content-Disposition` filename, `Cache-Control: no-store`,
`X-Content-Type-Options: nosniff`, and `Content-Length`. The bounded attempt is
reserved before opening the file, but the reference is consumed only after the
complete stream finishes. An interrupted transfer therefore retains its
remaining retry budget; a complete download is removed from the private
artifact directory.

## Pinned template and storage

Provision the exact template before starting API traffic. There is no request-
time `latest` lookup, branch resolution, or GitHub fetch. The immutable template
root and writable artifact root must be separate:

```text
<templateDir>/<version>/<commit>/OpenPath-Windows-Setup-Template.exe
<templateDir>/<version>/<commit>/OpenPath-Windows-Setup-Template.exe.sha256
<artifactsDir>/<opaque-derived-name>.exe
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

Provisioning downloads only the exact configured GitHub release asset and its
sidecar, verifies the digest, and publishes atomically. `--verify-only` is
local-only and never fetches or repairs files. API startup performs the local
readiness check after migrations and before listening; health reports the
capability as `not_configured`, `ok`, or a safe error code. Readiness never
provisions or repairs the template and caches a verified hash by file identity.

## UI and wrapper integration

The OpenPath SPA exposes `WindowsOfflineInstallerAction` through the public SPA
surface. The Windows option is first in the enrollment modal. Generation starts
only after the user clicks the visible download action; the page does not mount
with an automatic download or persistent `href`. After generation the user can
click the link to download the `.exe`, see version/hash/expiry metadata, retry a
failed generation, and use the PowerShell fallback when appropriate. Strings and
error states are localized in English and Spanish.

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

For target-platform evidence, run the read-only PowerShell helper on a Windows
runner with the generated executable. It validates the trailer, classroom ID,
optional API URL, and file hash; it does not install or modify the machine unless
`-Install` is explicitly supplied:

```powershell
pwsh -NoProfile -File .\tests\e2e\ci\run-windows-offline-installer-canary.ps1 `
  -ExecutablePath .\OpenPath-Aula-1-Windows-Setup.exe `
  -ExpectedClassroomId '<classroom-id>' `
  -ExpectedApiUrl 'https://api.example.test'
```

Do not report target-platform evidence from local Linux tests alone. The local
contract and HTTP tests prove the API lifecycle; a Windows runner is required to
claim that the generated installer executes on Windows.
