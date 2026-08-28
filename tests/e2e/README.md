# OpenPath E2E and Contract Test Inventory

> Status: maintained
> Applies to: `tests/e2e/`
> Last verified: 2026-04-13
> Source of truth: `tests/e2e/README.md`

This directory holds the repo's cross-platform installation, packaging, and student-policy contract coverage.

## Current Top-Level Suites

- `linux-e2e-tests.sh`
- `agent-integration.bats`
- `Windows-E2E.Tests.ps1`
- `student-flow/*.test.ts`
- `ci/run-linux-e2e.sh`
- `ci/run-linux-apt-contracts.sh`
- `ci/run-linux-installer-contracts.sh`
- `ci/run-linux-student-flow.sh`
- `ci/run-windows-e2e.ps1`
- `ci/run-windows-personalized-offline-installer-e2e.ps1`
- `ci/run-windows-student-flow.ps1`

## What These Tests Cover

- Linux installer/package/runtime contracts
- Windows bootstrap/runtime contracts
- student-policy scenario reconciliation helpers
- required artifact manifests under `validation/`
- the release-scripts Windows lane generates, downloads, executes, and cleans
  up a personalized offline installer through the real HTTP reference flow

## Useful Entry Points

```bash
npm run test:installer:linux
npm run test:installer:apt
npm run test:student-policy:linux
npm run test:student-policy:windows
```

## Windows CI Runner Note

Required Windows Pester coverage uses both the pinned OpenPath self-hosted
Windows runner and GitHub-hosted `windows-2025`. Destructive installer and
student-policy Windows lanes still target the pinned self-hosted runner.

Older GitHub-hosted Windows samples could cancel the Pester lane after `Run Windows Unit Tests` and `Complete job` had both succeeded. Keep that as historical context for old runs rather than evidence of a client regression.

Do not reintroduce descendant process cleanup, WMI process killing, success marker recovery, or timeout-sentinel logic without new upstream runner evidence and maintainer approval.
