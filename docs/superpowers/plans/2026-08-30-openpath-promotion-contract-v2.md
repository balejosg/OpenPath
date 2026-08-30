# OpenPath Promotion Contract v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make OpenPath publish one exact, deterministic, immutable Promotion Contract v2 certifying the compatible Linux, Windows, and browser-policy artifact set for a source SHA.

**Architecture:** Preserve the existing v1 builder and path during migration. Add pure Node modules for canonical release-input inventories, v2 schema/serialization, physical provenance, inheritance, and immutable publication; workflows only collect evidence, invoke those modules, and publish `gh-pages/promotion-contracts/v2/<full-sha>.json`.

**Tech Stack:** Node.js ESM, `node:test`, SHA-256, GitHub Actions YAML, APT `Packages` metadata, GitHub Releases API, and the existing Debian/Windows/Firefox producers.

---

### Task 1: Add failing v2 schema and publication tests

**Files:**

- Modify: `tests/openpath-promotion-contract.test.mjs`

- [ ] Add a complete v2 fixture and assert the issue-defined object shape, exact key order, trailing newline, and byte-stable repeated serialization.
- [ ] Add failures for non-lowercase/short SHA, invalid SHA-256, unsupported APT suite, missing interface/component fields, mismatched Windows release tag, and volatile fields.
- [ ] Add temporary-directory tests for immutable create, identical retry success, and conflicting retry failure without replacing the original.
- [ ] Run `node --test tests/openpath-promotion-contract.test.mjs`; the new tests must fail before implementation while the existing v1 tests stay green.

### Task 2: Add failing canonical fingerprint tests

**Files:**

- Create: `tests/openpath-release-inputs.test.mjs`

- [ ] Test stable POSIX-relative ordering and canonical inventories for Linux, Windows offline installer, and browser policy.
- [ ] Verify that build scripts, manifests, packaging files, workflow/action configuration, runtime files, and `windows/offline-installer/payload-pins.json` are included.
- [ ] Change representative relevant bytes and assert the corresponding fingerprint changes; change documentation and assert component fingerprints do not.
- [ ] Run `node --test tests/openpath-release-inputs.test.mjs`; it must fail because the module does not exist.

### Task 3: Implement canonical release-input fingerprints

**Files:**

- Create: `scripts/openpath-release-inputs.mjs`
- Test: `tests/openpath-release-inputs.test.mjs`

- [ ] Export `RELEASE_COMPONENTS`, `listReleaseInputFiles({ repoRoot, component })`, `computeReleaseInputFingerprint({ repoRoot, component })`, and `classifyReleaseInputPath(relativePath)`.
- [ ] Define the component inventories centrally, including shared inputs where they can alter the produced artifact, and deduplicate overlaps.
- [ ] Ignore generated/build output and repository metadata; fail closed when a declared required input is missing.
- [ ] Hash sorted normalized paths plus framed file size and bytes, never timestamps or runner data; return lowercase 64-character SHA-256.
- [ ] Run the focused fingerprint test and confirm PASS.

### Task 4: Implement v2 schema, provenance, inheritance, and immutability

**Files:**

- Modify: `scripts/openpath-promotion-contract.mjs`
- Modify: `tests/openpath-promotion-contract.test.mjs`

- [ ] Keep `buildOpenPathPromotionContract()` and the existing `write` CLI v1-compatible; add separate v2 builder/validator/serializer/CLI APIs.
- [ ] Validate exact lowercase source SHA/SHA-256 formats, generic interface versions, required Linux/Windows/browser fields, and `scripts-v<version>-<sourceSha[0:7]>`.
- [ ] Implement canonical v2 serialization with the issue-defined key order and no volatile fields.
- [ ] Implement `resolveComponentInheritance()`: copy a previous component only when the current canonical `inputsSha256` matches; otherwise require a complete current component; require all three current components for bootstrap.
- [ ] Implement pure APT verification requiring suite, package, exact version, filename, stanza SHA-256, and downloaded-byte SHA-256.
- [ ] Implement pure Windows verification requiring exact tag target, release, template/sidecar, payload-manifest asset, and matching bytes.
- [ ] Implement `writeImmutablePromotionContract()` with create/identical-success/different-fail semantics.
- [ ] Run `node --test tests/openpath-promotion-contract.test.mjs` and confirm PASS.

### Task 5: Add failing workflow contract tests

**Files:**

- Modify: `tests/repo-config/workflow-contracts.test.mjs`
- Modify: `tests/install.bats`

- [ ] Assert the new workflow checks out the requested exact SHA, requires same-SHA evidence, computes canonical fingerprints, resolves first-parent v2 inheritance, verifies physical artifacts before publication, and writes only the full-SHA v2 path.
- [ ] Assert release-scripts tag publication checks existing remote targets, creates at the exact SHA, verifies after push, and contains no permissive tag `continue-on-error` or ignored push failure.
- [ ] Assert existing v1 Debian publication remains present and canonical input/provenance scripts are called instead of duplicating classifiers.
- [ ] Run the workflow tests before workflow changes and confirm the new assertions fail.

### Task 6: Add the aggregator workflow and harden producers

**Files:**

- Create: `.github/workflows/publish-promotion-contract.yml`
- Modify: `.github/workflows/release-scripts.yml`
- Modify: `.github/workflows/reusable-deb-publish.yml`
- Modify only as needed: `.github/workflows/build-deb.yml`, `.github/workflows/prerelease-deb.yml`

- [ ] Add manual/reusable exact-SHA inputs, full-history checkout, gh-pages checkout, non-cancelling concurrency, and same-SHA quality gates.
- [ ] Calculate all canonical fingerprints and resolve only an OpenPath first-parent v2 contract; never use latest/current/main or downstream state.
- [ ] For changed components consume existing producer outputs and invoke Node physical verifiers; for unchanged components inherit only after fingerprint equality; fail before writing on any missing/mismatched bytes.
- [ ] Serialize once and publish through the immutable writer at `gh-pages/promotion-contracts/v2/<full-sha>.json`; commit/push only that exact file.
- [ ] Replace release-scripts permissive tag logic with exact remote-target checks and verify existing release assets before idempotent success; do not reimplement packaging.
- [ ] Keep Debian v1 output semantically unchanged and make any new evidence additive.
- [ ] Run `node --test tests/repo-config/workflow-contracts.test.mjs` and `cd tests && bats install.bats`; both must pass.

### Task 7: Document the v2 contract

**Files:**

- Create: `docs/openpath-promotion-contract-v2.md`
- Modify: `docs/INDEX.md`
- Modify: `docs/contract-tests.md`

- [ ] Document the exact URL, schema, generic interface versions, canonical fingerprints, first-parent inheritance, physical verification, immutable publication, exact-SHA consumer rule, and v1 migration coexistence.
- [ ] Keep the documentation OpenPath-only and record every new source-text guard in the contract-test inventory.
- [ ] Run `npx prettier --write docs/openpath-promotion-contract-v2.md docs/INDEX.md docs/contract-tests.md` and `npm run verify:docs`.

### Task 8: Verify and land

**Files:** all implementation files above; no unrelated generated files

- [ ] Run focused contract, fingerprint, workflow, and Bats tests.
- [ ] Run `npm run verify:quick`, `npm run verify:checks`, and `npm run verify:affected` from `OpenPath/`; classify failures through `../scripts/validate-hypothesis.sh openpath local` when needed.
- [ ] Inspect the diff for v1 compatibility, exact v2 bytes, no downstream terminology, and no publication bypasses.
- [ ] Commit on `main` with hooks enabled using `feat(release): publish promotion contract v2`; do not push, release, or close the issue as part of this task.
