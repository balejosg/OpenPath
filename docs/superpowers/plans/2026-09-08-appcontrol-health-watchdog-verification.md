# OpenPath #186 verification record

Status: locally verified implementation; target-platform acceptance outstanding.
Independent review approved the final changes without confirmed blockers.
No deployment, push, release, tag, or issue closure has been performed.

## Scope and checkout

Implementation is in the isolated `codex-186-health/health-watchdog/OpenPath`
checkout on `main`, based on `1481869d`. The divergent shared checkout and the
independently claimed browser-boundary E2E files have not been modified.

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

## Outstanding target-platform evidence

Real Windows acceptance still requires positive Firefox/Edge/arbitrary-PE
execution checks and negative health cases for missing policy, task, targeting,
and failed repair, followed by verified restoration. The browser-boundary E2E
paths remain independently claimed by the #253 session. Historical successful
runner results do not validate this implementation's new negative cases.
