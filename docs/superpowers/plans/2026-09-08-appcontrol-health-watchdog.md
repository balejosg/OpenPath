# AppControl Health And Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Windows endpoint health non-healthy whenever required AppControl or its watchdog boundary is absent, and preserve stable reason codes through reporting and storage.

**Architecture:** Add one structured AppControl evaluator behind the existing boolean compatibility function, plus a structured scheduled-task readiness evaluator in the watchdog runtime. Carry deduplicated reason codes through the watchdog outcome, Windows sender, shared wire schema, API persistence, and query responses while retaining existing human-readable actions.

**Tech Stack:** PowerShell 5.1/Pester, TypeScript, Zod, tRPC, Drizzle ORM/PostgreSQL, Node test runner.

---

## File Map

- `windows/lib/AppControl.psm1`: authoritative AppControl observation and boolean adapter.
- `windows/tests/Windows.AppControl.Tests.ps1`: reason-code and compatibility contract.
- `windows/lib/internal/Watchdog.Runtime.ps1`: task readiness, repair orchestration, and aggregate reason codes.
- `windows/tests/Windows.Watchdog.Tests.ps1`: watchdog/task/repair health contract.
- `windows/scripts/Test-DNSHealth.ps1`: pass aggregate reason codes to the sender.
- `windows/lib/internal/Common.Http.Health.ps1`: serialize bounded reason-code arrays.
- `windows/tests/Windows.Common.Mocked.Tests.ps1`: Windows payload serialization tests.
- `shared/src/schemas/index.ts`: shared reason-code wire validation.
- `shared/tests/schemas-health-report-submit.test.ts`: schema compatibility and rejection tests.
- `api/src/db/schema.ts`, `api/src/db/schema.sql`, `api/drizzle/*`: health-report storage column and migration metadata.
- `api/src/trpc/routers/health-reports.ts`: map validated input into storage.
- `api/src/lib/health-reports.ts`: store and return reason codes.
- `api/tests/health-reports-admin.test.ts`: submit/query persistence coverage.

### Task 1: Structured AppControl Health Contract

**Files:**

- Modify: `windows/tests/Windows.AppControl.Tests.ps1`
- Modify: `windows/lib/AppControl.psm1:1242-1393`

- [ ] **Step 1: Add failing Pester tests for distinct observations**

Add a `Get-OpenPathNonAdminAppControlHealth` context using the existing module
mocks. Each test must assert both `Healthy` and the exact stable code:

```powershell
$result = InModuleScope AppControl {
    Get-OpenPathNonAdminAppControlHealth -Mode Enforced -ApprovedBrowsers @('Firefox')
}
$result.Healthy | Should -BeFalse
$result.ReasonCodes | Should -Contain 'appcontrol_effective_policy_absent'
```

Cover these independent cases:

```text
appcontrol_capability_unavailable
appcontrol_restricted_target_missing
appcontrol_appidsvc_not_running
appcontrol_local_policy_absent
appcontrol_local_policy_invalid
appcontrol_effective_policy_absent
appcontrol_effective_policy_invalid
appcontrol_runtime_evaluation_unavailable
appcontrol_runtime_arbitrary_exe_allowed
appcontrol_runtime_edge_allowed
appcontrol_runtime_firefox_not_allowed
appcontrol_probe_cleanup_failed
```

Add a compatibility assertion:

```powershell
Mock Get-OpenPathNonAdminAppControlHealth {
    [pscustomobject]@{ Healthy = $false; ReasonCodes = @('appcontrol_effective_policy_absent') }
} -ModuleName AppControl
InModuleScope AppControl {
    Test-OpenPathNonAdminAppControlActive -Mode Enforced -ApprovedBrowsers @('Firefox')
} | Should -BeFalse
```

- [ ] **Step 2: Run the focused test and verify red state**

Run:

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path windows/tests/Windows.AppControl.Tests.ps1 -CI"
```

Expected: failures because `Get-OpenPathNonAdminAppControlHealth` is not
defined/exported and the boolean function does not delegate to it.

- [ ] **Step 3: Implement the structured evaluator**

In `AppControl.psm1`, implement a deterministic result builder whose public
shape is:

```powershell
[PSCustomObject]@{
    Healthy = ($reasonCodes.Count -eq 0)
    Mode = $Mode
    ReasonCodes = @($reasonCodes | Select-Object -Unique)
    CapabilityAvailable = $capabilityAvailable
    RestrictedTargetValid = $restrictedTargetValid
    AppIdentityServiceRunning = $appIdentityServiceRunning
    LocalPolicyPresent = $localPolicyPresent
    LocalPolicyValid = $localPolicyValid
    EffectivePolicyPresent = $effectivePolicyPresent
    EffectivePolicyValid = $effectivePolicyValid
    RuntimeEvaluationAvailable = $runtimeEvaluationAvailable
    RuntimeBoundaryValid = $runtimeBoundaryValid
}
```

Move the current local/effective XML and `Test-AppLockerPolicy` observations
into that function. Do not place exception strings, paths, usernames, SIDs,
URLs, or configuration values in `ReasonCodes`. Keep detailed diagnostics in
existing local logs only.

Replace the current boolean implementation with the adapter:

```powershell
function Test-OpenPathNonAdminAppControlActive {
    [CmdletBinding()]
    param(
        [ValidateSet('AuditOnly', 'Enforced')][string]$Mode = 'Enforced',
        [string[]]$ApprovedBrowsers = @('Firefox')
    )

    $health = Get-OpenPathNonAdminAppControlHealth `
        -Mode $Mode `
        -ApprovedBrowsers $ApprovedBrowsers
    return [bool]$health.Healthy
}
```

Export the new function beside `Test-OpenPathNonAdminAppControlActive`.

- [ ] **Step 4: Run focused Pester and make it green**

Run the Step 2 command. Expected: all tests pass, including all pre-existing
AppControl behavior.

- [ ] **Step 5: Commit the contract**

```bash
git add windows/lib/AppControl.psm1 windows/tests/Windows.AppControl.Tests.ps1
git commit -m "feat(windows): structure AppControl health" -m "Refs #186"
```

### Task 2: Watchdog Task And Repair Health

**Files:**

- Modify: `windows/tests/Windows.Watchdog.Tests.ps1`
- Modify: `windows/lib/internal/Watchdog.Runtime.ps1:46-145`
- Modify: `windows/lib/internal/Watchdog.Runtime.ps1:284-818`
- Modify: `windows/lib/internal/Watchdog.Runtime.ps1:812-930`

- [ ] **Step 1: Add failing task-readiness and aggregate-code tests**

Add isolated tests for a new `Get-OpenPathWatchdogTaskHealth` helper. Mock
`Get-OpenPathScheduledTaskSpec` to return `OpenPath-Watchdog` and the expected
`scripts\Test-DNSHealth.ps1` action. Assert:

```text
missing task -> watchdog_task_missing
State Disabled -> watchdog_task_disabled
wrong/missing executable action -> watchdog_task_not_runnable
State Ready + expected action -> Healthy
State Running + expected action -> Healthy
```

Add watchdog-cycle cases for missing `Get-OpenPathNonAdminAppControlHealth`,
group synchronization false/throw, `Set-OpenPathNonAdminAppControl` false/throw,
and post-repair health false. Assert exact codes:

```text
appcontrol_health_check_unavailable
appcontrol_group_sync_failed
appcontrol_repair_failed
appcontrol_repair_unverified
```

Finally assert that `Get-OpenPathWatchdogOutcome` cannot return `HEALTHY` when
`ReasonCodes` is non-empty even if `Issues` is empty.

- [ ] **Step 2: Run the watchdog suite and verify red state**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path windows/tests/Windows.Watchdog.Tests.ps1 -CI"
```

Expected: new helper/properties/parameter are absent.

- [ ] **Step 3: Implement scheduled-task readiness**

Dot-source `ScheduledTaskCatalog.ps1` if its lookup command is unavailable.
Implement:

```powershell
function Get-OpenPathWatchdogTaskHealth {
    $codes = [System.Collections.Generic.List[string]]::new()
    $spec = Get-OpenPathScheduledTaskSpec -TaskType Watchdog
    $task = Get-ScheduledTask -TaskName $spec.Name -ErrorAction SilentlyContinue
    # Missing, Disabled, and mismatched action add the codes listed above.
    [pscustomobject]@{
        Healthy = ($codes.Count -eq 0)
        ReasonCodes = @($codes)
        Present = ($null -ne $task)
        Enabled = ($task -and [string]$task.State -ne 'Disabled')
        Runnable = $runnable
    }
}
```

Validate the action by normalizing slashes/case and requiring the canonical
`Test-DNSHealth.ps1` leaf; accept scheduler states `Ready` and `Running`.

- [ ] **Step 4: Integrate AppControl and repair observations**

At the start of `Invoke-OpenPathWatchdogChecks`, initialize:

```powershell
$reasonCodes = [System.Collections.Generic.List[string]]::new()
```

Add task-readiness codes, consume
`Get-OpenPathNonAdminAppControlHealth`, never default missing inspection/sync
commands to success, and add explicit repair codes. Rerun the structured
health evaluator after a successful repair and clear only the transient
initial AppControl observation codes when the post-repair result is healthy.

Return `ReasonCodes` alongside `Issues`. Extend
`Get-OpenPathWatchdogOutcome` with a mandatory `ReasonCodes` parameter, make a
non-empty array produce at least `DEGRADED`, and return its deduplicated value.

- [ ] **Step 5: Run focused suites and make them green**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path windows/tests/Windows.AppControl.Tests.ps1,windows/tests/Windows.Watchdog.Tests.ps1 -CI"
```

Expected: all tests pass.

- [ ] **Step 6: Commit watchdog behavior**

```bash
git add windows/lib/internal/Watchdog.Runtime.ps1 windows/tests/Windows.Watchdog.Tests.ps1
git commit -m "fix(windows): make watchdog health truthful" -m "Refs #186"
```

### Task 3: Structured Health-Report Transport

**Files:**

- Modify: `shared/src/schemas/index.ts:151-164,246-286`
- Modify: `shared/tests/schemas-health-report-submit.test.ts`
- Modify: `windows/lib/internal/Common.Http.Health.ps1:74-178`
- Modify: `windows/tests/Windows.Common.Mocked.Tests.ps1:543-600`
- Modify: `api/src/db/schema.ts:379-397`
- Modify: `api/src/db/schema.sql:23-35`
- Modify: `api/src/trpc/routers/health-reports.ts:73-125`
- Modify: `api/src/lib/health-reports.ts:19-95,122-214`
- Modify: `api/tests/health-reports-admin.test.ts`
- Create: generated `api/drizzle/0026_*.sql`
- Create: generated `api/drizzle/meta/0026_snapshot.json`
- Modify: `api/drizzle/meta/_journal.json`

- [ ] **Step 1: Add failing schema and sender tests**

Add this bounded wire contract at the top level of a health report:

```typescript
reasonCodes: z.array(z.string().regex(/^[a-z][a-z0-9_]{2,63}$/))
  .max(32)
  .optional();
```

Tests must accept omitted and valid arrays, reject more than 32 entries, and
reject values containing spaces, paths, colons, URLs, or mixed case.

In Pester, call:

```powershell
Send-OpenPathHealthReport `
    -Status DEGRADED `
    -ReasonCodes @('appcontrol_effective_policy_absent', 'watchdog_task_missing')
```

Assert the JSON array is preserved in order and duplicates are removed. Add a
test proving no `reasonCodes` property is serialized when the input is empty.

- [ ] **Step 2: Add failing API persistence test**

Submit a report with two reason codes via `healthReports.submit`, query it via
the existing admin report procedure, and assert exact round-trip order. Submit
an older payload without the field and assert the returned value is `[]`.

- [ ] **Step 3: Run focused tests and verify red state**

```bash
npm test --workspace=@openpath/shared -- --test-name-pattern='HealthReportSubmitInput'
pwsh -NoProfile -Command "Invoke-Pester -Path windows/tests/Windows.Common.Mocked.Tests.ps1 -CI"
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit api/tests/health-reports-admin.test.ts
```

Expected: schema/sender/storage do not yet expose `reasonCodes`.

- [ ] **Step 4: Implement schema, sender, and API mapping**

Add optional `reasonCodes` to `HealthReportSubmitInput`. Add a PowerShell
`[string[]]$ReasonCodes = @()` parameter, deduplicate it, and serialize only
validated lowercase underscore codes.

Add `reasonCodes: string[]` to `HealthReport`, map input in the router, store
it in `saveHealthReport`, and map a nullable legacy row to `[]` in both query
functions. Add this Drizzle field:

```typescript
reasonCodes: text('reason_codes').array(),
```

Add the matching nullable `text[]` column to `schema.sql`.

- [ ] **Step 5: Generate and verify migration metadata**

```bash
npm run drizzle:generate --workspace=@openpath/api
npm run verify:migrations:metadata
```

Expected: one new migration adds `health_reports.reason_codes text[]`; Drizzle
metadata and schema verification pass.

- [ ] **Step 6: Run focused suites and make them green**

Run all commands from Step 3. Expected: all pass.

- [ ] **Step 7: Commit transport and persistence**

```bash
git add shared/src/schemas/index.ts shared/tests/schemas-health-report-submit.test.ts \
  windows/lib/internal/Common.Http.Health.ps1 windows/tests/Windows.Common.Mocked.Tests.ps1 \
  api/src/db/schema.ts api/src/db/schema.sql api/src/trpc/routers/health-reports.ts \
  api/src/lib/health-reports.ts api/tests/health-reports-admin.test.ts api/drizzle
git commit -m "feat(health): persist endpoint reason codes" -m "Refs #186"
```

### Task 4: Entrypoint Integration And Verification

**Files:**

- Modify: `windows/scripts/Test-DNSHealth.ps1:75-122`
- Modify: `windows/tests/Windows.Watchdog.Tests.ps1`
- Modify: `tests/e2e/ci/run-windows-browser-boundary-ci.ps1` only after the active #253 path claim is released or coordinated.

- [ ] **Step 1: Add a failing source/behavior contract for the entrypoint**

Assert that the real entrypoint passes the aggregate reason codes through both
calls:

```powershell
-ReasonCodes @($checkResult.ReasonCodes)
```

Pass this value to `Get-OpenPathWatchdogOutcome`, then pass
`-ReasonCodes @($outcome.ReasonCodes)` to `Send-OpenPathHealthReport`.
Add a behavioral assertion that an unresolved
effective-policy or watchdog-task code produces a non-`HEALTHY` report.

- [ ] **Step 2: Wire the entrypoint and rerun focused Windows tests**

Pass `ReasonCodes` from checks to outcome and sender without converting them to
exception text or embedding secrets.

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path windows/tests/Windows.AppControl.Tests.ps1,windows/tests/Windows.Watchdog.Tests.ps1,windows/tests/Windows.Common.Mocked.Tests.ps1 -CI"
```

Expected: all focused tests pass.

- [ ] **Step 3: Run repository-local validation**

```bash
/datos_nvme/run0/Whitelist/scripts/validate-hypothesis.sh openpath local --dry-run
/datos_nvme/run0/Whitelist/scripts/validate-hypothesis.sh openpath windows-direct --dry-run
npm run verify:quick
npm run verify:affected
```

Expected: dry runs identify the intended local and Windows lanes; quick and
affected verification pass. Do not manually run `verify:full`.

- [ ] **Step 4: Perform two-stage subagent review**

Dispatch one read-only reviewer against the approved spec and plan. Require an
acceptance-criteria verdict with file/line evidence. Dispatch a second
read-only reviewer for code quality, PowerShell 5.1 compatibility, secret
leakage, migration safety, and test isolation. Fix every confirmed finding and
rerun the affected focused test.

- [ ] **Step 5: Commit the integrated entrypoint**

```bash
git add windows/scripts/Test-DNSHealth.ps1 windows/tests/Windows.Watchdog.Tests.ps1
git commit -m "fix(windows): report boundary health codes" -m "Refs #186"
```

- [ ] **Step 6: Run the direct Windows lane**

Only after confirming the active #253 path claim is released and the checkout
is on the intended exact SHA, run:

```bash
npm run diagnostics:windows:direct -- \
  --mode browser-boundary \
  --source-mode local-overlay \
  --artifact-dir ../.opencode/tmp/openpath-186-browser-boundary
```

The local overlay archives committed HEAD, so commit the reviewed changes and
verify a clean checkout before running it. Do not substitute the runner's older
checkout for the unpushed implementation.

Capture exact SHA and artifacts proving Firefox allowed, Edge denied, and an
arbitrary PE denied. Extend or run the physical negative-health harness so
effective-policy removal, watchdog removal/disablement, broken restricted
targeting, and forced repair failure each report non-`HEALTHY`, then restore
the endpoint and re-prove the positive boundary.

- [ ] **Step 7: Final evidence report**

Report separately:

```text
unit/contract test
target-platform symptom cleared
```

Do not claim closure if the physical negative-health harness was not executed.
Do not push, deploy, release, tag, promote, or close #186.
