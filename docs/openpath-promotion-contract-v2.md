# OpenPath Promotion Contract v2

> Status: maintained
> Applies to: OpenPath release producers and downstream consumers
> Last verified: 2026-08-30
> Source of truth: the v2 contract published on the OpenPath `gh-pages` branch

Promotion Contract v2 is the one authoritative answer to the question "which
OpenPath artifact set is valid for this exact OpenPath commit?". A consumer may
use OpenPath only when the contract at the exact URL below exists:

```text
https://raw.githubusercontent.com/balejosg/openpath/gh-pages/promotion-contracts/v2/<FULL_OPENPATH_SHA>.json
```

There is no branch, latest, current, or ancestor fallback. A missing contract
for the requested SHA means that SHA is not promoted for v2 consumption.

## Contract shape

The canonical serializer emits this field order and two-space JSON indentation:

```json
{
  "schemaVersion": 2,
  "openpathSha": "<40 lowercase hex characters>",
  "openpathVersion": "<VERSION>",
  "interfaces": {
    "wrapperIntegration": 1,
    "windowsOfflineInstaller": 1,
    "readiness": 1
  },
  "components": {
    "linuxAgent": {
      "sourceSha": "<40 lowercase hex characters>",
      "inputsSha256": "<64 lowercase hex characters>",
      "packageName": "openpath-dnsmasq",
      "packageVersion": "<Packages Version>",
      "aptSuite": "stable",
      "filename": "<exact Packages Filename>",
      "sha256": "<physical .deb SHA-256>"
    },
    "windowsOfflineInstaller": {
      "sourceSha": "<40 lowercase hex characters>",
      "inputsSha256": "<64 lowercase hex characters>",
      "version": "<VERSION at sourceSha>",
      "releaseTag": "scripts-v<version>-<git-short-sha>",
      "templateAsset": "OpenPath-Windows-Setup-Template.exe",
      "templateSha256": "<physical template SHA-256>",
      "payloadManifestAsset": "payload-manifest.json",
      "payloadManifestSha256": "<physical manifest SHA-256>"
    },
    "browserPolicy": {
      "sourceSha": "<40 lowercase hex characters>",
      "inputsSha256": "<64 lowercase hex characters>",
      "firefoxExtensionVersion": "<manifest version>",
      "browserPolicySpecSha256": "<physical policy spec SHA-256>"
    }
  }
}
```

`sourceSha` identifies the commit that produced that component. It may be an
ancestor of `openpathSha` when OpenPath has proved that the component inputs
are unchanged. The public interface numbers are protocol versions, not product
versions:

- `wrapperIntegration` covers the generic promotion-contract consumption
  boundary.
- `windowsOfflineInstaller` covers the template, trailer, payload manifest,
  sidecar, and download/verification expectations.
- `readiness` covers the public readiness contract consumed by platform
  integrations.

Increment an interface number only for an incompatible public-contract change.
No downstream product, tenant, institution, deployment, or service name belongs
in this schema.

## Deterministic and immutable bytes

`scripts/openpath-promotion-contract.mjs` is the canonical v2 validator and
serializer. It rejects unknown fields, volatile metadata, malformed hashes,
unsupported interface versions, and a Windows tag that is not a prefix of its
component `sourceSha`.

The authoritative JSON contains no timestamps, workflow IDs, runner IDs,
attempts, or publication metadata. CI evidence may contain those values outside
the contract. Identical logical inputs therefore produce identical bytes.

Publication uses only the exact SHA path:

```text
missing file                         -> create
existing file with identical bytes  -> success, idempotent
existing file with different bytes  -> fail closed
```

The publisher opens a new file with exclusive creation and never replaces an
existing contract. Corrections require a new OpenPath commit and a new SHA-keyed
contract.

## Canonical release-input fingerprints

`scripts/openpath-release-inputs.mjs` is the only component-input definition.
It inventories sorted POSIX-relative paths and hashes each path, byte length,
and file bytes with a versioned SHA-256 framing. Directory enumeration order,
file timestamps, and runner identity do not affect the result.

The current inventories are:

- `linuxAgent`: `VERSION`, root package manifests, release/build actions and
  Debian workflows, `linux/debian-package/`, `linux/lib/`,
  `linux/libexec/`, `linux/scripts/runtime/`, the browser-policy spec, and the
  Firefox source/build inputs used by the Debian package.
- `windowsOfflineInstaller`: `VERSION`, root package manifests, the release
  actions/workflow, `windows/` except generated
  `windows/offline-installer/build/`, `runtime/`, and the Firefox
  source/build inputs used by the template.
- `browserPolicy`: `VERSION`, package/build orchestration inputs, the browser
  policy spec, `linux/lib/`, `windows/lib/`, and the Firefox source/build inputs
  that participate in browser-policy behavior.

Generated `node_modules`, extension `dist`, and installer build outputs are not
inventoried as source inputs. Their reproducibility is covered by the source,
build configuration, pins, packaging scripts, and workflow inputs that produce
them. A relevant source, script, manifest, packaging, pin, or orchestration
change therefore changes the corresponding fingerprint; unrelated repository
documentation does not.

## Component inheritance

Inheritance is an OpenPath release decision. The publisher finds the previous
v2 contract only by walking the first-parent history of the requested OpenPath
SHA and looking for an exact SHA-keyed file on `gh-pages`.

For each component independently:

```text
current inputsSha256 == previous inputsSha256
    -> copy the previous complete component, including its sourceSha

current inputsSha256 != previous inputsSha256
    -> inheritance is forbidden
    -> require current physical evidence and a complete current component
```

The top-level `openpathSha` and `openpathVersion` always describe the requested
commit. A first v2 bootstrap has no trusted predecessor and therefore requires
complete physical Linux and Windows evidence plus the current browser-policy
source verification. Consumers never perform this comparison and never search
ancestor contracts themselves.

## Physical provenance checks

The publisher verifies artifacts, not just mutually consistent metadata.

### Linux

For a changed Linux component, the publisher consumes the existing APT producer
output and v1 package identity, then verifies all of the following:

1. the APT `Release` advertises the selected suite and codename;
2. the matching `openpath-dnsmasq` `Packages` stanza has the exact package,
   version, filename, and SHA-256;
3. the referenced pool file exists at that filename; and
4. the downloaded `.deb` bytes hash to the `Packages` SHA-256.

The v2 component records the exact `Filename` and physical digest. The existing
Firefox managed-extension consistency checks remain in the Debian producer.

### Windows

For a changed Windows component, the publisher verifies this complete chain:

```text
sourceSha
  -> VERSION
  -> exact git short SHA
  -> scripts-v<version>-<short-sha>
  -> tag target
  -> GitHub Release tag
  -> template asset
  -> .sha256 sidecar
  -> template bytes
  -> payload-manifest.json bytes
```

The sidecar must identify the exact template filename and its digest must equal
the digest of the downloaded executable. The payload manifest must be valid
JSON with its supported manifest schema, and its recorded v2 digest is computed
from the downloaded bytes.

The existing Windows build, personalized installer, and real executable E2E
lanes remain the producers and physical target-platform evidence. The v2
workflow consumes their published output; it does not compile a second
installer.

### Browser policy

The publisher reads the exact checked-out Firefox manifest and browser-policy
specification, parses both as JSON, records the manifest version, and hashes the
physical policy-spec bytes. The browser-policy fingerprint covers the source and
platform policy modules that produce the behavior.

## Orchestration and migration

`.github/workflows/publish-promotion-contract.yml` is an explicit
`workflow_dispatch`/`workflow_call` aggregator for an exact OpenPath SHA. It:

1. checks out the requested SHA with full history and checks out `gh-pages`;
2. requires the existing CI, E2E, and installer-contract summaries for that
   exact SHA;
3. calculates canonical fingerprints and resolves the first-parent predecessor;
4. verifies only changed components, consuming the existing APT and Windows
   release producers;
5. builds the deterministic v2 object in Node;
6. writes only `promotion-contracts/v2/<FULL_SHA>.json`; and
7. commits/pushes that exact file to `gh-pages`.

The workflow contains no Debian or NSIS packager. It cannot publish before the
physical verification steps succeed.

The existing v1 contract remains in parallel at
`promotion-contracts/<FULL_SHA>.json` with its existing fields and meaning.
The reusable Debian publisher continues producing v1 during the migration
window. v1 is not silently reinterpreted as v2; a consumer must explicitly
request the exact v2 path once it migrates.

`release-scripts.yml` now treats tag publication as:

```text
tag absent                       -> create at exact SHA, push, verify remote
tag present at exact SHA         -> idempotent success
tag present at a different SHA  -> hard failure
```

When a GitHub Release already exists for the tag, every authoritative release
asset is downloaded and compared byte-for-byte with the newly built local
asset before the release action is skipped. Missing, inaccessible, or
incompatible assets fail closed.

## Local verification

Focused coverage is registered in the repository contract suite:

```bash
node --test tests/openpath-promotion-contract.test.mjs \
  tests/openpath-release-inputs.test.mjs \
  tests/openpath-promotion-publisher.test.mjs \
  tests/openpath-release-assets.test.mjs
npm run test:repo-config
```

The physical Windows executable E2E remains a required CI/Windows-runner lane;
the Node tests prove contract rejection and provenance rules but are not a
substitute for executing the real `.exe`.
