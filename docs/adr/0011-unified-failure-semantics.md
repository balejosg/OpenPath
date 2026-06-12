# ADR 0011: Unified Failure Semantics — Protected Mode on Both Platforms

**Status:** Accepted
**Date:** 2026-06-12
**Decision Makers:** OpenPath maintainers

## Context

The Linux and Windows endpoint agents handled watchdog-threshold failures through opposite product
decisions that were never deliberately aligned:

**Linux (prior behaviour)**
When `dnsmasq-watchdog.sh` recorded `MAX_CONSECUTIVE_FAILS` (3) consecutive failures and no
checkpoint rollback was available, it called `deactivate_firewall()`. This flushed every iptables
OUTPUT rule and set the policy to `ACCEPT`, giving the machine unrestricted outbound access —
a _fail-open_ posture.

**Windows (prior behaviour)**
When `Get-OpenPathWatchdogOutcome` incremented the fail counter to ≥ 3 and a checkpoint
rollback was unavailable, the agent did **not** open the firewall. Instead
`Enter-StaleWhitelistFailsafe` narrowed the Acrylic DNS proxy to a minimal set of control-plane
domains (`whitelistUrl` host, `apiUrl` host) while leaving the firewall rules in place —
a _fail-closed with a critical-domains valve_ posture. The state was persisted to
`data\stale-failsafe-state.json` and the watchdog reported status `STALE_FAILSAFE`.

The divergence was discovered during the cross-platform parity audit (2026-06-12). Both platforms
share the same threat model: a student endpoint whose primary risk is bypassing the approved
whitelist, not being unable to browse during a brief outage. Fail-open undermines the product
guarantee.

## Decision

**Both platforms will use fail-closed with a critical-domains valve (the Windows model).**

On Linux, when the watchdog threshold is reached and rollback fails, the agent switches dnsmasq
to a _protected-mode config_ instead of deactivating the firewall:

- The iptables firewall rules remain active.
- dnsmasq is reconfigured with only critical domains forwarded to the upstream resolver; all
  other queries continue to be sinkholed.
- The critical domain set is derived from `common-protected-domains.sh` (control-plane: GitHub
  raw, OpenPath API host, whitelist host) extended with captive-portal probe hosts and OS update
  domains (NTP, connectivity checks).
- A state file `$VAR_STATE_DIR/watchdog-protected.flag` is written so downstream tooling and
  health reporting can detect the mode.

An escape hatch is provided for labs and pilots that need to revert to the legacy behaviour
without a release: set `OPENPATH_FAILURE_MODE=open` (default: `protected`). When
`OPENPATH_FAILURE_MODE=open` the watchdog behaves exactly as it did before this ADR
(`deactivate_firewall`). Any value other than `open` is treated as `protected`.

## Consequences

### Positive

- Students cannot access arbitrary sites during a watchdog-triggered outage.
- The Linux agent now matches the Windows agent's security guarantee.
- Recovery from protected mode is automatic: the next watchdog cycle that passes all checks
  resets the fail counter and removes the state file; the full whitelist config is regenerated
  by the next update cycle (bounded by the update interval, default 5 minutes), since
  `generate_dnsmasq_config` runs unconditionally on every update.

### Negative

- If the critical-domains list is too narrow, students lose legitimate network connectivity during
  a failure (e.g. cannot reach captive portals, OS updaters). The escape hatch exists precisely
  for this case.
- Operators need to validate the critical-domain list against their network topology before
  production deployment.

### Neutral

- The `FAIL_OPEN` status code in `HEALTH_FILE` is replaced by `PROTECTED` when the new code
  path is taken. Operators monitoring for `FAIL_OPEN` should add `PROTECTED` to their alert
  queries.
- The Windows `STALE_FAILSAFE` status and Linux `PROTECTED` status are semantically equivalent
  but use platform-native names; this is intentional.

## Rollout

**Required validation before any production claim:**

1. Deploy to a staging or lab environment identical to the target production topology.
2. Simulate watchdog failures (stop dnsmasq, corrupt resolv.conf) and confirm the agent enters
   `PROTECTED` state (not `FAIL_OPEN`).
3. Verify that every domain in the critical-domains list resolves correctly in the lab network
   during protected mode.
4. Verify that non-whitelisted domains remain sinkholed during protected mode.
5. Verify that the next successful watchdog cycle exits protected mode and restores the full
   whitelist configuration.
6. If any critical domain fails to resolve (step 3), extend `common-protected-domains.sh` and
   repeat from step 2.

Do not promote to production until staging/lab evidence is available for all five checks above.
The `OPENPATH_FAILURE_MODE=open` escape hatch is available as a temporary revert path.

## Alternatives Considered

- **Keep Linux fail-open, accept the divergence**: rejected because the security guarantee of the
  product requires consistent behaviour on both platforms.
- **Always fail-closed with no critical-domain valve (full sinkhole)**: rejected because it
  breaks captive-portal authentication and OS updates during the failure window. The Windows
  implementation already demonstrated that a narrow valve is the right balance.
- **Make Windows match Linux (both fail-open)**: rejected by the operator; fail-open is not
  acceptable as the default posture on either platform.
