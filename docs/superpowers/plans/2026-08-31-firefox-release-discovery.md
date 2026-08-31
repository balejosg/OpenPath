# Firefox Release Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Windows Firefox Release readiness discovery independent of PowerShell process bitness while preserving the existing failure-code contract.

**Architecture:** Keep `Resolve-OpenPathFirefoxReleaseExecutable` as the private string-returning seam used by readiness. Add a private discovery layer in `Browser.FirefoxPolicy.psm1` that reads explicit Registry64/Registry32 views, then known architecture-safe filesystem paths, validates and deduplicates candidates, and returns diagnostics through an optional reference. Readiness includes those diagnostics only for executable-discovery failure; installer runtime-registration behavior remains unchanged.

**Tech Stack:** Windows PowerShell, `Microsoft.Win32.RegistryKey`, Pester 5.7, existing OpenPath browser-policy modules.

---

### Task 1: Add the architecture-mismatch regression test

**Files:**

- Modify: `windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1` in the Firefox policy `Describe` block.

- [ ] **Step 1: Write the failing test**

Add a test that sets the process environment to the exact reported shape and only exposes the native Firefox path:

```powershell
It "Resolves 64-bit Firefox Release from ProgramW6432 under a 32-bit PowerShell process" {
    $environmentNames = @(
        'ProgramFiles',
        'ProgramFiles(x86)',
        'ProgramW6432',
        'PROCESSOR_ARCHITECTURE',
        'PROCESSOR_ARCHITEW6432'
    )
    $previousEnvironment = @{}

    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        [Environment]::SetEnvironmentVariable('ProgramFiles', 'C:\Program Files (x86)', 'Process')
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Program Files (x86)', 'Process')
        [Environment]::SetEnvironmentVariable('ProgramW6432', 'C:\Program Files', 'Process')
        [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'x86', 'Process')
        [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITEW6432', 'AMD64', 'Process')

        Mock Test-Path {
            param([string]$LiteralPath)
            return $LiteralPath -eq 'C:\Program Files\Mozilla Firefox\firefox.exe'
        } -ModuleName Browser.FirefoxPolicy

        $resolved = InModuleScope Browser.FirefoxPolicy {
            Resolve-OpenPathFirefoxReleaseExecutable
        }

        $resolved | Should -Be 'C:\Program Files\Mozilla Firefox\firefox.exe'
    }
    finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
}
```

- [ ] **Step 2: Run the focused test and verify the expected failure**

Run from `OpenPath/`:

```bash
pwsh -NoProfile -Command '& { $c = New-PesterConfiguration; $c.Run.Path = @("windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1"); $c.Filter.FullName = "*Resolves 64-bit Firefox Release from ProgramW6432*"; $c.Run.PassThru = $true; $r = Invoke-Pester -Configuration $c; if ($r.FailedCount -ne 1) { exit 1 } }'
```

Expected: the new test fails because the current resolver returns an empty
string after checking only `ProgramFiles` and `ProgramFiles(x86)`; no
production file has been changed yet.

- [ ] **Step 3: Commit the red test**

```bash
git add windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1
git commit -m "test(windows): reproduce Firefox bitness discovery gap"
```

### Task 2: Implement registered and architecture-safe candidate discovery

**Files:**

- Modify: `windows/lib/Browser.FirefoxPolicy.psm1` around `Resolve-OpenPathFirefoxReleaseExecutable` and its readiness result.

- [ ] **Step 1: Add private registry and candidate helpers**

Implement these private helpers in the module:

- `Get-OpenPathFirefoxReleaseRegistryCandidates`: open HKLM with
  `RegistryView.Registry64` and `RegistryView.Registry32`; inspect
  `SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe` and
  Mozilla Firefox uninstall subkeys; emit candidate path/source records; catch
  inaccessible or unavailable views without failing readiness.
- `ConvertTo-OpenPathFirefoxReleaseExecutablePath`: normalize quoted App Paths
  and `DisplayIcon` values, remove icon indexes, and append `firefox.exe` to a
  registered install directory.
- `Test-OpenPathFirefoxReleaseCandidate`: require a leaf named `firefox.exe`,
  reject `Tor Browser` and `FirefoxPortable` path segments, and verify the
  candidate with `Test-Path -LiteralPath`.
- `Get-OpenPathFirefoxReleaseDiscovery`: concatenate registry candidates before
  the `ProgramW6432`, `ProgramFiles`, and `ProgramFiles(x86)` fallbacks,
  deduplicate case-insensitively, and return `Path`, `Source`, `Checked`, and
  `Rejected` fields.

Use the uninstall display-name identity for normal Mozilla Firefox only; do not
accept ESR, Developer Edition, Nightly, Tor, or portable entries as Firefox
Release. Filesystem fallback paths must remain under the known `Mozilla Firefox`
directory.

- [ ] **Step 2: Preserve the resolver seam and pass diagnostics**

Keep the resolver's normal return value as a string. Add an optional `[ref]`
diagnostics parameter so readiness can capture discovery evidence without
changing existing private-call or mock expectations:

```powershell
function Resolve-OpenPathFirefoxReleaseExecutable {
    param([ref]$Diagnostics)

    $discovery = Get-OpenPathFirefoxReleaseDiscovery
    if ($Diagnostics) {
        $Diagnostics.Value = $discovery
    }
    return [string]$discovery.Path
}
```

Extend the readiness result with a structured `FirefoxDiscovery` property,
retain `firefox-release-missing`, and construct its message from the discovery
source/path lists. Do not add `-RequireRuntimeRegistration` to
`Install-OpenPath.ps1`.

- [ ] **Step 3: Run the decisive test and verify it passes**

Run the same focused command from Task 1. Expected: the test passes and the
existing 20 Firefox policy tests remain green.

- [ ] **Step 4: Commit the minimal implementation**

```bash
git add windows/lib/Browser.FirefoxPolicy.psm1
git commit -m "fix(windows): discover system Firefox across registry views"
```

### Task 3: Add the remaining discovery and diagnostic coverage

**Files:**

- Modify: `windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1`.

- [ ] **Step 1: Add registry-priority and custom-location tests**

Mock the module's registry-candidate seam with Registry64 and Registry32
records, make both filesystem candidates visible, and assert the Registry64
candidate wins, duplicates are checked once, and a registered custom
installation path is accepted when it is a normal Firefox Release path.

- [ ] **Step 2: Add product exclusion and fallback tests**

Cover Firefox x86 through `ProgramFiles(x86)`, reject paths containing `Tor
Browser` and `FirefoxPortable` even when `Test-Path` reports them present, and
return an empty string with stable rejection diagnostics when no valid
candidate exists.

- [ ] **Step 3: Add readiness diagnostic assertions**

Keep the existing `firefox-release-missing` assertion, and additionally assert
that the message contains `Firefox Release executable could not be discovered`
and does not mention policy or runtime registration as the cause. Keep the
existing policy-missing and runtime-registration tests unchanged except for
asserting their distinct failure codes.

- [ ] **Step 4: Run the focused Windows Pester file**

```bash
pwsh -NoProfile -Command '& { $c = New-PesterConfiguration; $c.Run.Path = @("windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1"); $c.Run.PassThru = $true; $c.Output.Verbosity = "Detailed"; $r = Invoke-Pester -Configuration $c; if ($r.FailedCount -gt 0) { exit 1 } }'
```

Expected: all Firefox policy tests pass, including the new registry, fallback,
exclusion, and diagnostic cases.

- [ ] **Step 5: Commit the regression coverage**

```bash
git add windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1
git commit -m "test(windows): cover Firefox Release discovery diagnostics"
```

### Task 4: Run repository verification and inspect the landing state

**Files:**

- No additional files; inspect only the two implementation/test files and the
  approved design/plan documents.

- [ ] **Step 1: Run the cheapest repository checks**

```bash
../scripts/validate-hypothesis.sh openpath local
```

This is the first verification lane. Do not deploy or dispatch broad CI as a
development shortcut. If a Windows-targeted direct runner is needed after the
local Pester evidence, use `../scripts/validate-hypothesis.sh openpath windows-direct`.

- [ ] **Step 2: Inspect the final diff and repository status**

```bash
git diff origin/main...HEAD -- windows/lib/Browser.FirefoxPolicy.psm1 windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1 docs/superpowers/specs/2026-08-31-firefox-release-discovery-design.md docs/superpowers/plans/2026-08-31-firefox-release-discovery.md
git status --short --branch
```

Confirm that no installer runtime-registration semantics, ClassroomPath files,
secrets, tags, releases, or root-workspace changes were introduced.

- [ ] **Step 3: Report evidence precisely**

Report the focused Pester result, repository verification result, exact final
OpenPath HEAD SHA, and limitations (for example, whether a live Windows runner
was required). State the highest completed evidence rung; local tests alone are
`unit/contract test` evidence, not staging or production evidence.
