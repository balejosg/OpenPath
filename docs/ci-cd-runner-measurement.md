# CI/CD Runner Measurement

> Status: maintained
> Applies to: OpenPath CI/E2E timing, artifact evidence, and controlled runner follow-up
> Last verified: 2026-04-29
> Source of truth: `docs/ci-cd-runner-measurement.md`

Use this runbook when continuing CI optimization work. It replaces temporary
planning notes as the durable place to record how OpenPath runner timing is
measured.

## Test Portfolio Baseline

The current OpenPath test portfolio follows a practical test pyramid rather
than a pure unit-heavy shape. Source-local unit tests cover API, SPA, shared,
dashboard, and extension logic. Integration and contract tests remain a large
middle layer because endpoint behavior depends on Linux services, Windows
services, browser policy, packaging, and delivery artifacts that unit tests
cannot prove.

Latest tracked-test inventory, excluding fixtures, snapshots, generated
artifacts, and local worktrees:

| Component                  |                  Unit | Integration / contract |                           E2E / target platform |
| -------------------------- | --------------------: | ---------------------: | ----------------------------------------------: |
| API                        | 167 files / 477 cases |    11 files / 30 cases |                       Covered by endpoint flows |
| React SPA                  | 106 files / 736 cases |                      - |                             9 files / 122 cases |
| Shared                     |  11 files / 196 cases |                      - |                                               - |
| Dashboard proxy            |    2 files / 14 cases |                      - |                                               - |
| Firefox extension          |  26 files / 108 cases |    12 files / 46 cases |    Covered by delivery and student-policy flows |
| Linux agent                |                     - |   21 files / 409 cases |   Covered by Linux E2E and student-policy lanes |
| Windows agent              |                     - |   21 files / 214 cases | Covered by Windows E2E and student-policy lanes |
| Repo and release contracts |                     - |     5 files / 70 cases |                              8 files / 81 cases |

The inventory is intentionally file- and case-count based. Use it to spot
portfolio drift, not as an exact assertion count.

## Component Quality-Speed Policy

Use the smallest layer that proves the risk:

- API changes should start with focused Node tests and add integration only
  for database, authentication, token delivery, public request, SSE, or
  cross-route authorization boundaries. Do not turn API-only regressions into
  browser E2E unless the bug crosses into an installed endpoint or browser.
- React SPA changes should keep most behavior in Vitest component, hook, and
  public-surface tests. Playwright should stay focused on smoke, auth, domain
  management, visual, and performance coverage instead of duplicating every UI
  branch.
- Shared and dashboard changes should remain unit-first. Dashboard is allowed a
  small contract surface while it stays a thin proxy, but new route or client
  behavior needs a focused test.
- Firefox extension changes should prefer unit and contract coverage for
  background logic, native-host messaging, manifest policy, and release
  artifacts. Release readiness must prove the managed payload and force-install
  path, not only the existence of browser policy files.
- Linux agent changes should keep BATS as the primary integration layer. Add
  focused BATS tests for pure shell helpers, and reserve APT, installer, and
  student-policy lanes for packaging, service, DNS, firewall, and browser-policy
  risks.
- Windows agent changes should keep Pester as the fast contract layer and use
  Windows Student Policy as the required target-platform proof. Hosted Windows
  Pester is now a second required gate after repeated samples showed stable
  runner teardown behavior, but it does not replace self-hosted target-platform
  coverage.

When selecting a first hypothesis-check lane from the shared Linux workspace,
prefer `../scripts/validate-hypothesis.sh openpath windows-direct` over GitHub
workflow fan-out if the question is Windows-targeted and only needs the
runner/platform signal. Reserve `windows-gh` workflow dispatch for
integration-time verification.

Do not expand `.test-allowlist`. It is legacy debt only. When touching an
allowlisted file, either add a focused test or add an explicit `.test-file-map`
entry to an existing split suite.

## What To Measure

For each representative push, record:

- OpenPath commit SHA and workflow run ID.
- Workflow conclusion and total wall-clock time.
- Per-job durations for:
  - `Windows Agent Tests (Pester)`
  - `Windows E2E`
  - `Windows Student Policy`
  - `Linux E2E`
  - `Linux Student Policy`
  - release or package workflows when they are relevant to the change.
- Whether the job waited in queue before starting.
- Runner identity for Windows jobs (`RUNNER_NAME`, `RUNNER_ENVIRONMENT`,
  `RUNNER_OS`) so queue pressure can be separated from test execution time.
- Cache signals from logs, especially npm cache hits and pre-provisioned
  Windows dependency reuse.
- Artifact evidence for diagnostic uploads when the workflow is meant to retain
  artifacts.
- Runner health after the run: runner online, not stuck busy, and reset helper
  completed.

Do not compare a cold runner provisioning sample with a warm steady-state
sample without labeling it as cold or warm.

## GitHub CLI Commands

List current main-branch workflow runs:

```bash
gh run list --repo balejosg/Openpath --branch main --limit 10 \
  --json databaseId,workflowName,headSha,status,conclusion,createdAt,updatedAt
```

Inspect one workflow run:

```bash
gh run view <run-id> --repo balejosg/Openpath \
  --json name,headSha,status,conclusion,createdAt,updatedAt,jobs
```

Compare queued versus executing time for Windows jobs:

```bash
gh run view <run-id> --repo balejosg/Openpath --json jobs \
  --jq '.jobs[] | select(.name | test("Windows")) |
    [.name,.status,.conclusion,.startedAt,.completedAt] | @tsv'
```

Inspect a specific job log for cache and artifact signals:

```bash
gh run view <run-id> --repo balejosg/Openpath --job <job-id> --log \
  | rg -n "Cache hit|Cache restored|Upload .*diagnostics|Artifact|ENOTFOUND|ETIMEDOUT"
```

List retained artifacts:

```bash
gh api repos/balejosg/Openpath/actions/runs/<run-id>/artifacts \
  --jq '.artifacts[] | [.name,.expired,.size_in_bytes,.created_at] | @tsv'
```

## Latest Controlled Windows Baseline

The latest validated OpenPath controlled Windows baseline is:

- Commit: `ecb7a69c` (`ci: restore windows runner before artifact upload`)
- E2E run: `24760799312`
- Workflow conclusion: `success`
- `Windows Student Policy`: `9m45s`
- `Windows E2E`: `3m36s`
- `Linux Student Policy`: `6m44s`
- `Linux E2E (ubuntu-22.04)`: `1m38s`
- `Linux E2E (ubuntu-24.04)`: `1m44s`
- Windows student-policy diagnostic artifact:
  `windows-student-policy-artifacts-24760799312`, retained, `1123977`
  bytes.
- Linux student-policy auto-allow diagnostics now write
  `linux-auto-allow-boundary.json` under
  `tests/e2e/artifacts/linux-student-policy` when SP-006 runs. The artifact
  records `failureBoundary`, ordered `diagnosticPhases`, probe hosts/results,
  remote whitelist, local `/var/lib/openpath/whitelist.txt`, local DNS probes,
  service status, resolver config, and native-host manifest evidence.
- Upload symptom cleared: the Windows diagnostics upload finalized in GitHub
  blob storage without `ENOTFOUND`.

The important implementation detail is the step order in
`.github/workflows/e2e-tests.yml`: `Restore self-hosted Windows runner state`
must run before `Upload Windows student-policy diagnostics`. The reset restores
external DNS before `actions/upload-artifact` contacts GitHub artifact storage.
`tests/repo-config/workflow-contracts.test.mjs` protects that ordering.

## Current Constraint Decision

The current bottleneck is Windows target-platform capacity, not local
pre-commit. The latest measurement set that motivated this decision included:

- OpenPath pre-commit with no staged files: `0.117s`.
- OpenPath `E2E Tests` run `24905419191`: `15m45s` total, with
  `Windows Student Policy` at `11m50s` and `Windows E2E` at `3m37s`.
- OpenPath `CI` run `24905419192`: `16m41s` total, while the Windows Pester
  execution itself was about `52s` and waited behind other Windows work.
- OpenPath prerelease deb/APT run `24906133675`: `7m04s`.
- OpenPath `E2E Tests` run `24923049151` published
  `windows-student-policy-timings.json`; the expensive work was not setup:
  `Build workspaces` was `4.329s`, `Install Selenium dependencies` was
  `1.790s`, and `Ensure test PostgreSQL` was `4.414s`. The two browser passes
  dominated the lane: `Run Selenium student suite (sse)` was `294.908s` and
  `Run Selenium student suite (fallback)` was `266.407s`.

Do not register a second destructive Windows runner process on the same VM while
the host has no spare RAM. That would increase contention on the current
constraint and can corrupt target-platform evidence because the Windows lanes
modify DNS, services, scheduled tasks, browser policy, and client install state.

`test-windows` remains a required `CI Success` input and stays pinned to the
self-hosted OpenPath Windows runner. `test-windows-hosted` is also required and
runs the same isolated Pester helper on GitHub-hosted `windows-2025`, with a
distinct `windows-hosted-results.xml` result path and a short `6m` job timeout.
The earlier hosted advisory samples on runs `24910078474` and `24922725203`
completed Pester and summary steps but stalled during hosted runner
finalization. After the checkpoint restore test stopped leaking real
DNS/firewall/Acrylic side effects, three manual samples on the same workflow
shape and commit `c6e8a98d` reported hosted Pester success without teardown
cancellation: `25110580058`, `25110581352`, and `25110643484`. Hosted Windows is
therefore promoted as an additional required signal, not as a replacement for
self-hosted target-platform coverage.

Windows Student Policy keeps full target-platform evidence on the self-hosted
runner, but only the SSE pass runs the full Selenium matrix. The fallback pass
uses the `fallback-propagation` profile to prove the behavior that differs from
SSE: blocked-page request submission, backend approval, manual/update-based
propagation, and blocked-path enforcement in the installed Windows client. This
exploits the current constraint by removing duplicate browser-matrix work while
preserving a required Windows gate.

After run `25130519857`, the constraint stayed inside `Windows Student Policy`:
the job took about `9m26s`, and `windows-student-policy-timings.json` showed
`Run Selenium student suite (sse, full)` at `356.985s` while the already reduced
fallback proof was `46.919s`. The next optimization therefore narrows the SSE
matrix only for high-confidence single-family diffs. `Detect Relevant Changes`
publishes `windows_student_policy_sse_group`, resolved by
`scripts/select-windows-student-policy-sse-group.mjs`; the Windows runner reads
that value through `OPENPATH_WINDOWS_STUDENT_SSE_GROUP` and still defaults to
`full` for mixed, broad, unknown, runner, workflow, lockfile, shared, runtime, or
Windows-client changes.
The selector also publishes `windows_student_policy_sse_reason` so workflow
summaries record whether the lane used a narrow single-family SSE group, full
target-platform coverage, or a cheap release-infrastructure-only route.

Release-infrastructure-only diffs now stay on the `E2E Summary` evidence path
without consuming destructive target-platform runners. The `Detect Relevant
Changes` job publishes `release_infra_only=true` only when the diff is limited
to release workflows, the release quality-gate helper, or repo-config contract
tests. In that case the expensive Linux and Windows E2E/student-policy lanes
are skipped explicitly; product, runtime, installer, browser, API, shared, and
Selenium changes still route to the full relevant platform lanes.

## Windows Runner Queue Update - 2026-04-29

Change:

- Promoted `Windows Agent Tests (Pester, hosted)` to a required `CI Success`
  input while keeping the self-hosted `Windows Agent Tests (Pester)` lane as
  the pinned Windows target-platform proof.
- Routed release-infrastructure-only diffs to `E2E Summary` so destructive
  Windows lanes stay reserved for product, runtime, installer, browser, API,
  shared, and Selenium changes.

Before:

- `CI` run `25098824685`: `Windows Agent Tests (Pester)` queue `761s`,
  execution `55s`; `Windows Agent Tests (Pester, hosted advisory)` skipped;
  `CI Success` queue `818s`, execution `3s`.
- `E2E Tests` run `25098824712`: `Windows E2E` queue `534s`, execution `225s`.

After:

- `CI` run `25111008847`: `Windows Agent Tests (Pester)` queue `13s`,
  execution `54s`; `Windows Agent Tests (Pester, hosted)` queue `13s`,
  execution `81s`; `CI Success` queue `163s`, execution `4s`.
- `E2E Tests` run `25111008912`: `E2E Summary` queue `14s`, execution `2s`;
  Windows and Linux target-platform lanes skipped because the diff was
  release-infrastructure-only.

## Pipeline Speed Baseline - 2026-05-01

Current evidence:

- `E2E Tests` run `25210255015` for commit
  `b792a7311c01411d4c1473b9af11d8b2dee8e020` succeeded in `9m00s` wall-clock.
  `Detect Relevant Changes` queued `2s` and executed `9s`; `Windows Student
Policy` queued `13s` and executed `522s`; `Linux Student Policy` queued `13s`
  and executed `459s`; `Windows E2E` and matrix `Linux E2E` were explicitly
  skipped; `E2E Summary` executed after the platform lanes in `3s`.
- `CI` run `25210255027` for the same commit succeeded in `1m32s`
  wall-clock. `Detect Relevant Changes` queued `2s` and executed `7s`;
  `Delivery Contracts (Node)` queued `17s` and executed `64s`; both Windows
  Pester lanes and Linux BATS were explicitly skipped by routing; `CI Success`
  queued behind the required job results for `89s` and executed `2s`.

Decision:

- Keep the current narrow Windows student-policy SSE groups. They already route
  high-confidence single-family request lifecycle, AJAX auto-allow,
  path-blocking, and exemption/schedule diffs without weakening full coverage
  for mixed, workflow, runtime, installer, lockfile, shared, or Windows-client
  changes.
- Do not add another destructive Windows lane or split the current pinned
  runner work. The latest representative run still shows the platform work
  itself dominates; additional concurrency on the same VM would weaken the
  target-platform signal.

Policy:

- Keep short Windows unit coverage on hosted Windows only while repeated hosted
  samples stay stable.
- Keep installed-client, DNS, service, and browser-policy evidence on the
  self-hosted Windows runner.

## Decision Rules

- Optimize from repeated representative samples, not one isolated fast or slow
  run.
- Treat GitHub artifact upload failures separately from endpoint behavior when
  local diagnostic files were created and client tests passed.
- Treat a runner that is offline, stuck busy, or unable to pick up jobs as
  runner infrastructure evidence.
- Treat endpoint install, DNS, policy, or self-update failures as product or
  client evidence unless runner health checks show the runner itself failed.
- Keep self-hosted runner usage restricted to trusted repository workflows.
- Treat hosted Windows cancellation after successful Pester output as runner
  infrastructure evidence. Because hosted is now required, `CI Success` must
  fail on that cancellation instead of accepting the Pester assertions alone.
- Do not remove self-hosted Windows coverage from `CI Success` based on hosted
  success. Hosted proves portable Windows capacity; self-hosted proves the
  pinned target platform.

## Remaining Optimization Questions

- Measure sustained queue pressure with the hosted Windows gate before adding
  paid Windows capacity.
- Split `windows-student-policy` into parallel SSE and fallback jobs only if the
  reduced fallback profile still leaves this lane as the workflow bottleneck.
- Consider browser-stack simplification separately from runner provisioning;
  replacing Selenium with Playwright is a larger product-test change, not a
  runner setup task.
