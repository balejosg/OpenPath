#!/usr/bin/env bash
################################################################################
# run-linux-contract-scenarios.sh - Host entrypoint for the Linux firewall+DNS
# contract-scenario lane (npm run test:contract:linux).
#
# Thin wrapper over run-linux-e2e.sh --contract-scenarios that pins the
# operational gotchas of this Docker lane: LC_ALL=C (locale-dependent awk/
# printf broke evidence before), a FIXED container name so an interrupted
# previous run's orphan is removed before starting (never pattern-match other
# lanes' containers), and an absolute artifact dir.
################################################################################
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

export OPENPATH_E2E_CONTAINER_NAME="${OPENPATH_E2E_CONTAINER_NAME:-openpath-contract-scenarios}"
export OPENPATH_CONTRACT_ARTIFACT_DIR="${OPENPATH_CONTRACT_ARTIFACT_DIR:-$PROJECT_ROOT/tests/e2e/artifacts/contract-scenarios}"

# Orphan cleanup: remove exactly our fixed-name container from a previous
# interrupted run (run-linux-e2e.sh's cleanup trap handles the current run).
docker rm -f "$OPENPATH_E2E_CONTAINER_NAME" >/dev/null 2>&1 || true

exec bash "$SCRIPT_DIR/run-linux-e2e.sh" --contract-scenarios
