# AGENTS.md (Repository Instructions for Coding Agents)

This repository is the standalone OpenPath OSS core: Linux and Windows endpoint agents plus a Node.js/TypeScript monorepo for the API, dashboard proxy, shared contracts, React SPA, and browser extension.

## Workflow Proportionality

Use direct work for bounded changes; delegate only when isolation, specialist work
or independent judgment adds value. Keep one writer. Use skills when explicitly
requested or clearly applicable; generic workflow guidelines do not require extra
design documents, commits or repeat approval for an already-approved narrow change.
Use fuller design work when requirements, architecture or material risks remain
unresolved. Read applicable instructions fully when required and reuse unchanged
context. None of this waives safety checks, required review or final acceptance.

## Dependency Rule

OpenPath must remain agnostic of downstream wrappers, managed distributions, and tenant-specific overlays.

- Do not add imports, configs, env vars, or runtime assumptions that require any downstream wrapper.
- Do not move downstream wrapper logic into OpenPath.
- If functionality is genuinely shared, implement it here as a generic OpenPath capability.

The dependency direction is one-way: `wrapper -> OpenPath`.

## Absolute Prohibitions

These rules have no exceptions for agent work:

- Do not use `git commit --no-verify` or `git commit -n`.
- Do not use `HUSKY=0 git commit`.
- Do not skip failing tests or disable checks just to get a commit through.
- Do not use `@ts-ignore` or broad lint disables as a shortcut around a real problem.
- Do not reintroduce repo-side cleanup hacks for the historical hosted Windows Pester teardown cancellation.

If a hook fails, diagnose it and fix only within authorized scope; report unrelated blockers. Do not bypass the workflow.

## Hosted Windows Pester Teardown History

The required Windows Pester coverage now uses two gates: the pinned self-hosted
OpenPath Windows runner and a GitHub-hosted `windows-2025` runner. Before the
hosted gate was promoted, older hosted samples could cancel after `Run Windows
Unit Tests`, `Record Windows lane outcome`, and `Complete job` had all
succeeded. That cancellation is documented as hosted-runner teardown evidence,
not an OpenPath Windows client regression.

Do not add descendant process cleanup, WMI process killing, success marker
recovery, or timeout-sentinel logic to the Windows Pester lanes as a repo-side
hosted-runner fix. Changing this stance requires new upstream runner evidence
and maintainer approval.

## CI/CD Runner Measurement

For CI speed or runner follow-up work, read
[`docs/ci-cd-runner-measurement.md`](docs/ci-cd-runner-measurement.md) before
changing workflow routing, runner setup, or diagnostic artifact handling. Record
workflow run IDs, per-job durations, cache signals, artifact evidence, and
runner health instead of relying on informal timing notes.

## Branch And Git Policy

OpenPath uses a trunk-based workflow. (canonical: workspace root AGENTS.md "Workspace Rules > Trunk-Based Only")

- Write and commit on `main`; do not create feature branches or PR branches.
- Use an isolated writable checkout on `main` for concurrent implementation.
- Detached worktrees are for read-only inspection; do not commit or push from them.
- Never stash, discard changes or switch a user's checkout automatically to meet
  branch policy. Preserve unexpected state and resolve ownership/authority first.

Technical enforcement lives in `.husky/pre-commit`, `.husky/pre-push`, and `scripts/require-main-branch.sh`.

## Hook Behavior

- `pre-commit`: checks sensitive files and runs staged verification through `scripts/agent-verify.js --staged`
- `commit-msg`: appends `Verified-by: pre-commit`
- `pre-push`: captures the pushed ref range from stdin, then runs `npm run verify:full`. Static,
  checks, security, coverage, and unit stages always run. The e2e stage is skipped only when every
  changed file in the pushed range matches the e2e-irrelevant allowlist in
  `scripts/lib/e2e-scope.mjs` (`docs/**`, `**/*.md`, `linux/**`, `windows/**`, `.github/**`); any
  doubt (new ref, deleted ref, multi-ref push, unresolvable range, non-matching file) means e2e
  runs, and the hook prints the per-file rule matches. Force e2e with
  `OPENPATH_VERIFY_E2E=1 git push`. Details: [`docs/pre-push-e2e-scoping.md`](docs/pre-push-e2e-scoping.md)

Do not run `npm run verify:full` manually immediately before every push just to duplicate the hook. Run it manually only when debugging a failure or when the user explicitly asks for it.

## Hypothesis Validation Order

Do not use broad CI or release workflows as the first signal for a development hypothesis when a cheaper lane can falsify it first. Default order:

1. Focused local suite or `npm run verify:quick`.
2. Direct runner connection for Windows-targeted endpoint, browser-policy, or runtime hypotheses: `npm run diagnostics:windows:direct`, or focused Pester / `npm run test:student-policy:windows` on a Windows-capable machine.
3. Broader CI for integrated evidence.

From the shared workspace the same lanes are `../scripts/validate-hypothesis.sh openpath local` and `openpath windows-direct`. Keep `openpath windows-gh --integration` for integration-time verification rather than the default development loop.

## Repo Map

- `linux/`: Bash endpoint agent (`dnsmasq`, firewall rules, systemd, browser policy helpers)
- `windows/`: PowerShell endpoint agent (Acrylic DNS Proxy, Windows Firewall, Task Scheduler, browser rollout)
- `api/`: Express + tRPC service with PostgreSQL/Drizzle
- `dashboard/`: REST compatibility proxy over API tRPC routes
- `react-spa/`: React SPA and Playwright/Vitest coverage
- `shared/`: shared Zod schemas, helpers, and contract types
- `firefox-extension/`: browser extension and release artifact tooling

Start with:

- [`README.md`](README.md)
- [`CONTRIBUTING.md`](CONTRIBUTING.md)
- [`docs/INDEX.md`](docs/INDEX.md)

## Environment And Tooling

Node.js `>= 20` with npm workspaces from the repo root; `bats` for Bash tests; PowerShell/Pester for Windows-oriented validation. Script bodies live in `package.json`: read them there. This section records only what a script name does not tell you.

### Script Semantics

Script names here do NOT mean the same thing as in ClassroomPath -- do not assume cross-repo symmetry.

- `verify:quick`: typecheck + lint + format:check -- **no tests**. Fast feedback on TS/lint changes.
- `verify:static`: turbo typecheck + lint across all workspaces in parallel; no format check, no tests.
- `verify:affected`: `verify:quick` plus tests for the workspaces affected by current changes; broader than `verify:quick`, cheaper than `verify:full`.
- `verify:agent`: picks the fastest lane for what changed; default agent self-check, also what the pre-commit hook runs.
- `verify:checks`: repo-structure and shell lanes in parallel (shell lint, format, docs, sensitive files, repo-config, test-file coverage, migration metadata, PowerShell culture).
- `verify:unit`: builds `@openpath/shared`, then the full unit suite across all workspaces; no e2e.
- `verify:full`: the pre-push hook suite (static, checks, security, coverage, unit, path-scoped e2e). [Do not run it manually before every push](AGENTS.md#hook-behavior).
- `verify:docs`: dead links, non-ASCII, `docs/INDEX.md` coverage. Run after editing any markdown doc.
- `verify:migrations:metadata`: run after editing DB migration files.
- `test:repo-config`: repo-level config contracts; many read sources as raw text.
- `test:repo-test-files`: enforces that every source file has a test file. Run after adding or removing source files.
- `docker:manifests` / `docker:manifests:check`: write / verify the `package.docker.json` manifests. Run after changing workspace deps or versions.
- `check:ps-culture`: flags unsafe `[DateTime]::Parse` calls. Run after editing any `.ps1` file.
- `lint:shell`: shellcheck at warning severity. Run after editing any Bash script.
- `security:files`, `security:secrets`, `security:audit`: sensitive file patterns, secretlint, and `npm audit` failing on critical vulnerabilities. Run the relevant one after adding config or credential-adjacent files, or changing dependencies.
- `size:check`: bundle size limit; silently skipped unless `react-spa/dist` is built.
- `test:e2e:smoke`: Playwright `@smoke` subset; requires a built `react-spa/dist` and a running API.
- `test:installer:linux`, `test:installer:apt`, `diagnostics:linux-student:local`: require Docker.
- `diagnostics:windows:direct`: runs diagnostic modes on the self-hosted Windows runner over SSH; remote and slow (10+ min).

## Testing Guide

Before renaming files or functions, check [`docs/contract-tests.md`](docs/contract-tests.md) to see which tests read those sources as raw text and will break on a rename.

Use the smallest relevant test surface first.

- Per workspace: `npm test --workspace=@openpath/<name>` for `api`, `dashboard`, `react-spa`, `shared` and `firefox-extension`.
- API: `npm test` is the curated smoke set (what CI unit lanes, turbo, and pre-push run); `npm run test:all --workspace=@openpath/api` runs every suite plus uncovered top-level test files. Focused, same workspace: `test:auth`, `test:setup`, `test:e2e`, `test:security`.
- React SPA e2e: `npm run test:e2e:smoke`, then `npm run test:e2e`.
- Linux agent contracts: `cd tests && bats *.bats`, `npm run test:installer:linux`, `npm run test:installer:apt`, `npm run test:student-policy:linux`.
- Windows agent contracts: `npm run test:student-policy:windows`; broader Windows checks run through the suites under `windows/tests/`.

## Knowledge Graph

A pre-built knowledge graph for OpenPath lives at the workspace root: `../graphify-out/graph.json` (raw data), `graph.html` (interactive community view) and `GRAPH_REPORT.md` (god nodes, surprises, import cycles).

For an exact file or known symbol, read it directly or use targeted `rg`. Use the graph for unknown relationships or broad navigation; its absence is not a blocker and does not authorize a rebuild during read-only work. **Query with code identifiers (function/file/symbol names), not prose questions** -- start-node matching is literal substring matching on node labels, so a prose question collapses to noise. Always pass `--graph` explicitly; the default depends on the current working directory.

```bash
# from the workspace root (Whitelist/)
graphify query "bearerAuth" --graph graphify-out/graph.json
graphify path "StudentPolicyDriver" "parseTRPC" --graph graphify-out/graph.json
```

If results look irrelevant, grep `graph.json` node labels for your term first, then re-query with the labels you find. Use `--dfs` to trace a specific path; `--budget 1500` to cap output length.

A post-commit hook rebuilds the graph in the background after each commit (log: `~/.cache/graphify-rebuild.log`). Manual refresh, from the workspace root only (plain `graphify update` inside `OpenPath/` would create a divergent `OpenPath/graphify-out/`):

```bash
GRAPHIFY_OUT=../graphify-out graphify update OpenPath
```

### God Nodes (highest cross-community coupling -- change with care)

`parseTRPC()` and `bearerAuth()` (`api/src/`), `db` (`api/src/db/`), `useT()` (`react-spa/src/`), `Write-OpenPathLog()` (`windows/lib/internal/Common.System.ps1`), `StudentPolicyDriver` and `ScheduleWithPermissions` (`windows/`). Current edge counts are in `GRAPH_REPORT.md`.

### Known Import Cycles

Three cycles remain, each closed only by `import type` back-edges. Do not add new edges into them; resolve rather than extend, by extracting the shared types to a dedicated types file (as `config-storage.types.ts` and `native-response.types.ts` did in `firefox-extension/src/lib/`).

- `groupsViewModelActions.ts`, `groupsViewModelState.ts` and `useGroupsViewModel.ts` (`react-spa/src/hooks/`)
- `useGroupedRulesManager.ts` and `useGroupedRulesData.ts` (`react-spa/src/hooks/`)
- `HierarchicalRulesTable.tsx` and `rules-table/HierarchicalGroupRow.tsx` (`react-spa/src/components/`)

`import-x/no-cycle` is enabled at error level for `react-spa/src` and `firefox-extension/src` in `eslint.config.js`. The rule skips `import type`, so these three pass without inline disables; a new runtime (non-type) import that closes a cycle fails `npm run lint`.

### Key Cross-Community Bridges

- `normalizeUserRoleString()` -- bridges Role Storage <-> Header/User Context <-> Services; role-normalization changes ripple across all three.
- `getRootDomain()` -- bridges Groups/Whitelist Rules <-> SPA Components.
- `useRulesManagerViewModel()` -- bridges Rules hooks <-> Test utilities.

## Documentation Rules

- Maintained and process docs are English-only.
- Keep maintained docs aligned with repo truth.
- If you add a maintained doc, link it from [`docs/INDEX.md`](docs/INDEX.md).
- Delete obsolete docs instead of leaving contradictory stubs.
- Treat `CHANGELOG.md` and most ADRs as historical context, not current runbooks.
