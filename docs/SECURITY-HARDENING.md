# OpenPath Security Hardening

> Status: maintained
> Applies to: OpenPath operators
> Last verified: 2026-11-16
> Source of truth: `docs/SECURITY-HARDENING.md`

## API

- set a strong `JWT_SECRET`
- set explicit `CORS_ORIGINS` in production
- publish public agent/extension endpoints over HTTPS
- rotate registration or enrollment material when compromised

## Linux Agents

- restrict root access
- verify `dnsmasq`, watchdog, SSE, and update services after install
- protect `/etc/openpath` and monitor `/var/log/openpath.log`
- keep package/upgrade trust anchored to the persistent APT signing key
- serve enrollment and APT bootstrap URLs over HTTPS; without certificate
  pinning, plain HTTP bootstrap can be modified by a network attacker before
  the agent is installed
- publish package or bootstrap artifact hashes through a trusted channel and
  compare them during operational rollout when pinning is not available

## Windows Agents

- run installers as Administrator only from trusted sources
- verify scheduled tasks and firewall rules after bootstrap
- protect `C:\OpenPath\data\config.json` and staged browser-extension artifacts
- the AppLocker tool-blocks and Appx denies (IP-literal egress mitigation) are on
  by default; for stricter lockdown, the optional outbound egress floor is
  default-off -- enable it per the canary runbook in
  [`windows-egress-floor.md`](windows-egress-floor.md)

## Windows runtime dependency learning

The runtime dependency queue under `C:\OpenPath\data\runtime-dependency-queue`
is writable by local users. The native host accepts self-asserted
`{anchorHost, dependencyHost, requestType}` triples and the SYSTEM worker turns
accepted dependencies into local DNS exceptions. Before the limits below, the
only checks were that the anchor was locally whitelisted and the dependency was
not protected or blocked; there was no relationship check between anchor and
dependency.

Mitigations now in place:

- per-anchor budget: a new dependency is rejected when its `anchorHost`
  already has 32 live dependencies, configured with
  `OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_MAX_PER_ANCHOR`. This is more than five
  times the maximum of six dependencies per anchor observed in the first-visit lane
  fixture logs under `tests/e2e/ci/first-visit/fixtures/`. Overlays written
  before this limit existed are not truncated; the cap applies to new entries.
- machine-wide rate limit: at most 60 new dependencies per rolling 5 minute
  window, configured with `OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_LIMIT` and
  `OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_RATE_WINDOW_MINUTES`. This is three times
  the 20-entry synthetic fan-out exercised in the Phase 2B lab burst documented
  in [`design/runtime-dependency-readiness-plan.md`](design/runtime-dependency-readiness-plan.md).
- audit trail: every accepted net-new dependency and every rejection caused by
  either limit is appended to
  `C:\OpenPath\data\runtime-dependency-audit.log` with a UTC timestamp in
  round-trip format, the anchor, the dependency, the request type, and the
  reason. The file lives under the restricted data root and is set to the
  `RestrictedRoot` ACL profile, which grants full control to the SYSTEM
  (`S-1-5-18`) and Administrators (`S-1-5-32-544`) SIDs and removes inherited
  access. The path can be overridden with
  `OPENPATH_RUNTIME_DEPENDENCY_AUDIT_PATH`.

Residual risk after this change: a local user can still use any whitelisted
anchor as a generic pivot for arbitrary (non-protected, non-blocked) dependency
hosts up to the per-anchor and rate limits. The per-anchor budget is keyed on
the asserted `anchorHost`; subdomains of a whitelisted domain are separate
anchors, so the machine-wide rate limit is the aggregate bound in that case.
Filling an anchor budget can also deny legitimate new dependencies for that
anchor until entries expire or are evicted. The limits bound and record abuse;
they do not prove that a dependency was actually requested by the anchor. This
is an accepted residual, not a complete authorization boundary.

## Machine token exposure on Windows

The native `get-config` action returns `machineToken` to the browser, at
`windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1:116`. The Firefox
native host runs as the logged-in student, so a local user can read the machine
token for that machine. This is an accepted risk.

Scope verified in `api/`:

- `api/tests/machine-auth-scope-operational.test.ts`: the shared secret alone is
  rejected for machine health submission, request submission, and token
  rotation; a machine token is accepted only for its own hostname; rotating the
  token invalidates the previous token.
- `api/tests/machine-auth-scope-boundaries.test.ts`: a machine token for
  classroom A cannot submit a health report for a machine in classroom B (403),
  and an enrollment token for classroom A cannot register a machine in
  classroom B (403).
- `api/tests/machine-auth-scope-enrollment.test.ts`: a teacher cannot mint an
  enrollment token for a classroom outside their group, and a machine token can
  read the whitelist for its own machine.

The implementation matches that scope: `resolveMachineTokenAccess` loads
exactly one machine row from the token hash, `healthReports.submit` requires
`machineMatchesHostname`, `/api/requests/submit` uses
`resolveMachineTokenHostnameAccess`, and the machine policy, events, and
delivery routes derive the machine from the token instead of a caller-supplied
hostname. The token therefore operates only on its own machine: it can submit
that machine's health and access requests, read that machine's whitelist and
policy, and rotate its own download token. It cannot read or change another
machine's policy, submit data as another machine, or cross a classroom boundary.
The local-user impact is impersonation and availability of that machine's
enrollment (including rotating its token), not a fleet-wide or cross-tenant
authorization bypass.

## Repo Checks

```bash
npm run security:audit
npm run security:secrets
npm run verify:security
```

Use [`../SECURITY.md`](../SECURITY.md) for disclosure workflow; this file is the operator hardening checklist.
