# WEDU Captive Portal Lab Contract

> Status: maintained
> Applies to: OpenPath WEDU captive portal lab workflows and controller scripts
> Last verified: 2026-05-28
> Source of truth: `docs/testing/wedu-captive-portal-lab.md`

The WEDU captive portal lab is the destructive target-platform lane for proving
OpenPath captive portal recovery against the Proxmox captive-network topology.
It mutates VM networking and must remain manual/nightly only.

## Check-Run Identities

- Full destructive lab: `WEDU captive portal lab`
- Gateway-only preflight: `WEDU gateway healthcheck`
- Optional VM 104 preflight: `WEDU Linux client smoke`

Only `WEDU captive portal lab` is eligible as target-platform release evidence.
The healthcheck and Linux client smoke lanes are optional preflight only and do not satisfy the promotion gate.

## Workflow Triggers

`.github/workflows/wedu-captive-portal-lab.yml` is manual plus nightly. It must
not run on `push` or `pull_request`.

`.github/workflows/wedu-gateway-healthcheck.yml` and
`.github/workflows/wedu-linux-client-smoke.yml` are manual-only cheap lanes.
They share the same remote lock as the full lab so they cannot overlap with VM
mutation or gateway mode changes.

## Shared Remote Lock

All lanes acquire `/run/openpath-wedu-captive-portal-lab.lock` through
`scripts/lib/wedu-captive-portal-lab-controller.sh`.

The lock metadata file is `wedu-lock-metadata.json` and includes:

- `owner`
- `mode`
- `startedEpoch`
- `githubRunId`
- `repoSha`
- `host`
- `pid`

The default stale-lock TTL is 7200 seconds via
`OPENPATH_WEDU_CI_LOCK_TTL_SECONDS`. A stale lock fails closed unless
`OPENPATH_WEDU_CI_FORCE_STALE_LOCK=1` is set. Forced stale-lock replacement
writes the same metadata schema as normal acquisition.

## Validator Modes

`scripts/assert-wedu-captive-portal-result.mjs` validates artifacts emitted by
the full lab harness.

`lab-direct` mode accepts direct lab evidence from the captive-network harness.
It requires:

- `direct-captive-portal-wedu-lab-result.json`
- `profile: captive-portal-wedu-lab`
- `wedu-lab-browser-before.json`
- pre-auth portal detection

`lab-direct` mode may accept missing `schemaVersion` and
`targetPlatformSymptomCleared: false`; it proves the lab detected the captive
portal but is not final target-platform clearance.

`target-platform` mode is stricter. It requires:

- `schemaVersion >= 2`
- `targetPlatformSymptomCleared: true`
- limited-mode DNS evidence in `wedu-lab-dns-limited.json`
- limited-mode browser evidence in `wedu-lab-browser-limited.json`
- exact declared-domain evidence from native recovery, with
  `limitedModeReady: true`, `activeMarkerMode: limited`, recovery hosts applied,
  and no `passthrough` fallback
- the declared WEDU portal host must be present in the limited-mode exact-host
  set and must resolve through Acrylic on `127.0.0.1`; dynamic login, asset,
  CDN, auth, redirect, resource, runtime, pending-host, and truncation fields are
  diagnostic only
- `browserAfterAuthPath: wedu-lab-browser-post-auth.json`
- post-auth DNS evidence in `wedu-lab-dns-post-auth.json`, including
  successful queries through `127.0.0.1` and adapter DNS content showing the
  local resolver
- post-auth OpenPath protection evidence in
  `wedu-lab-openpath-protection-after.json`, proving the blocked-domain
  negative control is still blocked, the allowed-domain positive control still
  resolves, Acrylic has returned to the normal `NX *` catch-all without the
  captive-portal recovery section, and `protectedModeRestored: true`
- post-auth browser evidence with `portalMarkerAbsent: true`
- post-auth external navigation with `externalNavigationFunctional: true`
- `failureKind: none`

The split portal fields are intentional: pre-auth detection proves the captive
portal appeared, while post-auth fields prove the marker disappeared and normal
external navigation recovered.

During the limited-mode phase the Windows recovery code may probe bounded
HTTP bootstrap redirects and HTML from the trigger host to discover exact
portal hosts such as login, asset, CDN, or auth hosts. The native marker and
lab artifacts store only normalized hostnames, never URLs, cookies, headers,
paths, query strings, or page DOM.

## Gateway Healthcheck

`scripts/wedu-captive-portal-gateway-healthcheck.sh` uses VM 121 only. It
acquires the shared lock with mode `healthcheck`, verifies QGA and gateway
services, records the previous gateway firewall mode, calls `/lab/reset`,
probes the captive portal body, writes `gateway-healthcheck.json`, and restores
authenticated mode when that was the previous state.

This lane is useful before running the destructive full lab, but it is not
release evidence and does not satisfy the promotion gate. The cheap lanes do
not satisfy the promotion gate.

## VM 104 Linux Client Smoke

`scripts/run-wedu-captive-portal-gateway-client-smoke.sh` is an optional preflight only.
It acquires the shared lock with mode `linux-client-smoke`,
asserts VM 103 is not attached to `vmbr10`, snapshots VM 104, moves VM 104 to
`vmbr10`, verifies DHCP on `10.77.0.0/24` with DNS `10.77.0.1`, confirms
pre-auth portal interception, authenticates the gateway, confirms post-auth
external navigation, rolls VM 104 back, restores gateway state, and releases
the lock.

It validates gateway/client topology without consuming the Windows runner, but
it does not satisfy the promotion gate.
