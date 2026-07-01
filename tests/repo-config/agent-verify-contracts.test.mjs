import { describe, test } from 'node:test';
import assert from 'node:assert/strict';

import { categorizeFiles, planVerificationSteps } from '../../scripts/agent-verify.js';

/**
 * agent-verify.js plans verification steps from a changed-files list.
 *
 * Regression coverage: `npm test` runs via tsx and does NOT typecheck, so a
 * strict/noUncheckedIndexedAccess-class error can pass `npm test` and the
 * pre-commit `agent-verify.js` gate while still breaking `tsc`. These tests
 * assert that any .ts/.tsx change causes a TYPECHECK step (npm run
 * verify:static) to be included in the plan, so that class of bug is caught
 * before push instead of only at the pre-push cross-workspace typecheck.
 */
describe('agent-verify: planVerificationSteps includes a typecheck step for TS changes', () => {
  test('a plain .ts source change plans a TYPECHECK step', () => {
    const steps = planVerificationSteps(['api/src/lib/exemption-storage-query.ts']);

    const typecheckStep = steps.find((step) => step.level === 'TYPECHECK');
    assert.ok(typecheckStep, 'expected a TYPECHECK step in the plan');
    assert.equal(typecheckStep.command, 'npm run verify:static');
  });

  test('a .tsx source change plans a TYPECHECK step', () => {
    const steps = planVerificationSteps(['react-spa/src/views/Users.tsx']);

    assert.ok(
      steps.some((step) => step.level === 'TYPECHECK'),
      'expected a TYPECHECK step in the plan'
    );
  });

  test('a shared .ts change plans STAGED+AFFECTED and TYPECHECK', () => {
    const steps = planVerificationSteps(['shared/src/utils.ts']);

    assert.deepEqual(
      steps.map((step) => step.level),
      ['STAGED+AFFECTED', 'TYPECHECK']
    );
  });

  test('a .test.ts change plans STAGED+AFFECTED and TYPECHECK', () => {
    const steps = planVerificationSteps(['api/tests/exemption-storage-query.test.ts']);

    assert.deepEqual(
      steps.map((step) => step.level),
      ['STAGED+AFFECTED', 'TYPECHECK']
    );
  });

  test('a docs-only change (.md) plans no TYPECHECK step', () => {
    const steps = planVerificationSteps(['docs/INDEX.md']);

    assert.deepEqual(
      steps.map((step) => step.level),
      ['STAGED']
    );
  });

  test('a plain .js change plans STAGED but no TYPECHECK step', () => {
    const steps = planVerificationSteps(['scripts/generate-docker-manifests.mjs']);

    assert.deepEqual(
      steps.map((step) => step.level),
      ['STAGED']
    );
  });

  test('mixed .js and .ts changes still plan a TYPECHECK step', () => {
    const steps = planVerificationSteps(['scripts/foo.mjs', 'api/src/lib/bar.ts']);

    assert.ok(
      steps.some((step) => step.level === 'TYPECHECK'),
      'expected a TYPECHECK step when any changed file is .ts/.tsx'
    );
  });

  test('categorizeFiles marks typescript=true only when a .ts/.tsx file is present', () => {
    assert.equal(categorizeFiles(['api/src/lib/bar.ts']).typescript, true);
    assert.equal(categorizeFiles(['react-spa/src/App.tsx']).typescript, true);
    assert.equal(categorizeFiles(['scripts/foo.mjs']).typescript, false);
    assert.equal(categorizeFiles(['docs/INDEX.md']).typescript, false);
  });
});
