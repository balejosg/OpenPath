# AppControl Health And Watchdog Design

## Problem

When Windows configuration requires non-admin AppControl in `Enforced` mode,
OpenPath can still lose the reason that the execution boundary is unavailable.
The current code has effective-policy and runtime probes from issue #253, and
the watchdog checks several repair return values, but these checks collapse to
booleans and free-form issue strings. A missing or disabled
`OpenPath-Watchdog` task is also absent from the endpoint health decision.

The result is an incomplete health contract: operators cannot reliably
distinguish policy, service, targeting, task, runtime, and repair failures, and
a manually invoked health cycle can report `HEALTHY` while the recurring
watchdog is absent.

## Scope And Ownership

This issue owns truthful AppControl health, watchdog readiness, repair-result
propagation, and structured endpoint reporting.

Issue #253 remains the owner of installer phase ordering, rollback,
partial-install safety, and the `Sync -> Set -> Test -> commit` transaction.
This change will consume that transaction's `appControlCommitState`; it will
not redesign or duplicate it. ClassroomPath, deployment, release, tags,
promotion, and issue closure are out of scope.

## Selected Approach

Introduce a structured local health result and carry its stable reason codes
through the existing health-report pipeline as first-class data. Preserve the
current boolean and free-text surfaces as compatibility adapters.

Encoding reason codes only inside `actions` was rejected because it would not
provide a queryable structured contract. Replacing the full endpoint health
subsystem was rejected as unnecessary for this issue.

## AppControl Health Contract

`windows/lib/AppControl.psm1` will expose
`Get-OpenPathNonAdminAppControlHealth`. It will return a deterministic object
with:

- `Healthy`: true only when every required predicate passes;
- `ReasonCodes`: unique stable codes in deterministic order;
- `Mode` and non-secret diagnostic booleans for capability, restricted target,
  AppIDSvc, local policy, effective policy, and runtime evaluation.

The result will distinguish at least:

- AppLocker capability unavailable;
- restricted group or usable student target missing;
- AppIDSvc absent or stopped;
- local policy absent or structurally invalid;
- effective policy absent or structurally invalid;
- runtime evaluation unavailable or inconsistent with the required boundary;
- probe cleanup failure.

The existing `Test-OpenPathNonAdminAppControlActive` function will call the new
function and return only `Healthy`. Existing callers therefore retain their
boolean contract while watchdog health gains the structured result.

The durable `appControlCommitState` introduced by #253 defines the current
model. Missing current targeting is unhealthy. The historical
`BUILTIN\Users` fallback must not independently prove a current configuration
healthy; legacy configuration may become committed only through the existing
verified migration path.

## Watchdog Readiness And Repair Flow

A focused task-readiness helper will resolve the canonical Watchdog descriptor
from `ScheduledTaskCatalog.ps1` and inspect the registered task. Its result
will distinguish a missing task, disabled task, and task whose action cannot
run the expected health entrypoint. `Ready` and `Running` scheduler states are
acceptable.

Each health cycle will:

1. evaluate watchdog task readiness and initial AppControl health;
2. preserve group-sync and capability-unavailable failures instead of
   defaulting missing commands to success;
3. attempt the existing restricted-group and AppControl repairs when eligible;
4. record whether repair was attempted and whether it returned false or threw;
5. rerun the structured effective-policy/runtime validation;
6. remove repaired observations only when the post-repair result is healthy;
7. keep the endpoint non-healthy with stable codes when repair fails or cannot
   be verified.

The watchdog result will carry both human-readable `Issues` and structured
`ReasonCodes`. `Get-OpenPathWatchdogOutcome` will never return `HEALTHY` when
either collection contains an unresolved health finding.

## Reporting And Storage

The Windows health sender will include `reasonCodes: string[]` in addition to
the existing `actions` text. The shared submission schema will validate a
bounded array of stable, non-secret codes. The API router, database model, and
migration will persist it, and health-report queries will return it.

`actions` remains populated for older consumers. No exception text, path,
username, SID, configuration value, token, or URL is permitted in a reason
code. Unknown extra fields retain the repository's existing input-handling
semantics.

## Failure Semantics

Required AppControl is fail-closed for health classification:

- missing inspection commands are capability failures, not successful skips;
- AppIDSvc running is necessary but never sufficient;
- local structure cannot substitute for effective policy;
- a successful repair call cannot substitute for post-repair validation;
- a watchdog that is missing, disabled, or wired to an invalid action prevents
  `HEALTHY`;
- an absent watchdog cannot report its own failure, so server-side stale
  heartbeat detection remains the independent backstop.

## Testing And Evidence

Tests will be added before production behavior changes.

Focused Pester coverage will prove distinct codes for capability, group/target,
AppIDSvc, local/effective policy, runtime decisions, task readiness, repair
false/throw, and failed post-repair validation. Compatibility tests will prove
the existing boolean function still reflects the structured result. Health
sender tests will verify deterministic serialization and absence of secret
diagnostics.

Shared/API tests will cover schema validation, persistence, query round trips,
and compatibility when older agents omit `reasonCodes`. Repository migration
metadata checks will cover the database change.

After local focused tests, the repository's Windows direct-runner lane will be
used. Target-platform acceptance requires both directions:

- a healthy endpoint permits Firefox while denying Edge and an arbitrary PE;
- removing effective policy, removing or disabling the watchdog, breaking the
  restricted target, or forcing repair failure makes reported health
  non-`HEALTHY` with the corresponding code.

Physical evidence is exact-SHA evidence. Existing successful browser-boundary
runs do not prove the new negative health cases.

## Coordination And Landing

Implementation will use the isolated checkout prepared from `origin/main`.
The divergent shared checkout and its active browser-boundary worktree claim
will not be modified. Subagents will receive non-overlapping write scopes, and
the primary agent will review every diff and run integrated verification.

No push, deployment, release, tag, promotion, or issue closure is authorized
by this implementation request.
