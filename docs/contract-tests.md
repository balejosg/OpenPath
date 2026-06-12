# Source-Text Contract Tests

> Status: maintained
> Applies to: OpenPath repository
> Last verified: 2026-06-12
> Source of truth: `docs/contract-tests.md` -- update this file whenever a source-text contract test is added, removed, or its guarded files change.

## What is a source-text contract test?

A source-text contract test opens a file with `readFileSync`, `Get-Content -Raw`, or a bats `grep`, and then asserts that specific strings are present or absent in that file. It is not a functional test -- it does not run the code. It enforces structural invariants: that a function exists, that a workflow step name is spelled a certain way, that a forbidden pattern is absent, or that one string appears before another (ordering assertions).

These tests are fragile in one specific way: they break when someone edits the guarded file without updating the test. The breakage is often silent -- no lint error fires, no type error fires, the rename looks clean -- and the failure only surfaces in CI.

**Golden rule:** before renaming or moving ANY file or function in this repository, run `grep -r 'YourFunctionName' tests/ windows/tests/` first. If any test file references the name as a literal string, update both the source and the test in the same change.

**The comment trap:** a comment or help text that contains a function name literally can satisfy (or break) a needle assertion just as well as the real implementation. If you add `# calls Foo-Bar internally` to a file, and a test needle checks for `Foo-Bar`, that comment will make the test pass -- even if the real function was renamed. Conversely, if you delete a comment that contained a needle string, the test will fail even though the code still works.

---

## Test inventory

Each row describes one test file, the source files it opens for text inspection, the kinds of needles it uses, and what to do when editing the guarded sources.

### tests/repo-config/workflow-contracts.test.mjs

Guards `.github/workflows/ci.yml`, `.github/workflows/e2e-tests.yml`, and a wide range of other workflow and action files.

| Source files read                                              | Needle kinds                                                                                                                                                                                                                                                | Before renaming or editing                                                                             |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `.github/workflows/ci.yml`                                     | Job names, step names, step IDs, shell values (`pwsh`, `bash`), runner labels, output variable names, script paths invoked as strings, ordering assertions (one string must precede another in the file), forbidden strings (patterns that must not appear) | Update the test to match the new job/step name or remove the needle if the contract no longer applies. |
| `.github/workflows/e2e-tests.yml`                              | Job names, step names, workflow dispatch input names and option values, output variable names, path-filter regex patterns, runner labels, script paths invoked as strings, forbidden string assertions                                                      | Same as above.                                                                                         |
| `.github/workflows/verify-trailers.yml`                        | Required step text fragments, env key names, bot actor names                                                                                                                                                                                                | Same as above.                                                                                         |
| `.github/workflows/prerelease-deb.yml`                         | Job names, output names, release quality gate required pairs, ordering assertions                                                                                                                                                                           | Same as above.                                                                                         |
| `.github/workflows/build-deb.yml`                              | Job names, quality gate required pairs, Firefox artifact action path                                                                                                                                                                                        | Same as above.                                                                                         |
| `.github/workflows/security.yml`                               | Action versions, tool versions, scan command fragments, forbidden action versions                                                                                                                                                                           | Same as above.                                                                                         |
| `.github/workflows/release-scripts.yml`                        | Trigger path patterns, quality gate pairs, tag creation ordering                                                                                                                                                                                            | Same as above.                                                                                         |
| `.github/workflows/release-extension.yml`                      | Quality gate pairs, action versions                                                                                                                                                                                                                         | Same as above.                                                                                         |
| `.github/workflows/firefox-release-assets.yml`                 | Output names, artifact path fragments, forbidden version patterns                                                                                                                                                                                           | Same as above.                                                                                         |
| `.github/workflows/reusable-test.yml`                          | Coverage lane names, lane configuration output names, ordering assertions                                                                                                                                                                                   | Same as above.                                                                                         |
| `.github/workflows/coverage.yml`                               | Lane names, reusable workflow path                                                                                                                                                                                                                          | Same as above.                                                                                         |
| `.github/workflows/wedu-captive-portal-lab.yml`                | Step names, runner labels, env key names, script path fragments                                                                                                                                                                                             | Same as above.                                                                                         |
| `.github/workflows/wedu-gateway-healthcheck.yml`               | Check-run name, cron string, step name                                                                                                                                                                                                                      | Same as above.                                                                                         |
| `.github/workflows/wedu-linux-client-smoke.yml`                | Check-run name, absent step name                                                                                                                                                                                                                            | Same as above.                                                                                         |
| `.github/actions/setup-node/action.yml`                        | Action version, cache input names, cache key expressions                                                                                                                                                                                                    | Same as above.                                                                                         |
| `.github/actions/docker-build/action.yml`                      | Action versions                                                                                                                                                                                                                                             | Same as above.                                                                                         |
| `.github/actions/prepare-firefox-release-artifacts/action.yml` | Script names, input names, default values, ordering assertions, forbidden patterns                                                                                                                                                                          | Same as above.                                                                                         |
| `tests/e2e/ci/run-windows-pester-isolated.ps1`                 | Function names, PowerShell expressions, config property names, error messages                                                                                                                                                                               | Rename coordinated with test update.                                                                   |
| `tests/e2e/ci/reset-self-hosted-windows-runner.ps1`            | Function calls, service names, task names, registry fragments                                                                                                                                                                                               | Same as above.                                                                                         |
| `tests/e2e/ci/report-windows-processes.ps1`                    | Parameter set names, WMI class names                                                                                                                                                                                                                        | Same as above.                                                                                         |
| `windows/tests/Windows.Browser.*.Tests.ps1` (five files)       | `BeforeAll` block presence, `Join-Path $PSScriptRoot` pattern                                                                                                                                                                                               | Same as above.                                                                                         |
| `scripts/run-wedu-captive-portal-lab-ci.sh`                    | Function names, lock variable names, env key names, ordering assertions, forbidden patterns                                                                                                                                                                 | Same as above.                                                                                         |
| `scripts/lib/wedu-captive-portal-lab-controller.sh`            | Function names, SSH option names, Python subprocess expressions                                                                                                                                                                                             | Same as above.                                                                                         |
| `scripts/require-release-quality-gate.mjs`                     | Function names, flag names                                                                                                                                                                                                                                  | Same as above.                                                                                         |
| `firefox-extension/sign-firefox-release.mjs`                   | Option string literals                                                                                                                                                                                                                                      | Same as above.                                                                                         |
| `firefox-extension/package.json`                               | `web-ext` pinned version                                                                                                                                                                                                                                    | Bump version in both the package and re-verify.                                                        |
| `api/package.json`                                             | `test:public-requests` script exact value                                                                                                                                                                                                                   | Same as above.                                                                                         |
| `README.md`                                                    | Codecov badge URL fragment                                                                                                                                                                                                                                  | Same as above.                                                                                         |
| `docs/testing/wedu-captive-portal-lab.md`                      | Two specific documentation phrases                                                                                                                                                                                                                          | Keep phrases intact or update test.                                                                    |

**Dangerous needle kinds in this test:**

- **Exact step and job names** (hundreds of `includes()` calls): renaming a workflow step breaks the contract silently outside of tests.
- **Ordering assertions**: `indexOf(A) < indexOf(B)` checks that one block appears before another. Reordering jobs or steps can flip this.
- **Forbidden string assertions**: the test uses `!workflow.includes(...)` to ensure obsolete or prohibited patterns are absent. Adding a comment containing a forbidden pattern will cause the test to fail even if the code is correct.
- **Script path strings**: the test checks that workflow YAML references specific `.ps1` or `.sh` script paths by their exact repo-relative path. Renaming a script requires updating both the YAML and the test.

---

### tests/repo-config/runtime-contracts.test.mjs

Guards scripts, configuration files, and a subset of workflow files for runtime behavior contracts.

| Source files read                                     | Needle kinds                                                                                  | Before renaming or editing                                   |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `scripts/verify-full.sh`                              | Exact `concurrently` invocation string, script names, ordering assertion for coverage vs unit | Rename must preserve the string or update the test.          |
| `.husky/pre-commit`                                   | Step label strings, absent script names                                                       | Same as above.                                               |
| `react-spa/playwright.config.ts`                      | Env var name, worker count                                                                    | Same as above.                                               |
| `scripts/start-api-e2e.sh`                            | npm workspace commands, absent dev-mode command                                               | Same as above.                                               |
| `api/Dockerfile`                                      | Dockerfile syntax comment, `COPY` target paths, cache mount syntax, runtime copy paths        | Same as above.                                               |
| `linux/lib/apt.sh`                                    | Function names, config key strings, error message fragments                                   | Same as above.                                               |
| `linux/lib/common.sh`                                 | Include path string, sourcing order regex                                                     | Same as above.                                               |
| `linux/lib/browser-firefox.sh`                        | APT repository URL, keyring path, pin fragment, ordering regex                                | Same as above.                                               |
| `linux/lib/install-core-steps.sh`                     | Function call presence, forbidden direct `apt-get`                                            | Same as above.                                               |
| `linux/lib/openpath-self-update-package.sh`           | Function call presence                                                                        | Same as above.                                               |
| `linux/lib/firefox-activation-plan.sh`                | Function names                                                                                | Same as above.                                               |
| `linux/scripts/runtime/openpath-browser-setup.sh`     | Function calls, include path, source path strings                                             | Same as above.                                               |
| `linux/scripts/runtime/dnsmasq-watchdog.sh`           | Function call presence                                                                        | Same as above.                                               |
| `linux/scripts/build/apt-setup.sh`                    | Env key, function names, error message                                                        | Same as above.                                               |
| `linux/scripts/build/apt-bootstrap.sh`                | Env key, function names, APT repository fragments, error message                              | Same as above.                                               |
| `tests/e2e/Dockerfile`                                | APT helper copy and source path, function call                                                | Same as above.                                               |
| `tests/e2e/Dockerfile.student`                        | APT helper copy and source path, function call, Firefox edition string, absent version pin    | Same as above.                                               |
| `tests/e2e/Dockerfile.bats-runner`                    | APT helper copy and source path, function call                                                | Same as above.                                               |
| `tests/e2e/ci/run-linux-apt-contracts.sh`             | APT helper copy and source path, function call, cleanup return pattern                        | Same as above.                                               |
| `scripts/check-test-files.sh`                         | Pattern constant name, glob pattern strings, error message fragment                           | Same as above.                                               |
| `scripts/run-changed-coverage.js`                     | CLI flag names, env var names, git command fragments                                          | Same as above.                                               |
| `scripts/check-new-file-coverage.js`                  | CLI flag names, env var names, git command fragments                                          | Same as above.                                               |
| `.github/workflows/ci.yml` (subset)                   | Migration command, forbidden push command                                                     | Same as above.                                               |
| `.github/workflows/build-deb.yml` (subset)            | APT helper invocation, forbidden raw apt-get                                                  | Same as above.                                               |
| `.github/workflows/reusable-deb-publish.yml` (subset) | APT helper invocation                                                                         | Same as above.                                               |
| `.github/workflows/perf-test.yml` (subset)            | APT helper invocation                                                                         | Same as above.                                               |
| `package-lock.json`                                   | Resolved vite version (compared semantically)                                                 | Keep vite above the advisory range or update the comparison. |
| `.release-please-manifest.json`                       | Root version field (compared against git tags)                                                | Keep manifest in sync with tags.                             |
| `api/package.json`                                    | `db:migrate`, `db:push`, `verify:migrations` script values                                    | Same as above.                                               |

**Dangerous needle kinds in this test:**

- **Exact script invocation strings**: `concurrently --group --names 'static,checks,security'` is checked character-by-character. Adding or removing a comma, space, or quote breaks the test.
- **Ordering regex**: `npm run verify:coverage` must appear before `npm run verify:unit` in `verify-full.sh`. Reordering these lines breaks the test.
- **Absent patterns (forbidden)**: `!hook.includes('npm run verify:coverage')` and similar. Adding such a string anywhere in the guarded file -- including in a comment -- will fail the test.
- **Dockerfile `COPY` path strings**: checked exactly, including whether a trailing slash is present.

---

### tests/repo-config/student-policy-contract-matrix.test.mjs

Guards `docs/testing/student-policy-contract-matrix.md`, `docs/INDEX.md`, and `tests/selenium/student-policy-scenarios.ts`.

| Source files read                                | Needle kinds                                                                                                    | Before renaming or editing                                                        |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `docs/testing/student-policy-contract-matrix.md` | Existence check, INDEX link presence, scenario ID regex (`SP-NNN`), table header exact columns, cell population | Adding or removing a Selenium scenario requires a matching matrix row.            |
| `docs/INDEX.md`                                  | Link pattern regex for the matrix file                                                                          | Renaming the matrix file requires updating both the file path and the INDEX link. |
| `tests/selenium/student-policy-scenarios.ts`     | Scenario ID regex to extract IDs (`SP-NNN`, `SP-FB-NNN`, ranges)                                                | Adding scenario IDs in source must have a corresponding matrix entry.             |

---

### tests/repo-config/windows-pester-contracts.test.mjs

Guards `windows/tests/Windows.Common.Mocked.Tests.ps1`, `windows/tests/Windows.Tests.ps1`, `windows/tests/Windows.Installer.Cleanup.Tests.ps1`, and `windows/tests/Windows.AppControl.Tests.ps1`.

| Source files read                                   | Needle kinds                                                                                | Before renaming or editing                                                            |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `windows/tests/Windows.Common.Mocked.Tests.ps1`     | Function names in mock assertions, mock scope (`-ModuleName Common`), exact assertion count | Renaming any of the listed mock targets breaks the regex pattern match.               |
| `windows/tests/Windows.Tests.ps1`                   | Presence of a specific test file name as a quoted string                                    | Renaming a Pester suite file requires updating the aggregate entrypoint and the test. |
| `windows/tests/Windows.Installer.Cleanup.Tests.ps1` | Test description strings, function name                                                     | Same as above.                                                                        |
| `windows/tests/Windows.AppControl.Tests.ps1`        | Test description strings, identifiers                                                       | Same as above.                                                                        |

---

### tests/repo-config/student-policy-contracts.test.mjs

Guards a large number of runner scripts, Selenium sources, workflow files, and documentation for student-policy end-to-end flows.

| Source files read                                     | Needle kinds                                                                                                                                  | Before renaming or editing                                                      |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `tests/e2e/ci/run-windows-student-flow.ps1`           | Function names, parameter names, validate-set values, phase names passed to timing helper, ordering regex, env var names, file path fragments | Renaming any function or phase label requires updating all affected needles.    |
| `tests/e2e/ci/run-linux-student-flow.sh`              | Function names, phase names, env var names, command fragments, ordering assertions                                                            | Same as above.                                                                  |
| `tests/e2e/ci/windows-browser-enforcement.ps1`        | Probe description strings, switch names                                                                                                       | Same as above.                                                                  |
| `tests/e2e/ci/run-windows-browser-boundary-ci.ps1`    | Function names, assertion label strings, ordering regex                                                                                       | Same as above.                                                                  |
| `tests/e2e/Dockerfile.student`                        | Firefox edition string, absent version pin string, package name                                                                               | Same as above.                                                                  |
| `tests/selenium/student-policy-flow.e2e.ts`           | Import path, absent alternative import path                                                                                                   | Same as above.                                                                  |
| `tests/selenium/student-policy-driver.ts`             | Method calls, preference key strings, property names                                                                                          | Same as above.                                                                  |
| `tests/selenium/student-policy-driver-platform.ts`    | curl option string                                                                                                                            | Same as above.                                                                  |
| `tests/selenium/student-policy-harness.ts`            | Profile-to-function mapping, function call                                                                                                    | Same as above.                                                                  |
| `tests/selenium/student-policy-scenarios.ts`          | Function names, scenario label strings, ordering assertions, forbidden patterns                                                               | Same as above.                                                                  |
| `tests/selenium/student-policy-env.ts`                | Absent group name                                                                                                                             | Same as above.                                                                  |
| `windows/lib/Update.Runtime.psm1`                     | Function signature with parameter, ordering regex across function boundaries                                                                  | Same as above.                                                                  |
| `scripts/select-windows-student-policy-sse-group.mjs` | Absent group names, flag name                                                                                                                 | Same as above.                                                                  |
| `tests/contracts/browser-chromium-policy.json`        | Deep-equal of `googleGameBlocks` array                                                                                                        | Changing the policy requires updating the JSON contract and the test assertion. |
| `windows/lib/Browser.psm1`                            | Loop variable name referencing spec property                                                                                                  | Same as above.                                                                  |
| `windows/lib/Browser.RequestReadiness.psm1`           | Function name                                                                                                                                 | Same as above.                                                                  |
| `.github/workflows/e2e-tests.yml` (subset)            | Step name ordering, env key names, artifact path                                                                                              | Same as above.                                                                  |
| `docs/testing/student-policy-contract-matrix.md`      | Evidence rung phrase                                                                                                                          | Same as above.                                                                  |
| `windows/README.md`                                   | Phase labels, documentation prohibition phrase                                                                                                | Same as above.                                                                  |

---

### tests/windows-runner-direct.test.mjs

Mostly behavioral (spawns the script with `--dry-run`). Also reads:

| Source files read                                   | Needle kinds                  | Before renaming or editing                                       |
| --------------------------------------------------- | ----------------------------- | ---------------------------------------------------------------- |
| `scripts/run-windows-runner-direct.mjs` (via spawn) | CLI flag names, output format | Renaming flags requires updating the test's expected token list. |
| `scripts/lib/windows-direct-diagnostic-modes.mjs`   | Mode names (via import)       | Adding or removing modes requires updating the test.             |
| Various repo-config support (via `readText`)        | Script name references        | Same as above.                                                   |

---

### tests/wedu-captive-portal-harness-contract.test.mjs

| Source files read                                             | Needle kinds                                                                                                                             | Before renaming or editing                                                       |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `tests/e2e/ci/run-windows-captive-portal-wedu-lab.ps1`        | Function names, boolean property names in success expression, absent function names, absent gateway control patterns, via-string literal | Renaming a function or property in the harness requires coordinated test update. |
| `windows/lib/CaptivePortal.psm1`                              | Function names, dot-source path string, export list presence, absent top-level function definition                                       | Same as above.                                                                   |
| `windows/lib/internal/CaptivePortal.DiagnosticsDiscovery.ps1` | Function name as top-level definition                                                                                                    | Same as above.                                                                   |
| `windows/lib/internal/NativeHost.Actions.CaptivePortal.ps1`   | Function name as section delimiter for slice                                                                                             | Same as above.                                                                   |

---

### tests/wedu-captive-portal-diagnostics-script.test.mjs

| Source files read                                          | Needle kinds                                                                                                                                    | Before renaming or editing |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| `windows/scripts/Collect-WeduCaptivePortalDiagnostics.ps1` | Function names, task name string literals, absent alternative command form, switch name, progress message strings, absent forbidden DNS command | Same as above.             |

---

### tests/generate-docker-manifests.test.mjs

| Source files read                                                                                                        | Needle kinds                                                                                    | Before renaming or editing                                                                                             |
| ------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Committed Docker manifest files (paths enumerated by `DOCKER_MANIFEST_CASES` in `scripts/generate-docker-manifests.mjs`) | Exact file content equality -- the committed file must match the generator output byte-for-byte | Changing any package manifest that feeds Docker manifests requires regenerating the committed files via the generator. |

---

### tests/windows-e2e.bats

Greps over Windows installer scripts, `scripts/Update-OpenPath.ps1`, `windows/lib/ScriptBootstrap.psm1`, `windows/lib/Update.Runtime.psm1`, `.github/workflows/e2e-tests.yml`, and several `tests/e2e/ci/*.ps1` helper files.

| Source files read (via grep)                          | Needle kinds                                                                                                                             | Before renaming or editing |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| `tests/e2e/ci/run-windows-e2e.ps1`                    | Installer invocation flags, function names, DNS retry call site, Acrylic diagnostic logging patterns, required/optional restart patterns | Same as above.             |
| `windows/Install-OpenPath.ps1`                        | ASCII-only check (grep for non-ASCII bytes)                                                                                              | Keep file ASCII.           |
| `windows/Uninstall-OpenPath.ps1`                      | ASCII-only check                                                                                                                         | Same as above.             |
| `windows/scripts/Pre-Install-Validation.ps1`          | ASCII-only check                                                                                                                         | Same as above.             |
| `windows/scripts/Update-OpenPath.ps1`                 | Module import lines, function call lines                                                                                                 | Same as above.             |
| `windows/lib/ScriptBootstrap.psm1`                    | Module load pattern, global import pattern                                                                                               | Same as above.             |
| `windows/lib/Update.Runtime.psm1`                     | Module import line, function name string                                                                                                 | Same as above.             |
| `windows/scripts/Enroll-Machine.ps1`                  | Bootstrap import, session init call, module flag, function name strings                                                                  | Same as above.             |
| `windows/lib/install/Installer.Staging.ps1`           | File name references                                                                                                                     | Same as above.             |
| `windows/lib/internal/NativeHost.ArtifactCatalog.ps1` | File name string literals                                                                                                                | Same as above.             |
| `windows/scripts/OpenPath-NativeHost.ps1`             | Function names, path construction patterns, dot-source call patterns, absent legacy import                                               | Same as above.             |
| `windows/OpenPath.ps1`                                | Module import line, error message string, function name string                                                                           | Same as above.             |
| `windows/lib/Common.psm1`                             | Sub-module file reference                                                                                                                | Same as above.             |
| `windows/lib/internal/Common.Http.ps1`                | Sub-module file reference                                                                                                                | Same as above.             |
| `windows/lib/internal/Common.Http.Assembly.ps1`       | Function name, assembly load call                                                                                                        | Same as above.             |
| `windows/lib/DNS.psm1`                                | Three sub-module file references                                                                                                         | Same as above.             |
| `windows/lib/internal/DNS.Acrylic.Config.ps1`         | Function names, setting key strings, absent template pattern, absent forbidden DNS pattern                                               | Same as above.             |
| `windows/lib/internal/AcrylicHostsModel.ps1`          | Function names, format string literals                                                                                                   | Same as above.             |
| `windows/lib/internal/AcrylicHostsRenderer.ps1`       | Function name                                                                                                                            | Same as above.             |
| `windows/lib/internal/DNS.Diagnostics.ps1`            | Function name, timing call                                                                                                               | Same as above.             |
| `tests/e2e/ci/acquire-shared-windows-runner-lock.ps1` | Lock path string                                                                                                                         | Same as above.             |
| `.github/workflows/e2e-tests.yml` (subset)            | Absent pre-install step names, lock step names                                                                                           | Same as above.             |

---

### tests/captive-portal.bats, tests/dns.bats, tests/services.bats

These tests source Linux library files directly (`linux/lib/common.sh`, `linux/lib/dns.sh`, `linux/lib/services.sh`) and call their functions under mocked shell environments. They do not use `grep`-based source-text assertions. They are behavioral tests for Linux shell functions, not source-text contract tests.

Note: if a function is renamed in `linux/lib/*.sh`, these tests will fail because the function call no longer resolves -- but the failure mode is a shell error, not a needle miss.

---

### windows/tests/Windows.Watchdog.Tests.ps1

Uses `Get-Content -Raw` extensively.

| Source files read                           | Needle kinds                                                                                                  | Before renaming or editing                                                                             |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `windows/scripts/Test-DNSHealth.ps1`        | Bootstrap import strings, required command name list, function name strings                                   | Same as above.                                                                                         |
| `windows/lib/internal/Watchdog.Runtime.ps1` | Function names, log message strings, absent pattern (`Should -Not -Match`), ordering assertions via `IndexOf` | Renaming a function or reordering blocks in this file can break both presence and ordering assertions. |
| `windows/lib/CaptivePortal.psm1`            | Function body slices via `IndexOf`, ordering assertions, absent patterns                                      | Same as above.                                                                                         |

**Ordering assertions in this test are especially fragile:** `$content.IndexOf('A') | Should -BeLessThan $content.IndexOf('B')` fails if either string moves past the other, even within the same logical function. Do not reorder code blocks in guarded files without checking for `IndexOf` ordering asserts first.

---

### windows/tests/Windows.Browser.NativeHost.Tests.ps1

Uses `Get-Content -Raw` on many internal native-host files.

| Source files read                                               | Needle kinds                                                                           | Before renaming or editing |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------- | -------------------------- |
| `windows/lib/internal/NativeHost.Actions.Bootstrap.ps1`         | Combined with other files via string concatenation; function presence, absent patterns | Same as above.             |
| `windows/lib/internal/NativeHost.Actions.Shared.ps1`            | Combined; function presence, absent patterns                                           | Same as above.             |
| `windows/lib/internal/NativeHost.Actions.RuntimeDependency.ps1` | Combined; function presence                                                            | Same as above.             |
| `windows/lib/internal/NativeHost.Actions.CaptivePortal.ps1`     | Combined; function presence                                                            | Same as above.             |
| `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1`   | Combined; function presence                                                            | Same as above.             |
| `windows/lib/internal/NativeHost.State.ps1`                     | Function presence                                                                      | Same as above.             |
| `windows/lib/internal/NativeHost.Protocol.ps1`                  | (referenced via artifact catalog)                                                      | Same as above.             |
| `windows/lib/Browser.psm1`                                      | Module content assertions                                                              | Same as above.             |
| `windows/lib/RequestSetup.State.psm1`                           | Module content assertions                                                              | Same as above.             |
| `windows/lib/Services.psm1`                                     | Module content assertions                                                              | Same as above.             |
| `windows/lib/internal/TaskHelper.ps1`                           | Function and pattern assertions                                                        | Same as above.             |
| `windows/scripts/OpenPath-NativeHost.ps1`                       | Function names, import call patterns, absent legacy pattern                            | Same as above.             |
| `windows/lib/internal/RuntimeDependency.Protocol.ps1`           | (referenced at test runtime)                                                           | Same as above.             |
| `windows/lib/internal/RuntimeDependency.Queue.ps1`              | (referenced at test runtime)                                                           | Same as above.             |
| `windows/lib/internal/RuntimeDependency.Overlay.ps1`            | (referenced at test runtime)                                                           | Same as above.             |
| `windows/lib/install/Installer.Staging.ps1`                     | (referenced at test runtime)                                                           | Same as above.             |
| `windows/lib/Update.Runtime.psm1`                               | (referenced at test runtime)                                                           | Same as above.             |

**The content-concatenation pattern** in this test is particularly dangerous: several `It` blocks build a virtual combined file by concatenating multiple `Get-Content -Raw` results with newlines, then run regex assertions on the combined string. A function name that appears in any of those files will satisfy the needle, so if the function moves between files the needle may still pass -- but if it is renamed, the needle fails regardless of which file it is in.

---

### scripts/check-ps-datetime-culture.mjs (PS DateTime culture guard)

This is a static source-text check, not a contract test. It scans every tracked `.ps1` and `.psm1`
file for `[DateTime]::Parse(` or `[DateTime]::ParseExact(` calls (case-insensitive) that do **not**
also include `InvariantCulture` on the same line.

**Why it exists:** `[DateTime]::Parse` without an explicit `InvariantCulture` argument silently swaps
day and month on d/M locales such as es-ES. On a Spanish-locale Windows host a date string like
`06/12/2026` is parsed as 12 June instead of 6 December, causing silent data corruption in
captive-portal expiry handling and any other date-aware logic.

**What it flags:** any line matching `[datetime]::(parse|parseexact)(` (case-insensitive) that
lacks `InvariantCulture` on the same line, unless the line or the line directly above it carries a
`# ps-culture-allow: <justification>` comment.

**Escape hatch:** add `# ps-culture-allow: <justification>` on the violating line or the line
immediately above it. Use this only when you have verified the call is locale-safe (for example the
input is a fixed numeric ISO format) and have a test that proves it.

**Where it runs:**

- `npm run check:ps-culture` -- on-demand, full-repo scan
- `verify:checks` -- runs in parallel alongside the other policy checks
- `lint-staged` (`*.{ps1,psm1}`) -- guards every commit that touches PowerShell files

---

## Summary checklist before editing a guarded file

1. From the repo root, run `grep -r 'MyFunctionOrStepName' tests/ windows/tests/` to find all literal needles.
2. Check for `IndexOf` ordering asserts in `windows/tests/Windows.Watchdog.Tests.ps1` and `tests/repo-config/workflow-contracts.test.mjs` if you are reordering blocks.
3. Check for `Should -Not -Match` and `!content.includes(...)` forbidden-string asserts if you are adding new text (including comments).
4. Run `npm run test:repo-config` and `cd tests && bats windows-e2e.bats` locally before pushing.
