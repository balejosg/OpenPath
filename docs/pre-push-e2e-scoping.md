# Pre-push E2E Scoping

The pre-push hook runs `npm run verify:full`. Every stage of it -- static, checks, security,
coverage, unit -- runs unconditionally on every push. Only the final e2e stage (`e2e:full`:
Docker Postgres + drizzle migrate/seed + shared/api/react-spa builds + the react-spa Playwright
suite) is path-scoped: it is skipped when, and only when, every changed file in the pushed range
matches a conservative e2e-irrelevant allowlist.

## Mechanism

1. `.husky/pre-push` reads the githooks(5) stdin ref list
   (`<local-ref> <local-sha> <remote-ref> <remote-sha>`, one line per pushed ref) before anything
   else can consume it. For exactly one pushed ref it exports `OPENPATH_PREPUSH_LOCAL_SHA` and
   `OPENPATH_PREPUSH_REMOTE_SHA`; for zero or multiple refs it exports nothing.
2. `scripts/verify-full.sh` consults `scripts/e2e-scope-check.mjs` ONLY when both variables are
   set. A manual `npm run verify:full` never sets them, so it always runs e2e.
3. `scripts/e2e-scope-check.mjs` (thin CLI over `scripts/lib/e2e-scope.mjs`) resolves the changed
   files via `git diff --name-only --no-renames -z <remote-sha>..<local-sha>` and prints the
   decision: stdout carries exactly `run` or `skip`; stderr explains why, including the matched
   allowlist rule for every changed file. Anything other than a clean `skip` -- including a crash
   of the scope check itself -- runs e2e.

## Allowlist (first match wins)

| Rule         | Why it is provably e2e-irrelevant                                                                                                                                                                                                          |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `docs/**`    | Never imported, built, or served by the e2e chain.                                                                                                                                                                                         |
| `**/*.md`    | Markdown is never imported, built, or served.                                                                                                                                                                                              |
| `linux/**`   | Zero references from `react-spa/e2e/**`, `scripts/e2e-setup.sh`, or `scripts/start-api-e2e.sh`; the linux raw-text contract tests run unconditionally in verify:checks/verify:unit, and CI runs real linux e2e lanes on `linux/**` pushes. |
| `windows/**` | Same as linux; Pester and `windows-e2e.bats` lanes are CI-side.                                                                                                                                                                            |
| `.github/**` | Workflows never execute in the local lane; workflow text is guarded by the unconditional `tests/repo-config/workflow-contracts.test.mjs`.                                                                                                  |

Everything else -- `react-spa/**`, `shared/**`, `api/**`, `scripts/**`, `patches/**`, root
`package.json`/`package-lock.json`, `docker-compose.test.yml`, tsconfigs, `.husky/**`,
`dashboard/**`, `firefox-extension/**`, root `tests/**` -- runs e2e. Some of those are known to be
e2e-irrelevant too, but they stay off the allowlist deliberately: there is NO CI Playwright
backstop (no workflow runs the react-spa Playwright suite), so the local hook is the only gate and
the allowlist must stay minimal and evidence-derived.

## Fail-safe semantics (any doubt -> RUN)

- `OPENPATH_VERIFY_E2E=1 git push` forces e2e regardless of the diff.
- New remote ref (zero remote SHA), ref deletion (zero local SHA), malformed SHAs -> RUN.
- Remote SHA not present locally, `git diff` failure, empty diff -> RUN.
- Multi-ref push or missing range variables -> RUN.
- Scope-check crash (non-zero exit, garbled stdout) -> RUN.

## Downstream release gates

A push whose whole range is docs/markdown does not trigger the `CI` or `E2E Tests` workflows
(their `paths:` filters exclude it), so such SHAs carry NO `CI Success` / `E2E Summary`
check-runs -- absent, not green. Downstream release gates that require check-runs on an exact
pinned SHA must not pin a docs-only SHA; pin the newest SHA whose CI actually ran.

## Extending the allowlist

Add a rule only with evidence that the path is outside the e2e:full dependency chain (read the
Playwright specs' imports and the two e2e shell scripts), then update, in one commit:
`E2E_IRRELEVANT_RULES` in `scripts/lib/e2e-scope.mjs`, the rule-list assertion in
`tests/e2e-scope-check.test.mjs`, this table, and the `## Hook Behavior` bullet in `AGENTS.md`.

## Measuring the win

```bash
time git push origin main 2>&1 | tee /tmp/prepush-timing.log
grep -E "e2e scope:|e2e: SKIP|e2e: RUN" /tmp/prepush-timing.log
```

Compare a mixed push (e2e runs) against a docs-only push (e2e skipped); the delta is the full
`e2e:full` stage. Measured results are recorded below by the rollout of this feature.

## Measured results
