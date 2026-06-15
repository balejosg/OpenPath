# AGENTS.md (Repository Instructions for Coding Agents)

This repository is the standalone OpenPath OSS core: Linux and Windows endpoint agents plus a Node.js/TypeScript monorepo for the API, dashboard proxy, shared contracts, React SPA, and browser extension.

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

If a hook fails, fix the issue and retry. Do not bypass the workflow.

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

- Work on `main`.
- Do not create feature branches or PR branches.
- Do not push from detached HEAD.
- If you need an isolated checkout, use a detached worktree based on `main`.

Technical enforcement lives in `.husky/pre-commit`, `.husky/pre-push`, and `scripts/require-main-branch.sh`.

## Hook Behavior

- `pre-commit`: checks sensitive files and runs staged verification through `scripts/agent-verify.js --staged`
- `commit-msg`: appends `Verified-by: pre-commit`
- `pre-push`: runs `npm run verify:full`

Do not run `npm run verify:full` manually immediately before every push just to duplicate the hook. Run it manually only when debugging a failure or when the user explicitly asks for it.

## Hypothesis Validation Order

Do not use broad CI or release workflows as the first signal for a development hypothesis when a cheaper lane can falsify it first.

Default order:

- focused local suite or `npm run verify:quick`
- direct runner connection for Windows-targeted endpoint, browser-policy, or runtime hypotheses
- broader CI for integrated evidence

From the shared workspace, use `../scripts/validate-hypothesis.sh` when choosing the first pass:

- `../scripts/validate-hypothesis.sh openpath local`
- `../scripts/validate-hypothesis.sh openpath windows-direct`
- `../scripts/validate-hypothesis.sh openpath windows-gh --integration`

Repo-local fallback when the workspace wrapper is unavailable:

- `npm run verify:quick`
- `npm run diagnostics:windows:direct`
- `npm run test:student-policy:windows` on a Windows-capable development machine

On a Windows-capable development environment, prefer focused Pester or `npm run test:student-policy:windows` before waiting on broader workflow fan-out. From the shared Linux workspace, prefer the direct runner lane first; keep `windows-gh --integration` for integration-time verification rather than the default development loop.

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

- Node.js `>= 20`
- npm workspaces from repo root
- `bats` for Bash tests
- PowerShell/Pester for Windows-oriented validation

Common root commands:

- `npm install`
- `npm run build --workspaces --if-present`
- `npm run lint`
- `npm run typecheck`
- `npm test`
- `npm run verify:docs`
- `npm run verify:agent`
- `npm run verify:quick`

### Script Semantics

Script names here do NOT mean the same thing as in ClassroomPath -- do not assume cross-repo symmetry.

| Script                            | What it actually runs                                                                                                                                     | When to use                                                                                                         |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `verify:quick`                    | typecheck + lint + format:check -- **no tests**                                                                                                           | fast feedback on TS/lint changes                                                                                    |
| `verify:checks`                   | lint:shell, format:check, verify:docs, security:files, test:repo-config, test:repo-test-files, verify:migrations:metadata, check:ps-culture (in parallel) | catch repo-structure and shell issues                                                                               |
| `verify:staged`                   | lint-staged (runs on staged files only)                                                                                                                   | manual staged check outside pre-commit hook                                                                         |
| `verify:full`                     | bash scripts/verify-full.sh -- full suite: static, checks, security, coverage, unit, e2e                                                                  | runs automatically as the pre-push hook; [do not run manually before every push](AGENTS.md#hook-behavior)           |
| `verify:docs`                     | node scripts/verify-docs.mjs -- dead links, non-ASCII, INDEX.md coverage                                                                                  | after editing any markdown doc                                                                                      |
| `verify:agent`                    | node scripts/agent-verify.js -- picks fastest lane based on what changed                                                                                  | default agent self-check; used by pre-commit hook                                                                   |
| `verify:affected`                 | verify:quick + tests for workspaces affected by current changes                                                                                           | broader than verify:quick, cheaper than verify:full                                                                 |
| `verify:migrations:metadata`      | api workspace verify:migrations (tsx scripts/verify-migrations.ts + drizzle-kit check)                                                                    | after editing DB migration files                                                                                    |
| `test:repo-config`                | node --test tests/repo-config.test.mjs tests/generate-docker-manifests.test.mjs tests/check-ps-datetime-culture.test.mjs                                  | validates repo-level config contracts                                                                               |
| `test:repo-test-files`            | bash scripts/check-test-files.sh -- enforces every source file has a test file                                                                            | after adding or removing source files                                                                               |
| `docker:manifests`                | node scripts/generate-docker-manifests.mjs -- writes package.docker.json manifests                                                                        | after changing workspace deps or versions                                                                           |
| `docker:manifests:check`          | node scripts/generate-docker-manifests.mjs --check -- verifies manifests are up to date                                                                   | CI or pre-push manifest drift check                                                                                 |
| `check:ps-culture`                | node scripts/check-ps-datetime-culture.mjs -- flags unsafe [DateTime]::Parse calls in .ps1 files                                                          | after editing any PowerShell file                                                                                   |
| `test:shell`                      | `cd tests && bats *.bats` -- runs all Bash bats test files under tests/                                                                                   | after editing Linux shell scripts or bats fixtures                                                                  |
| `test:e2e:smoke`                  | npm run test:e2e --workspace=@openpath/react-spa -- --grep @smoke -- Playwright smoke subset                                                              | fast browser smoke check after SPA changes; requires built react-spa/dist and a running API                         |
| `test:installer:linux`            | bash tests/e2e/ci/run-linux-installer-contracts.sh -- runs Linux installer contract suite in Docker                                                       | after editing linux/ installer scripts or Dockerfiles; requires Docker                                              |
| `test:installer:apt`              | bash tests/e2e/ci/run-linux-apt-contracts.sh -- runs APT helper contract suite in Docker                                                                  | after editing APT helper scripts or apt-bootstrap.sh; requires Docker                                               |
| `lint:shell`                      | `shellcheck --severity=warning linux/lib/*.sh linux/scripts/**/*.sh tests/**/*.sh`                                                                        | after editing any Bash shell script                                                                                 |
| `verify:static`                   | turbo run typecheck lint --parallel -- typechecks and lints all workspaces in parallel                                                                    | faster alternative to verify:quick when you only need type and lint signals across all workspaces                   |
| `verify:unit`                     | npm run build --workspace=@openpath/shared && npm run test:e2e:helpers && turbo run test --parallel -- full unit suite across all workspaces              | before pushing when you need full unit signal without e2e; used inside verify:full                                  |
| `security:files`                  | bash scripts/check-sensitive-files.sh -- checks for sensitive file patterns in the repo                                                                   | runs as part of verify:checks; run directly after adding new config or credential-adjacent files                    |
| `security:secrets`                | secretlint over JS/TS/JSON/YAML/env files -- scans for leaked secrets                                                                                     | runs as part of verify:security; run directly if you added or changed any file with potential secrets               |
| `security:audit`                  | npm audit --audit-level=high piped through check-npm-audit-critical.mjs -- fails on critical vulnerabilities                                              | runs as part of verify:security; run after changing dependencies                                                    |
| `size:check`                      | size-limit check on react-spa/dist -- fails if bundle exceeds configured limit (skipped if dist not built)                                                | after SPA dependency or bundle changes; requires react-spa/dist to be built first                                   |
| `diagnostics:windows:direct`      | node scripts/run-windows-runner-direct.mjs -- connects to the self-hosted Windows runner over SSH and runs diagnostic modes                               | Windows-targeted diagnostics; hits a remote runner VM via SSH, takes 10+ min; use for Windows hypothesis validation |
| `diagnostics:linux-student:local` | node scripts/run-linux-student-policy-local.mjs -- runs the Linux student policy flow locally in Docker                                                   | Linux student-policy hypothesis validation; requires Docker; use for local student-policy flow testing              |

## Testing Guide

Before renaming files or functions, check [`docs/contract-tests.md`](docs/contract-tests.md) to see which tests read those sources as raw text and will break on a rename.

Use the smallest relevant test surface first.

### API

- all: `npm test --workspace=@openpath/api`
- focused: `npm run test:auth --workspace=@openpath/api`
- focused: `npm run test:setup --workspace=@openpath/api`
- focused: `npm run test:e2e --workspace=@openpath/api`
- focused: `npm run test:security --workspace=@openpath/api`

### Dashboard

- all: `npm test --workspace=@openpath/dashboard`

### React SPA

- unit: `npm test --workspace=@openpath/react-spa`
- smoke e2e: `npm run test:e2e:smoke`
- full e2e: `npm run test:e2e`

### Shared

- all: `npm test --workspace=@openpath/shared`

### Firefox Extension

- all: `npm test --workspace=@openpath/firefox-extension`

### Linux Agent Contracts

- shell: `cd tests && bats *.bats`
- installer contracts: `npm run test:installer:linux`
- APT contracts: `npm run test:installer:apt`
- student-policy flow: `npm run test:student-policy:linux`

### Windows Agent Contracts

- student-policy flow: `npm run test:student-policy:windows`
- broader Windows checks run through the Windows test suites under `windows/tests/`

## Knowledge Graph

A pre-built knowledge graph for OpenPath lives at the workspace root:

| File                              | Purpose                                                |
| --------------------------------- | ------------------------------------------------------ |
| `../graphify-out/graph.json`      | Raw graph data                                         |
| `../graphify-out/graph.html`      | Interactive community view -- open in browser          |
| `../graphify-out/GRAPH_REPORT.md` | Full audit report: god nodes, surprises, import cycles |

**Query with code identifiers (function/file/symbol names), not prose questions** -- start-node
matching is literal substring matching on node labels, so a prose question collapses to noise.
Always pass `--graph` explicitly; the default depends on the current working directory.

```bash
# from the workspace root (Whitelist/)
graphify query "bearerAuth" --graph graphify-out/graph.json
graphify query "activate_firewall" --graph graphify-out/graph.json
graphify path "StudentPolicyDriver" "parseTRPC" --graph graphify-out/graph.json
```

If results look irrelevant, grep `graph.json` node labels for your term first, then re-query with
the labels you find. Use `--dfs` to trace a specific path; `--budget 1500` to cap output length.

**Rebuild:** a post-commit hook updates the graph automatically in the background after each
commit (log: `~/.cache/graphify-rebuild.log`). Manual refresh, from the workspace root only
(plain `graphify update` inside `OpenPath/` would create a divergent `OpenPath/graphify-out/`):

```bash
GRAPHIFY_OUT=../graphify-out graphify update OpenPath
```

### God Nodes (highest cross-community coupling -- change with care)

| Symbol                    | Edges | Location                                 |
| ------------------------- | ----- | ---------------------------------------- |
| `parseTRPC()`             | 61    | `api/src/`                               |
| `Write-OpenPathLog()`     | 57    | `windows/lib/internal/Common.System.ps1` |
| `useT()`                  | 48    | `react-spa/src/`                         |
| `StudentPolicyDriver`     | 47    | `windows/`                               |
| `db`                      | 45    | `api/src/db/`                            |
| `bearerAuth()`            | 43    | `api/src/`                               |
| `ScheduleWithPermissions` | 39    | `windows/`                               |

### Known Import Cycles

- **`groupsViewModelActions.ts`** -- 3-file cycle with `groupsViewModelState.ts` and `useGroupsViewModel.ts` (`react-spa/src/hooks/`)
- **`useGroupedRulesManager.ts`** -- 2-file cycle with `useGroupedRulesData.ts` (`react-spa/src/hooks/`, type-only imports)
- **`HierarchicalRulesTable.tsx`** -- 2-file cycle with `rules-table/HierarchicalGroupRow.tsx` (`react-spa/src/components/`, type-only imports)
- Do not add new edges into these cycles; resolve rather than extend them. The type-only cycles can be broken by extracting shared types to a dedicated types file.
- Resolved by type extraction (worked examples of the pattern above): the two `firefox-extension/src/lib/config-storage.ts` cycles were broken by moving `RequestConfig` into `config-storage.types.ts`, and the `native-messaging-client.ts` <-> `runtime-dependency-protocol.ts` cycle by moving `NativeResponse` into `native-response.types.ts`. Each original module keeps a type re-export, so consumers are unchanged.
- Automated guard (ACTIVE): `eslint-plugin-import-x@4.16.2` is installed; `import-x/no-cycle` is enabled at error level for `react-spa/src/**/*.{ts,tsx}` and `firefox-extension/src/**/*.{ts,tsx}` in `eslint.config.js`. `import type` declarations are automatically skipped by the rule (no `ignoreTypeImports` option needed -- it is built-in behaviour in this version). All three remaining cycles listed above produce no lint errors without inline disables, because every back-edge in each cycle is an `import type` statement that the rule skips. If a new runtime (non-type) import is added that closes a cycle, the rule will fire and block `npm run lint`.

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
