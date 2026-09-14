# AppControl Browser Inventory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make compatibility-mode AppLocker deny discovered unapproved browsers and portable executables with valid AppLocker paths while preserving managed applications and surfacing degraded inventory.

**Architecture:** `Browser.Inventory.psm1` remains the single discovery owner and returns normalized executable identities plus completeness diagnostics. `AppControl.psm1` consumes that result to build deterministic owned rules; its existing policy comparison makes watchdog health detect inventory drift and reconcile only when desired rules change.

**Tech Stack:** Windows PowerShell 5.1, Pester, AppLocker XML.

---

### Task 1: Normalize canonical browser discovery

**Files:**

- Modify: `windows/lib/Browser.Inventory.psm1`
- Test: `windows/tests/Windows.Browser.Inventory.Tests.ps1`

- [ ] Add failing Pester coverage for custom `InstallLocation`, `DisplayIcon`, App Paths, normalized family/path/source, and degraded registry reads.
- [ ] Run `Windows.Browser.Inventory.Tests.ps1`; expect the new assertions to fail because executable identities and discovery status are absent.
- [ ] Extend the inventory result with `ExecutableIdentities`, `DiscoveryStatus`, and `DiscoveryErrors`; keep all path derivation in this module.
- [ ] Re-run the focused inventory suite; expect PASS.

### Task 2: Generate deterministic compatibility policy

**Files:**

- Modify: `windows/lib/AppControl.psm1`
- Test: `windows/tests/Windows.AppControl.Tests.ps1`

- [ ] Add failing coverage proving a discovered custom Edge path becomes a deny, approved Firefox does not, and versioned paths normalize to a stable narrow wildcard.
- [ ] Add failing coverage proving policy paths contain only AppLocker variables and include `%OSDRIVE%\\Users\\*` writable roots plus `%REMOVABLE%\\*` and `%HOT%\\*` denies while retaining `%PROGRAMFILES%\\*`.
- [ ] Run the focused AppControl suite; expect the new assertions to fail on the current static/environment-variable policy.
- [ ] Import canonical inventory, consume its executable identities, replace unsupported variables, and preserve static known-browser fallbacks as defense in depth.
- [ ] Re-run the focused AppControl suite; expect PASS.

### Task 3: Detect drift and expose degraded inventory health

**Files:**

- Modify: `windows/lib/AppControl.psm1`
- Modify: `windows/lib/internal/Watchdog.Runtime.ps1`
- Test: `windows/tests/Windows.AppControl.Tests.ps1`
- Test: `windows/tests/Windows.Watchdog.Tests.ps1`

- [ ] Add failing tests that inventory degradation yields `appcontrol_browser_inventory_degraded` and that a changed custom-browser inventory makes the current policy unhealthy.
- [ ] Run focused suites; expect failure because inventory health is not represented.
- [ ] Add the reason code to structured health and watchdog mapping; rely on existing managed-rule replacement and post-repair verification to converge without rewriting a healthy policy.
- [ ] Re-run both focused suites; expect PASS.

### Task 4: Document and verify the boundary

**Files:**

- Modify: `windows/README.md`
- Modify: `docs/testing/student-policy-contract-matrix.md`

- [ ] Document compatibility-root trust, discovered-browser ownership, removable execution denial, and remaining discovery limits.
- [ ] Run focused Pester suites, source contract tests, and `npm run verify:quick`; expect PASS.
- [ ] Run the authorized real-Windows focused lane if runner exclusivity is available; record runtime decisions separately from local contract evidence.
