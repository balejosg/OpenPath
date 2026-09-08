# OpenPath #186 verification record

Status: locally and target-platform verified implementation.
Independent specification and quality reviews approved the final changes after
two review/runtime findings were corrected and re-reviewed.
No deployment, push, release, tag, or issue closure has been performed.

## Scope and checkout

Implementation is in the isolated `codex-186-health/health-watchdog/OpenPath`
checkout on `main`, based on `1481869d`. The Windows run exercised the clean
source tree at `1ffb93893654c0d0c5efe5803881d2deb9a518db`. The divergent shared
checkout has not been modified.

## Local evidence

Fresh primary-agent checks during implementation:

- AppControl Pester: 73 passed, including duplicate/unknown decision paths,
  partial evaluation, mixed browser decisions, and probe cleanup failures.
- Browser enforcement-status compatibility Pester: 10 passed.
- Health sender/Common Pester: 39 passed, including legacy positional binding.
- Shared health submission schema: 33 passed.
- API health-report admin tests: 15 passed; integration health-report tests:
  3 passed, using a disposable PostgreSQL 16 container on loopback port 32768.
- API typecheck, migration metadata verification, and affected TypeScript lint
  passed. Shared test files are outside the repository ESLint include scope;
  their execution and formatting were checked separately.
- The exact `0026` SQL was applied to a separate disposable database containing
  a legacy row; the row was preserved and the new column remained nullable.
- CLI Pester: 14 passed. The new durable-state regression failed before the fix.
- Watchdog Pester: 104 passed, including preservation of group failures after
  policy repair, durable legacy migration, and single-action task validation.
- Combined AppControl, Common sender, CLI, browser-status, and watchdog suites:
  240 passed in a single PowerShell process, with no failures or skips.
- `verify:quick` and PowerShell invariant-culture checks passed.
- The browser-boundary source contracts passed all 66 tests, and the direct
  Windows runner command contracts passed all 36 tests. The modified PowerShell
  parsed with zero errors.
- The complete shared suite passed all 253 tests. An earlier hook invocation
  reported a file-level failure without a diagnostic; isolated and full reruns
  passed without code changes. Its cause remains unconfirmed.
- A later hook's parallel static runner exited with a segmentation fault.
  All 10 static tasks passed with `--concurrency=1`; the unchanged default
  `verify:static` invocation then passed using those cached results.

Review-driven regressions cover previously unreported runtime errors, failed
partial cleanup, mixed allowed/denied browser results, duplicate or unknown
decision paths, and case-sensitive wire-code validation. The primary agent
reviewed these diffs and reran the tests independently of the implementers.

These are unit/contract and isolated API integration results, not Windows
physical enforcement evidence. Commit hooks additionally run at local commit time.

The browser-boundary harness was developed test-first. Its first revision moved
from 63 passing and 2 failing contracts to 65 passing. Quality review then found
that restricted-group reconciliation could add members outside the pre-probe
snapshot; exact removal/re-addition and snapshot verification were added. The
first physical execution found that dot-sourcing `Watchdog.Runtime.ps1` inside an
initializer kept its functions in function-local scope. A new failing contract
reproduced that boundary, the load moved to caller scope, and the focused suite
finished with 66 passing tests. Both fixes passed independent re-review.

## Validation incident

A delegated migration command supplied `DATABASE_URL` for the isolated test
database but omitted the separate `DB_*` variables consumed by Drizzle's config.
The repair pre-step used the isolated URL and reported zero changed rows.
Drizzle then connected to the default local database and failed on the first
migration statement because `classrooms` already existed.

Read-only inspection confirmed that `health_reports.reason_codes` was absent
from the default database and its `drizzle.__drizzle_migrations` table was empty.
The migration batch rolls back transactionally, but Drizzle creates its metadata
schema/table before that transaction. Without a prior metadata baseline, creation
of that empty metadata table cannot be excluded. It was not removed. No further
writes were made to the default database. Subsequent test commands explicitly
set both connection configurations to the disposable database.

## Target-platform evidence

The first-choice Windows VM 103 was not mutated: its QEMU guest agent timed out
while the runner was still detecting the guest address. VM 105 was online and
idle, so the same local-overlay browser-boundary lane was run there instead.

An execution at `e7141add1c8adf2f9c631663f3968002cf2e992a` preserved all positive
browser/AppLocker observations but failed before producing the summary because
`Get-OpenPathWatchdogTaskHealth` was no longer visible outside the initializer
scope. The external reset completed, and direct inspection found no OpenPath
tasks, install root, or restricted group, with AppIDSvc stopped. That execution
is failure evidence only; it is not counted as acceptance.

The corrected clean source tree at
`1ffb93893654c0d0c5efe5803881d2deb9a518db` completed the direct VM 105 lane at
2026-09-08T20:13:01+02:00 with exit code 0. The safe evidence files are under
`.opencode/tmp/openpath-186-health-watchdog-vm105-1ffb938/` in the isolated
checkout's parent:

- `direct-browser-boundary-completion.json`
- `browser-boundary-summary.json`
- `direct-final-reset.out.log`

The summary contains exactly four passing negative probes:

| Probe                              | Observed reason-code evidence                                                                                                                                                                                                 |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Watchdog scheduled task disabled   | `watchdog_task_disabled`                                                                                                                                                                                                      |
| OpenPath AppControl policy removed | `appcontrol_local_policy_invalid`, `appcontrol_effective_policy_invalid`, `appcontrol_runtime_arbitrary_exe_allowed`, `appcontrol_runtime_edge_allowed`, `appcontrol_runtime_firefox_not_allowed`                             |
| OpenPath restricted target missing | `appcontrol_restricted_target_missing`, `appcontrol_local_policy_invalid`, `appcontrol_effective_policy_invalid`                                                                                                              |
| Watchdog AppControl repair failed  | `appcontrol_local_policy_invalid`, `appcontrol_effective_policy_invalid`, `appcontrol_runtime_arbitrary_exe_allowed`, `appcontrol_runtime_edge_allowed`, `appcontrol_runtime_firefox_not_allowed`, `appcontrol_repair_failed` |

The same run preserved all positive evidence: approved Firefox executed; all
three Edge entry points were denied; arbitrary executables in Downloads,
Desktop, and LocalAppData/Temp were denied; student PowerShell was denied with
an AppLocker block event; and both administrator recovery probes passed.
`studentFailures` and `adminFailures` were zero.

Post-probe health was independently serialized as `Healthy=true`,
`WatchdogHealthy=true`, `AppControlHealthy=true`, with no reason codes. The
external reset then removed the temporary profile. Direct post-run inspection
confirmed zero OpenPath and browser-boundary tasks, no `C:\OpenPath`, no
`OpenPath-Restricted` group, and stopped AppIDSvc.

The completion JSON does not embed a source SHA. The exact association is the
clean local HEAD used to build the overlay plus the SHA-labelled artifact
directory, rather than an in-artifact identity field.

The direct-runner helper could not delete either attempt's overlay directory
immediately because Windows kept `direct-student-flow.err.log` open. The local
collected artifacts were restricted to directory mode 0700 and file mode 0600.
No associated task or process was visible, but the two exact temporary overlay
directories remained present during the final inspection. Product state was
reset; complete temporary-filesystem cleanup remains an operational follow-up.
