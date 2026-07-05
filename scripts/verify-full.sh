#!/usr/bin/env bash

set -euo pipefail

export OPENPATH_VERIFY_HEAD="${OPENPATH_VERIFY_HEAD:-HEAD}"

if [[ -z "${OPENPATH_VERIFY_BASE:-}" ]]; then
  if git rev-parse --verify --quiet origin/main >/dev/null; then
    OPENPATH_VERIFY_BASE="$(git merge-base origin/main "$OPENPATH_VERIFY_HEAD")"
  elif git rev-parse --verify --quiet HEAD~1 >/dev/null; then
    OPENPATH_VERIFY_BASE="HEAD~1"
  else
    OPENPATH_VERIFY_BASE=""
  fi
  export OPENPATH_VERIFY_BASE
fi

npx concurrently --group --names 'static,checks,security' 'npm:verify:static' 'npm:verify:checks' 'npm:verify:security'
npm run verify:coverage
npm run verify:unit

# E2E stage: unconditional by default. Path-scoped ONLY when the pre-push hook provided the
# pushed range (OPENPATH_PREPUSH_REMOTE_SHA / OPENPATH_PREPUSH_LOCAL_SHA); a manual
# `npm run verify:full` never sets those variables and always runs e2e. The scope check prints
# its per-file reasoning to stderr; only a clean `skip` on stdout skips (crash -> run).
if [[ "${OPENPATH_VERIFY_E2E:-}" == "1" ]]; then
  echo "e2e: RUN (forced by OPENPATH_VERIFY_E2E=1)"
  npm run e2e:full
elif [[ -n "${OPENPATH_PREPUSH_REMOTE_SHA:-}" && -n "${OPENPATH_PREPUSH_LOCAL_SHA:-}" ]]; then
  e2e_scope_decision="$(node scripts/e2e-scope-check.mjs || echo run)"
  if [[ "$e2e_scope_decision" == "skip" ]]; then
    echo "e2e: SKIP (scope report above; force with OPENPATH_VERIFY_E2E=1 git push)"
  else
    npm run e2e:full
  fi
else
  npm run e2e:full
fi
