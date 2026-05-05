import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, test } from 'node:test';
import { extractWorkflowJobBlock, projectRoot, readText } from './support.mjs';

describe('repository verification contract', () => {
  test('workflow helpers pin Node 24 compatible GitHub Action majors', () => {
    const cases = [
      {
        relativePath: '.github/workflows/ci.yml',
        required: ['actions/checkout@v6'],
        forbidden: ['actions/checkout@v4'],
      },
      {
        relativePath: '.github/workflows/verify-trailers.yml',
        required: ['actions/checkout@v6'],
        forbidden: ['actions/checkout@v4'],
      },
      {
        relativePath: '.github/workflows/security.yml',
        required: [
          'actions/setup-node@v6',
          'github/codeql-action/init@v4',
          'github/codeql-action/analyze@v4',
          'github/codeql-action/upload-sarif@v4',
          "GITLEAKS_VERSION: '8.30.1'",
          'gitleaks dir . --redact --no-banner --no-color --verbose',
        ],
        forbidden: [
          'actions/setup-node@v4',
          'github/codeql-action/init@v3',
          'github/codeql-action/analyze@v3',
          'github/codeql-action/upload-sarif@v3',
          'gitleaks/gitleaks-action@',
          'gitleaks detect',
          'FORCE_JAVASCRIPT_ACTIONS_TO_NODE24',
        ],
      },
      {
        relativePath: '.github/workflows/release-scripts.yml',
        required: ['actions/checkout@v6', 'softprops/action-gh-release@v3'],
        forbidden: ['actions/checkout@v4', 'softprops/action-gh-release@v2'],
      },
      {
        relativePath: '.github/workflows/release-extension.yml',
        required: ['actions/checkout@v6', 'softprops/action-gh-release@v3'],
        forbidden: ['actions/checkout@v4', 'softprops/action-gh-release@v2'],
      },
      {
        relativePath: '.github/workflows/build-deb.yml',
        required: ['actions/checkout@v6', 'softprops/action-gh-release@v3'],
        forbidden: ['actions/checkout@v4', 'softprops/action-gh-release@v2'],
      },
      {
        relativePath: '.github/workflows/firefox-release-assets.yml',
        required: ['actions/checkout@v6', 'actions/upload-artifact@v7'],
        forbidden: ['actions/checkout@v4', 'actions/upload-artifact@v4'],
      },
      {
        relativePath: '.github/actions/setup-node/action.yml',
        required: ['actions/setup-node@v6'],
        forbidden: ['actions/setup-node@v4'],
      },
      {
        relativePath: '.github/workflows/reusable-docker.yml',
        required: ['docker/login-action@v4'],
        forbidden: ['FORCE_JAVASCRIPT_ACTIONS_TO_NODE24', 'docker/login-action@v3'],
      },
      {
        relativePath: '.github/actions/docker-build/action.yml',
        required: ['docker/setup-buildx-action@v4', 'docker/build-push-action@v7'],
        forbidden: ['docker/setup-buildx-action@v3', 'docker/build-push-action@v6'],
      },
    ];

    for (const { relativePath, required, forbidden } of cases) {
      const content = readText(relativePath);

      for (const version of required) {
        assert.ok(content.includes(version), `${relativePath} should include ${version}`);
      }

      for (const version of forbidden) {
        assert.ok(!content.includes(version), `${relativePath} should not include ${version}`);
      }
    }
  });
});

test('prerelease deb publish keys off the CI Success summary job instead of the workflow conclusion', () => {
  const prereleaseWorkflow = readText('.github/workflows/prerelease-deb.yml');

  assert.ok(
    prereleaseWorkflow.includes('Inspect CI Success summary job'),
    'prerelease-deb.yml should inspect the CI Success summary job before building prerelease artifacts'
  );
  assert.ok(
    prereleaseWorkflow.includes('actions/runs/${{ github.event.workflow_run.id }}/jobs'),
    'prerelease-deb.yml should query the triggering CI workflow jobs so it can recover the canonical CI Success result'
  );
  assert.ok(
    prereleaseWorkflow.includes('select(.name == "CI Success")'),
    'prerelease-deb.yml should key prerelease publishing off the CI Success summary job'
  );
  assert.ok(
    prereleaseWorkflow.includes('ci_success_conclusion'),
    'prerelease-deb.yml should expose the recovered CI Success job conclusion as an output'
  );
  assert.ok(
    prereleaseWorkflow.includes("needs.ci-success.outputs.ci_success_conclusion == 'success'"),
    'prerelease-deb.yml should allow prerelease publishing when the CI Success summary job passed'
  );
  assert.ok(
    !prereleaseWorkflow.includes("github.event.workflow_run.conclusion == 'success'"),
    'prerelease-deb.yml should depend on the canonical CI Success summary rather than a broad workflow conclusion'
  );
});

test('Firefox release signing workflows are resilient to AMO throttling and reruns', () => {
  const buildDebWorkflow = readText('.github/workflows/build-deb.yml');
  const prereleaseWorkflow = readText('.github/workflows/prerelease-deb.yml');
  const firefoxAssetsWorkflow = readText('.github/workflows/firefox-release-assets.yml');
  const prepareAction = readText('.github/actions/prepare-firefox-release-artifacts/action.yml');

  assert.ok(
    prereleaseWorkflow.includes('concurrency:'),
    'prerelease-deb.yml should cancel obsolete prerelease signing waits instead of queueing them'
  );
  assert.ok(
    prereleaseWorkflow.includes('cancel-in-progress: true'),
    'prerelease-deb.yml should keep only the newest prerelease run active for the branch'
  );

  for (const [name, workflow] of [
    ['build-deb.yml', buildDebWorkflow],
    ['prerelease-deb.yml', prereleaseWorkflow],
  ]) {
    assert.ok(
      workflow.includes('2.0.${{ github.run_number }}.${{ github.run_attempt }}'),
      `${name} should include github.run_attempt in the AMO version so reruns avoid Version already exists`
    );
    assert.ok(
      !workflow.includes('2.0.${{ github.run_number }}"'),
      `${name} should not reuse the same AMO version across reruns`
    );
    assert.ok(
      workflow.includes('uses: ./.github/actions/prepare-firefox-release-artifacts'),
      `${name} should prepare Firefox release artifacts through the cache-aware action`
    );
    assert.ok(
      !workflow.includes('npm run sign:firefox-release'),
      `${name} should not call AMO signing directly from the Debian workflow`
    );
  }

  assert.ok(
    buildDebWorkflow.includes("OPENPATH_REQUIRE_FIREFOX_RELEASE_ARTIFACTS: '1'"),
    'stable Debian publishing should still require signed Firefox release artifacts in the Debian package'
  );
  assert.ok(
    !prereleaseWorkflow.includes("OPENPATH_REQUIRE_FIREFOX_RELEASE_ARTIFACTS: '1'"),
    'prerelease publishing should not block unstable Linux packages on AMO approval'
  );
  assert.ok(
    prereleaseWorkflow.includes("sign-on-cache-miss: 'false'"),
    'prerelease publishing should reuse cached signed Firefox assets but avoid new AMO signing waits'
  );
  assert.ok(
    prereleaseWorkflow.includes("require-signed-artifacts: 'false'"),
    'prerelease publishing should allow fallback browser assets while runtime health rejects disabled Firefox extensions'
  );

  assert.ok(
    prepareAction.includes('firefox-release-payload-hash.mjs'),
    'cache-aware Firefox release action should key reuse by the release payload hash'
  );
  assert.ok(
    prepareAction.includes('actions/cache/restore@v4'),
    'cache-aware Firefox release action should restore previously signed release artifacts'
  );
  assert.ok(
    prepareAction.includes('actions/cache/save@v4'),
    'cache-aware Firefox release action should save newly signed release artifacts'
  );
  assert.ok(
    prepareAction.includes('verify-firefox-release-artifacts.mjs'),
    'cache-aware Firefox release action should verify restored and newly signed artifacts'
  );
  assert.ok(
    prepareAction.includes('npm run sign:firefox-release'),
    'cache-aware Firefox release action should still sign through AMO when the cache misses'
  );
  assert.ok(
    prepareAction.includes('approval-timeout-seconds:'),
    'cache-aware Firefox release action should expose an approval timeout input'
  );
  assert.ok(
    prepareAction.includes('total-timeout-seconds:'),
    'cache-aware Firefox release action should expose a total signing timeout input'
  );
  assert.ok(
    prepareAction.includes('process-timeout-buffer-seconds:'),
    'cache-aware Firefox release action should expose a web-ext process timeout buffer input'
  );
  assert.ok(
    prepareAction.includes('sign-on-cache-miss:') && prepareAction.includes("default: 'true'"),
    'cache-aware Firefox release action should default to signing on cache miss for stable release safety'
  );
  assert.ok(
    prepareAction.includes('require-signed-artifacts:') &&
      prepareAction.includes("default: 'true'"),
    'cache-aware Firefox release action should default to requiring signed artifacts for stable release safety'
  );
  assert.ok(
    prepareAction.includes('artifact-source:') &&
      prepareAction.includes('signed-artifacts-present:'),
    'cache-aware Firefox release action should report whether artifacts came from cache, signing, or were skipped'
  );
  assert.ok(
    prepareAction.includes('Skipping AMO signing') &&
      prepareAction.includes('require-signed-artifacts'),
    'cache-aware Firefox release action should have an explicit non-blocking cache-miss path and a strict guard'
  );
  assert.ok(
    prepareAction.includes("default: '1800'"),
    'cache-aware Firefox release action should bound total AMO signing time to 30 minutes by default'
  );
  assert.ok(
    prepareAction.includes("default: '1200'"),
    'cache-aware Firefox release action should leave 10 minutes of the 30-minute budget for AMO recovery'
  );
  assert.ok(
    prepareAction.includes("default: '120'"),
    'cache-aware Firefox release action should keep a bounded web-ext parent-process buffer'
  );
  assert.ok(
    prepareAction.includes("default: '2700'"),
    'cache-aware Firefox release action should keep the long throttle wait as the stable default'
  );
  assert.ok(
    prepareAction.includes("default: '2'"),
    'cache-aware Firefox release action should keep two AMO retries as the stable default'
  );
  assert.ok(
    prepareAction.includes("default: '30'"),
    'cache-aware Firefox release action should keep the retry buffer as the stable default'
  );
  assert.ok(
    prereleaseWorkflow.includes('steps.firefox-release.outputs.artifact-source'),
    'prerelease publishing should summarize whether signed Firefox assets were cached or skipped'
  );
  assert.ok(
    firefoxAssetsWorkflow.includes("workflows: ['CI']") &&
      firefoxAssetsWorkflow.includes('workflow_dispatch:'),
    'Firefox release assets should be seeded after main CI and allow manual reseeding'
  );
  assert.ok(
    firefoxAssetsWorkflow.includes('select(.name == "CI Success")') &&
      firefoxAssetsWorkflow.includes("ci_success_conclusion == 'success'"),
    'Firefox release asset seeding should wait for the canonical CI Success job'
  );
  assert.ok(
    firefoxAssetsWorkflow.includes('uses: ./.github/actions/prepare-firefox-release-artifacts'),
    'Firefox release asset seeding should reuse the cache-aware signing action'
  );
  assert.ok(
    firefoxAssetsWorkflow.includes('2.0.${{ github.run_number }}.${{ github.run_attempt }}'),
    'Firefox release asset seeding should use rerun-safe AMO versions'
  );
  assert.ok(
    firefoxAssetsWorkflow.includes('firefox-extension/payload-hash.txt') &&
      firefoxAssetsWorkflow.includes('firefox-extension/dist/**') &&
      firefoxAssetsWorkflow.includes('firefox-extension/build/firefox-release/**') &&
      firefoxAssetsWorkflow.includes(
        'openpath-firefox-release-assets-${{ steps.firefox-release.outputs.payload-hash }}'
      ),
    'Firefox release asset seeding should publish reusable payload-hash artifacts with dist and signed release files'
  );
  assert.ok(
    !firefoxAssetsWorkflow.includes('--fallback-repo') &&
      !firefoxAssetsWorkflow.includes('source_repo'),
    'OpenPath Firefox release asset seeding must stay generic and avoid downstream wrapper fallback logic'
  );
  assert.ok(
    !buildDebWorkflow.includes('approval-timeout-seconds: 0'),
    'stable Debian publishing should not disable the web-ext approval timeout'
  );
  assert.ok(
    prepareAction.includes(
      'WEB_EXT_SIGN_MAX_THROTTLE_WAIT_SECONDS: ${{ inputs.max-throttle-wait-seconds }}'
    ),
    'cache-aware Firefox release action should wire the throttle wait input into signing'
  );
  assert.ok(
    prepareAction.includes('WEB_EXT_SIGN_RETRY_BUFFER_SECONDS: ${{ inputs.retry-buffer-seconds }}'),
    'cache-aware Firefox release action should wire the retry buffer input into signing'
  );
  assert.ok(
    prepareAction.includes('WEB_EXT_SIGN_MAX_RETRIES: ${{ inputs.max-retries }}'),
    'cache-aware Firefox release action should wire the retry count input into signing'
  );
  assert.ok(
    prepareAction.includes(
      'WEB_EXT_SIGN_APPROVAL_TIMEOUT_SECONDS: ${{ inputs.approval-timeout-seconds }}'
    ),
    'cache-aware Firefox release action should wire the approval timeout input into signing'
  );
  assert.ok(
    prepareAction.includes(
      'WEB_EXT_SIGN_TOTAL_TIMEOUT_SECONDS: ${{ inputs.total-timeout-seconds }}'
    ),
    'cache-aware Firefox release action should wire the total timeout input into signing'
  );
  assert.ok(
    prepareAction.includes(
      'WEB_EXT_SIGN_PROCESS_TIMEOUT_BUFFER_SECONDS: ${{ inputs.process-timeout-buffer-seconds }}'
    ),
    'cache-aware Firefox release action should wire the process timeout buffer input into signing'
  );

  const firefoxPackageJson = JSON.parse(
    readFileSync(resolve(projectRoot, 'firefox-extension/package.json'), 'utf8')
  );
  assert.equal(
    firefoxPackageJson.devDependencies?.['web-ext'],
    '10.1.0',
    'Firefox AMO signing should use a pinned repo-local web-ext version'
  );

  const signingScript = readText('firefox-extension/sign-firefox-release.mjs');
  assert.ok(
    signingScript.includes("'--no-install'"),
    'Firefox AMO signing should not let npx install or float web-ext at runtime'
  );
  assert.ok(
    signingScript.includes('timeout: attemptTimeoutMs'),
    'Firefox AMO signing should enforce a parent process timeout around web-ext'
  );
});

test('self-hosted Linux runner smoke workflow is manual and pinned to the OpenPath runner', () => {
  const smokeWorkflow = readText('.github/workflows/self-hosted-linux-runner-smoke.yml');

  assert.ok(
    smokeWorkflow.includes('workflow_dispatch:'),
    'self-hosted runner smoke must only be manually dispatched'
  );
  assert.ok(
    !smokeWorkflow.includes('pull_request:') && !smokeWorkflow.includes('push:'),
    'self-hosted runner smoke must not run on untrusted or automatic repository events'
  );
  assert.ok(
    smokeWorkflow.includes('runs-on: [self-hosted, Linux, X64, proxmox, openpath]'),
    'self-hosted runner smoke should target only the OpenPath Linux runner labels'
  );
  assert.ok(
    smokeWorkflow.includes('openpath-linux-102'),
    'self-hosted runner smoke should verify the expected OpenPath runner name'
  );
  assert.ok(
    smokeWorkflow.includes('actions/checkout@v6') &&
      smokeWorkflow.includes('persist-credentials: false'),
    'self-hosted runner smoke should use checkout without persisted credentials'
  );
});

test('self-hosted Windows runner smoke workflow is manual and pinned to the OpenPath runner', () => {
  const smokeWorkflow = readText('.github/workflows/self-hosted-windows-runner-smoke.yml');

  assert.ok(
    smokeWorkflow.includes('workflow_dispatch:'),
    'self-hosted Windows runner smoke must only be manually dispatched'
  );
  assert.ok(
    !smokeWorkflow.includes('pull_request:') && !smokeWorkflow.includes('push:'),
    'self-hosted Windows runner smoke must not run on untrusted or automatic repository events'
  );
  assert.ok(
    smokeWorkflow.includes('runs-on: [self-hosted, Windows, X64, proxmox, openpath]'),
    'self-hosted Windows runner smoke should target only the OpenPath Windows runner labels'
  );
  assert.ok(
    smokeWorkflow.includes('openpath-windows-103'),
    'self-hosted Windows runner smoke should verify the expected OpenPath runner name'
  );
  assert.ok(
    smokeWorkflow.includes('actions/checkout@v6') &&
      smokeWorkflow.includes('persist-credentials: false'),
    'self-hosted Windows runner smoke should use checkout without persisted credentials'
  );
});

test('Codecov coverage uploads stay wired to active workflows and the README badge targets the app UI', () => {
  const readme = readText('README.md');
  const reusableTestWorkflow = readText('.github/workflows/reusable-test.yml');

  assert.ok(
    existsSync(resolve(projectRoot, '.github/workflows/coverage.yml')),
    'the repository should keep an active coverage workflow instead of a badge-only Codecov setup'
  );

  const coverageWorkflow = readText('.github/workflows/coverage.yml');

  assert.ok(
    readme.includes(
      '[![codecov](https://codecov.io/github/balejosg/openpath/graph/badge.svg)](https://app.codecov.io/github/balejosg/openpath)'
    ),
    'README.md should point the Codecov badge at the current Codecov app URL and GitHub badge path'
  );
  assert.ok(
    coverageWorkflow.includes('uses: ./.github/workflows/reusable-test.yml'),
    'coverage.yml should invoke the reusable coverage test workflow'
  );

  for (const testType of ['api', 'web', 'spa', 'shared', 'extension']) {
    assert.ok(
      coverageWorkflow.includes(`test-type: ${testType}`),
      `coverage.yml should run the ${testType} coverage lane`
    );
  }

  assert.ok(
    reusableTestWorkflow.includes(
      "description: 'Coverage lane to run (api, web, spa, shared, extension)'"
    ),
    'reusable-test.yml should restrict the reusable coverage workflow to the active Codecov lanes only'
  );
  assert.ok(
    reusableTestWorkflow.includes('case "${{ inputs.test-type }}" in'),
    'reusable-test.yml should resolve lane-specific coverage configuration in one place'
  );
  assert.ok(
    reusableTestWorkflow.includes('run: ${{ steps.lane.outputs.test_command }}'),
    'reusable-test.yml should run coverage lanes from the resolved lane configuration instead of per-lane duplicated steps'
  );
  assert.ok(
    reusableTestWorkflow.includes('files: ${{ steps.lane.outputs.coverage_file }}'),
    'reusable-test.yml should upload the Codecov report selected by the resolved lane configuration'
  );
  assert.ok(
    reusableTestWorkflow.includes('flags: ${{ steps.lane.outputs.coverage_flag }}'),
    'reusable-test.yml should upload the Codecov flag selected by the resolved lane configuration'
  );
  assert.ok(
    reusableTestWorkflow.includes('path: ${{ steps.lane.outputs.coverage_dir }}'),
    'reusable-test.yml should upload only the coverage artifact directory for the active lane'
  );
  assert.ok(
    reusableTestWorkflow.includes("image: ${{ inputs.test-type == 'api' && 'postgres:16' || '' }}"),
    'reusable-test.yml should only provision PostgreSQL for the API coverage lane'
  );
  assert.ok(
    reusableTestWorkflow.includes("if: steps.lane.outputs.needs_postgres == 'true'"),
    'reusable-test.yml should gate database migrations on the resolved lane configuration'
  );
  assert.ok(
    reusableTestWorkflow.includes('npm run db:migrate --workspace=@openpath/api'),
    'reusable-test.yml should migrate PostgreSQL-backed coverage lanes with versioned migrations'
  );
  assert.ok(
    !reusableTestWorkflow.includes('npm run drizzle:push --workspace=@openpath/api'),
    'reusable-test.yml should not mix db:push with versioned migrations in the same coverage lane'
  );
  assert.ok(
    reusableTestWorkflow.includes('build-shared: ${{ steps.lane.outputs.build_shared }}'),
    'reusable-test.yml should derive shared build dependencies from the lane configuration'
  );
  assert.ok(
    reusableTestWorkflow.includes('build-api: ${{ steps.lane.outputs.build_api }}'),
    'reusable-test.yml should derive API build dependencies from the lane configuration'
  );
  assert.ok(
    reusableTestWorkflow.includes('build-extension: ${{ steps.lane.outputs.build_extension }}'),
    'reusable-test.yml should derive extension build dependencies from the lane configuration'
  );
  assert.ok(
    reusableTestWorkflow.includes(
      'test_command=npm run test:coverage --workspace=@openpath/react-spa'
    ),
    'reusable-test.yml should collect React SPA coverage before uploading to Codecov'
  );
  assert.ok(
    reusableTestWorkflow.includes('coverage_flag=dashboard'),
    'reusable-test.yml should map the dashboard lane to the dashboard Codecov flag'
  );
  assert.ok(
    reusableTestWorkflow.includes('coverage_flag=firefox-extension'),
    'reusable-test.yml should map the extension lane to the firefox-extension Codecov flag'
  );
  assert.ok(
    reusableTestWorkflow.includes('build_extension=true'),
    'reusable-test.yml should build the Firefox extension assets for the API coverage lane because token-delivery tests assert Windows manifest entries from firefox-extension/dist'
  );
  assert.ok(
    !reusableTestWorkflow.includes("inputs.test-type == 'integration'"),
    'reusable-test.yml should stop carrying the old integration lane branches in the coverage workflow'
  );
  assert.ok(
    !reusableTestWorkflow.includes("inputs.test-type == 'bash'"),
    'reusable-test.yml should stop carrying the old bash lane branches in the coverage workflow'
  );
  assert.ok(
    !reusableTestWorkflow.includes(
      "if: inputs.test-type == 'api'\n        run: npm run test:coverage --workspace=@openpath/api\n        env:\n          NODE_ENV: test\n          DB_HOST: localhost\n          DB_PORT: 5432\n          DB_NAME: openpath\n          DB_USER: openpath\n          DB_PASSWORD: openpath_dev\n          JWT_SECRET: test-jwt-secret-for-ci-testing"
    ),
    'reusable-test.yml should not override JWT_SECRET in the API coverage lane because auth.test verifies the test-mode fallback secret path'
  );

  const ciWorkflow = readText('.github/workflows/ci.yml');
  assert.ok(
    ciWorkflow.includes('npm run db:migrate --workspace=@openpath/api'),
    'ci.yml should bootstrap PostgreSQL-backed API checks with versioned migrations'
  );
  assert.ok(
    !ciWorkflow.includes('npm run drizzle:push --workspace=@openpath/api'),
    'ci.yml should not mix db:push with db:migrate in the same PostgreSQL setup flow'
  );
});

test('delivery contracts run public request regressions before reporting success', () => {
  const ciWorkflow = readText('.github/workflows/ci.yml');
  const deliveryJobBlock = extractWorkflowJobBlock(ciWorkflow, 'test-delivery-contracts');
  const apiPackage = JSON.parse(readText('api/package.json'));

  assert.equal(
    apiPackage.scripts['test:public-requests'],
    'tsx scripts/run-node-test-suite.ts tests/lib/public-request-input.test.ts tests/api-submit-routes.test.ts tests/machine-request-admission.service.test.ts tests/routes/public-requests.test.ts',
    'the API package should expose a focused public request contract suite for CI'
  );
  assert.ok(
    deliveryJobBlock.includes('id: run-public-request-contracts'),
    'ci.yml should give the public request contract step a stable id'
  );
  assert.ok(
    deliveryJobBlock.includes('npm run test:public-requests --workspace=@openpath/api'),
    'ci.yml should run public request contracts in the delivery-contract lane'
  );
  assert.ok(
    deliveryJobBlock.includes('steps.run-public-request-contracts.outcome'),
    'ci.yml should include public request contracts in the delivery-contract lane outcome'
  );
});

test('required Windows CI runs Pester in an untracked child host without success shortcuts', () => {
  const ciWorkflow = readText('.github/workflows/ci.yml');
  const linuxJobBlock = extractWorkflowJobBlock(ciWorkflow, 'test-linux-dnsmasq');
  const windowsJobBlock = extractWorkflowJobBlock(ciWorkflow, 'test-windows');
  const windowsHostedJobBlock = extractWorkflowJobBlock(ciWorkflow, 'test-windows-hosted');
  const windowsProcessReporter = readText('tests/e2e/ci/report-windows-processes.ps1');
  const windowsPesterRunnerPath = 'tests/e2e/ci/run-windows-pester-isolated.ps1';
  const windowsRunnerResetPath = 'tests/e2e/ci/reset-self-hosted-windows-runner.ps1';

  assert.ok(
    existsSync(resolve(projectRoot, windowsPesterRunnerPath)),
    'the required Windows lane should use a committed isolated Pester runner helper'
  );
  assert.ok(
    existsSync(resolve(projectRoot, windowsRunnerResetPath)),
    'the required Windows lane should use a committed self-hosted runner reset helper'
  );

  const windowsPesterRunner = readText(windowsPesterRunnerPath);
  const windowsRunnerReset = readText(windowsRunnerResetPath);

  assert.ok(
    ciWorkflow.includes('linux_bound: ${{ steps.filter.outputs.linux_bound }}'),
    'ci.yml should publish a dedicated linux_bound output from Detect Relevant Changes'
  );
  assert.ok(
    ciWorkflow.includes('windows_bound: ${{ steps.filter.outputs.windows_bound }}'),
    'ci.yml should publish a dedicated windows_bound output from Detect Relevant Changes'
  );
  assert.ok(
    ciWorkflow.includes('echo "linux_bound=true" >> "$GITHUB_OUTPUT"'),
    'ci.yml should mark linux_bound true during workflow_dispatch runs'
  );
  assert.ok(
    ciWorkflow.includes('echo "windows_bound=true" >> "$GITHUB_OUTPUT"'),
    'ci.yml should mark windows_bound true during workflow_dispatch runs'
  );
  assert.ok(
    ciWorkflow.includes('linux_bound=false') && ciWorkflow.includes('windows_bound=false'),
    'ci.yml should initialize linux_bound and windows_bound independently'
  );
  assert.ok(
    ciWorkflow.includes(
      "grep -Eq '^(linux/|tests/[^/]+\\.bats$|tests/e2e/agent-integration\\.bats$|tests/e2e/ci/run-linux-[^/]+\\.sh|tests/e2e/Dockerfile|\\.github/workflows/ci\\.yml$)'"
    ),
    'ci.yml should route Linux code and Linux-specific tests to the Linux lane without treating every tests/ change as Linux-bound'
  );
  assert.ok(
    ciWorkflow.includes(
      "grep -Eq '^(windows/|tests/e2e/Windows-E2E\\.Tests\\.ps1|tests/e2e/ci/run-windows-pester-isolated\\.ps1|tests/e2e/ci/run-windows-[^/]+\\.ps1|\\.github/workflows/ci\\.yml$)'"
    ),
    'ci.yml should route Windows code and Windows CI helpers to the Windows lane'
  );

  assert.ok(
    windowsJobBlock.includes('runs-on: [self-hosted, Windows, X64, proxmox, openpath]'),
    'ci.yml should route the required Windows Pester lane to the pinned OpenPath self-hosted Windows runner'
  );
  assert.ok(
    windowsJobBlock.includes('timeout-minutes: 25'),
    'ci.yml should cap the required Windows Pester lane while leaving enough teardown margin after the isolated Pester timeout'
  );
  assert.ok(
    !ciWorkflow.includes('runs-on: windows-2022'),
    'ci.yml should stop pinning the required Windows Pester lane to windows-2022'
  );
  assert.ok(
    !windowsJobBlock.includes('runs-on: windows-2025'),
    'ci.yml should keep the required Windows Pester lane off windows-2025 once the self-hosted runner is available'
  );
  assert.ok(
    !ciWorkflow.includes('persist-credentials: true'),
    'ci.yml should not persist checkout credentials because the required CI lanes do not need authenticated git after checkout'
  );
  assert.ok(
    linuxJobBlock.includes("if: needs.detect-relevant-changes.outputs.linux_bound == 'true'"),
    'ci.yml should gate the Linux lane on the dedicated linux_bound output'
  );
  assert.ok(
    linuxJobBlock.includes('timeout-minutes: 25'),
    'ci.yml should cap the Linux BATS lane so a hung agent test cannot block release evidence indefinitely'
  );
  assert.ok(
    linuxJobBlock.includes('uses: actions/checkout@v6'),
    'ci.yml should keep the Linux lane on actions/checkout because the Windows-specific checkout workaround should stay isolated to the required Pester job'
  );
  assert.ok(
    linuxJobBlock.includes('persist-credentials: false'),
    'ci.yml should disable persisted checkout credentials for the Linux lane checkout'
  );
  assert.ok(
    windowsJobBlock.includes("if: needs.detect-relevant-changes.outputs.windows_bound == 'true'"),
    'ci.yml should gate the Windows lane on the dedicated windows_bound output'
  );
  assert.ok(
    windowsJobBlock.includes('uses: actions/checkout@v6'),
    'ci.yml should use the standard checkout action again inside the Windows lane'
  );
  assert.ok(
    windowsJobBlock.includes('persist-credentials: false'),
    'ci.yml should disable persisted checkout credentials for the Windows lane checkout'
  );
  assert.ok(
    !ciWorkflow.includes('runs-on: windows-latest'),
    'ci.yml should avoid windows-latest for the required Windows Pester lane'
  );
  assert.ok(
    !windowsJobBlock.includes('GITHUB_STEP_SUMMARY'),
    'ci.yml should avoid inline Windows step summary processing in the required Pester job'
  );
  assert.ok(
    !ciWorkflow.includes('name: Upload test results'),
    'ci.yml should keep artifact upload out of the required Windows Pester lane'
  );
  assert.ok(
    !windowsJobBlock.includes('name: Install Pester'),
    'ci.yml should not install Pester in the tracked Actions shell because PowerShellGet can leave runner-tracked Windows helpers behind'
  );
  assert.ok(
    windowsJobBlock.includes('tests/e2e/ci/run-windows-pester-isolated.ps1'),
    'ci.yml should run Windows Pester through the isolated helper'
  );
  assert.ok(
    windowsHostedJobBlock.includes('runs-on: windows-2025'),
    'ci.yml should run the hosted Windows Pester gate on GitHub-hosted Windows capacity'
  );
  assert.ok(
    !windowsHostedJobBlock.includes('continue-on-error: true'),
    'ci.yml should fail the required hosted Windows Pester gate instead of treating it as advisory'
  );
  assert.ok(
    windowsHostedJobBlock.includes('timeout-minutes: 6'),
    'ci.yml should keep the hosted Windows gate bounded so hosted teardown stalls fail quickly'
  );
  assert.ok(
    windowsHostedJobBlock.includes(
      "if: needs.detect-relevant-changes.outputs.windows_bound == 'true'"
    ),
    'ci.yml should run the hosted Windows gate automatically for Windows-bound changes'
  );
  assert.ok(
    !windowsHostedJobBlock.includes("github.event_name == 'workflow_dispatch'"),
    'ci.yml should not leave the hosted Windows gate manual-only after promotion'
  );
  assert.ok(
    windowsHostedJobBlock.includes('outputs:') &&
      windowsHostedJobBlock.includes('tests_passed: ${{ steps.job-status.outputs.tests_passed }}'),
    'ci.yml should publish the hosted Windows Pester outcome for CI Success'
  );
  assert.ok(
    windowsHostedJobBlock.includes('tests/e2e/ci/run-windows-pester-isolated.ps1') &&
      windowsHostedJobBlock.includes('-ResultsPath windows-hosted-results.xml') &&
      windowsHostedJobBlock.includes('-TimeoutSeconds 180'),
    'ci.yml should run the same isolated Pester helper in hosted mode with a distinct result path'
  );
  assert.ok(
    windowsHostedJobBlock.includes(
      "TESTS_PASSED: ${{ steps.run-windows-unit-tests.outcome == 'success' && 'true' || 'false' }}"
    ) && windowsHostedJobBlock.includes('"tests_passed=$env:TESTS_PASSED" >> $env:GITHUB_OUTPUT'),
    'ci.yml should derive and emit the hosted Windows Pester outcome through a stable output'
  );
  assert.ok(
    !windowsHostedJobBlock.includes('reset-self-hosted-windows-runner.ps1') &&
      !windowsHostedJobBlock.includes('Prepare self-hosted Windows runner state') &&
      !windowsHostedJobBlock.includes('Restore self-hosted Windows runner state'),
    'ci.yml should not run persistent self-hosted cleanup against the ephemeral hosted runner'
  );
  assert.ok(
    windowsHostedJobBlock.includes('name: Report hosted Windows context') &&
      windowsHostedJobBlock.includes('GITHUB_STEP_SUMMARY') &&
      windowsHostedJobBlock.includes('RUNNER_NAME') &&
      windowsHostedJobBlock.includes('RUNNER_ENVIRONMENT'),
    'ci.yml should emit runner context for hosted Windows timing samples'
  );
  const ciSuccessBlock = ciWorkflow.slice(ciWorkflow.indexOf('  ci-success:\n'));
  assert.ok(
    ciSuccessBlock.startsWith('  ci-success:\n') &&
      /needs:\s*\[\s*detect-relevant-changes,\s*test-linux-dnsmasq,\s*test-windows,\s*test-windows-hosted,\s*test-delivery-contracts,\s*\]/.test(
        ciSuccessBlock
      ),
    'CI Success should require both self-hosted and hosted Windows Pester gates'
  );
  assert.ok(
    ciSuccessBlock.includes('needs.test-windows-hosted.result') &&
      ciSuccessBlock.includes('needs.test-windows-hosted.outputs.tests_passed') &&
      ciSuccessBlock.includes('Hosted Windows Agent Tests (Pester)'),
    'CI Success should fail when the hosted Windows Pester gate fails, cancels, or does not report passing tests'
  );
  assert.ok(
    windowsJobBlock.includes('name: Prepare self-hosted Windows runner state') &&
      windowsJobBlock.includes('name: Restore self-hosted Windows runner state') &&
      windowsJobBlock.includes('tests/e2e/ci/reset-self-hosted-windows-runner.ps1'),
    'ci.yml should reset persistent self-hosted Windows state before and after the Pester lane'
  );
  assert.ok(
    windowsRunnerReset.includes("Set-DnsClientServerAddress -InterfaceAlias 'Ethernet'") &&
      windowsRunnerReset.includes("@('1.1.1.1', '8.8.8.8')"),
    'the self-hosted Windows reset helper should restore external DNS so the runner can reconnect after client tests'
  );
  assert.ok(
    windowsRunnerReset.includes('Unregister-ScheduledTask') &&
      windowsRunnerReset.includes("'OpenPath-AgentUpdate'") &&
      windowsRunnerReset.includes("'OpenPath-Watchdog'"),
    'the self-hosted Windows reset helper should remove persistent OpenPath scheduled tasks between jobs'
  );
  assert.ok(
    windowsRunnerReset.includes('AcrylicDNSProxySvc') &&
      windowsRunnerReset.includes('Mozilla Firefox\\distribution'),
    'the self-hosted Windows reset helper should normalize Acrylic and Firefox policy state between jobs'
  );
  assert.ok(
    windowsRunnerReset.includes('Stop-Service -Name $acrylicServiceName') &&
      !windowsRunnerReset.includes('sc.exe delete $acrylicServiceName') &&
      !windowsRunnerReset.includes('Acrylic DNS Proxy",') &&
      !windowsRunnerReset.includes("Acrylic DNS Proxy'"),
    'the self-hosted Windows reset helper should preserve runner-provisioned Acrylic binaries and service for fast Windows lanes'
  );
  assert.ok(
    !windowsJobBlock.includes('git init .'),
    'ci.yml should not keep the manual Windows checkout workaround once the lane returns to the direct Pester pattern'
  );
  assert.ok(
    !windowsJobBlock.includes('git fetch --no-tags --depth=1 origin'),
    'ci.yml should not keep the manual Windows fetch workaround once the lane returns to the direct Pester pattern'
  );
  assert.ok(
    !ciWorkflow.includes('tests/e2e/ci/run-windows-unit-tests.ps1'),
    'ci.yml should stop routing the Windows lane through the isolated CI helper'
  );
  assert.ok(
    !ciWorkflow.includes('manage-windows-job-processes.ps1'),
    'ci.yml should stop routing the Windows lane through the old process cleanup helper'
  );
  assert.ok(
    !ciWorkflow.includes('tests/e2e/ci/report-windows-processes.ps1') &&
      !ciWorkflow.includes('tests\\e2e\\ci\\report-windows-processes.ps1'),
    'ci.yml should keep live Windows process diagnostics out of the required Pester lane'
  );
  assert.ok(
    !ciWorkflow.includes('name: Capture Windows job process baseline'),
    'ci.yml should not capture a Windows process baseline once the lane returns to the direct Pester pattern'
  );
  assert.ok(
    !ciWorkflow.includes('name: Clean Windows orphaned shells'),
    'ci.yml should not run the explicit Windows orphan cleanup step once the lane returns to the direct Pester pattern'
  );
  assert.ok(
    !ciWorkflow.includes('name: Re-scan Windows processes after idle delay'),
    'ci.yml should not re-scan the Windows process table once the lane returns to the direct Pester pattern'
  );
  assert.ok(
    !windowsJobBlock.includes('name: Report Windows process diagnostics'),
    'ci.yml should not re-run WMI process diagnostics immediately before runner orphan cleanup'
  );
  assert.ok(
    ciWorkflow.includes(
      'outputs:\n      tests_passed: ${{ steps.job-status.outputs.tests_passed }}'
    ),
    'ci.yml should expose explicit tests_passed outputs for required CI lanes'
  );
  assert.ok(
    windowsJobBlock.includes('name: Record Windows lane outcome'),
    'ci.yml should record an explicit Windows lane outcome instead of trusting needs.test-windows.result'
  );
  assert.ok(
    !windowsJobBlock.includes('shell: bash'),
    'ci.yml should avoid bash in the Windows lane'
  );
  assert.ok(
    !windowsJobBlock.includes('shell: cmd'),
    'ci.yml should not route the Windows lane through cmd once the direct pwsh Pester pattern is restored'
  );
  assert.ok(
    windowsJobBlock.includes('shell: pwsh'),
    'ci.yml should use pwsh only as the short-lived parent for the isolated Pester runner'
  );
  assert.ok(
    windowsPesterRunner.includes('Set-StrictMode -Off'),
    'the isolated Pester child should preserve the legacy non-strict Pester runtime used by the required Windows suite'
  );
  assert.ok(
    !windowsJobBlock.includes('report-windows-processes.ps1'),
    'ci.yml should not run live WMI process diagnostics in the required Windows lane because those diagnostics can keep the hosted runner in orphan cleanup'
  );
  assert.ok(
    windowsPesterRunner.includes('$aggregatorSuites = @('),
    'the isolated Pester runner should enumerate the Windows suite aggregators that must stay local-only'
  );
  assert.ok(
    windowsPesterRunner.includes("Get-ChildItem -Path 'windows/tests' -Filter '*.Tests.ps1' -File"),
    'the isolated Pester runner should discover the real Windows leaf suites from the suite directory'
  );
  assert.ok(
    windowsPesterRunner.includes('Where-Object { $_.Name -notin $aggregatorSuites }'),
    'the isolated Pester runner should exclude local-only Windows aggregator suites from the CI Pester path set'
  );
  assert.ok(
    windowsPesterRunner.includes('$config.Run.Path = $suitePaths'),
    'the isolated Pester runner should point at the discovered leaf suite paths instead of the whole directory'
  );
  assert.ok(
    windowsPesterRunner.includes(
      "throw 'Windows Pester suite discovery returned no leaf test files.'"
    ),
    'the isolated Pester runner should fail fast if Windows Pester suite discovery finds no executable leaf suites'
  );
  assert.ok(
    windowsPesterRunner.includes('$config.Run.PassThru = $true'),
    'the isolated Pester runner should request a Pester result object so FailedCount reflects the real suite outcome'
  );
  assert.ok(
    windowsPesterRunner.includes('$config.TestResult.OutputPath = $ResultsPath'),
    'the isolated Pester runner should keep the Windows lane writing its NUnit XML result file'
  );
  assert.ok(
    windowsPesterRunner.includes('Invoke-Pester -Configuration $config'),
    'the isolated Pester runner should continue to execute the real Pester suite'
  );
  assert.ok(
    windowsPesterRunner.includes('function Receive-CompletedStream'),
    'the isolated Pester runner should use a bounded stream drain helper on timeout'
  );
  assert.ok(
    windowsPesterRunner.includes('$Task.Wait($TimeoutMilliseconds)'),
    'the isolated Pester runner should not block indefinitely waiting for stdout or stderr after timeout'
  );
  assert.ok(
    windowsPesterRunner.includes('KillIssued=$killedProcess'),
    'the isolated Pester runner should report whether the child process kill was issued on timeout'
  );
  assert.ok(
    windowsPesterRunner.includes(
      "throw 'Windows Pester suite did not produce windows-test-results.xml.'"
    ),
    'the isolated Pester runner should fail fast if the Windows lane does not emit its expected NUnit XML file'
  );
  assert.ok(
    windowsPesterRunner.includes("throw 'Invoke-Pester returned no result object.'"),
    'the isolated Pester runner should fail fast if Invoke-Pester does not return a result object'
  );
  assert.ok(
    windowsPesterRunner.includes(
      'throw "Windows Pester suite reported $($result.FailedCount) failure(s)."'
    ),
    'the isolated Pester runner should fail the Windows lane when the Pester result reports failures'
  );
  assert.ok(
    windowsPesterRunner.includes('Get-Job -ErrorAction SilentlyContinue'),
    'the isolated Pester runner should inspect lingering PowerShell jobs in the same test shell before exiting the Windows lane'
  );
  assert.ok(
    windowsPesterRunner.includes('Stop-Job -ErrorAction SilentlyContinue'),
    'the isolated Pester runner should stop lingering PowerShell jobs before exiting the Windows lane'
  );
  assert.ok(
    windowsPesterRunner.includes('Remove-Job -Force -ErrorAction SilentlyContinue'),
    'the isolated Pester runner should remove lingering PowerShell jobs before exiting the Windows lane'
  );
  assert.ok(
    windowsPesterRunner.includes("$null = $startInfo.Environment.Remove('RUNNER_TRACKING_ID')"),
    'the isolated Pester child should remove RUNNER_TRACKING_ID so Windows service helpers do not wedge Actions orphan cleanup'
  );
  assert.ok(
    windowsPesterRunner.includes('OPENPATH_WINDOWS_CI_ISOLATED_PESTER'),
    'the isolated Pester child should mark its execution mode for future diagnostics'
  );
  assert.ok(
    windowsJobBlock.includes(
      "TESTS_PASSED: ${{ steps.run-windows-unit-tests.outcome == 'success' && 'true' || 'false' }}"
    ),
    'ci.yml should derive the Windows lane outcome from a GitHub Actions expression so the output step stays shell-minimal'
  );
  assert.ok(
    windowsJobBlock.includes('"tests_passed=$env:TESTS_PASSED" >> $env:GITHUB_OUTPUT'),
    'ci.yml should emit the Windows lane outcome through a single redirected line to GITHUB_OUTPUT'
  );
  assert.ok(
    !windowsJobBlock.includes('name: Hold successful Windows lane until timeout cancellation'),
    'ci.yml should not use a timeout-cancellation sentinel as the expected Windows success path'
  );
  assert.ok(
    !windowsJobBlock.includes('Start-Sleep -Seconds 3600'),
    'ci.yml should not intentionally sleep the Windows lane until timeout'
  );
  assert.ok(
    !windowsJobBlock.includes('name: Write Windows success marker'),
    'ci.yml should not require a Windows success-marker workaround for normal green CI'
  );
  assert.ok(
    !windowsJobBlock.includes('Set-Content -Path ci/windows-tests-passed.txt -Value success'),
    'ci.yml should not materialize a Windows success marker file in the workspace'
  );
  assert.ok(
    !windowsJobBlock.includes('Out-File -FilePath $env:GITHUB_OUTPUT'),
    'ci.yml should avoid the more error-prone multi-line Out-File pattern in the Windows lane outcome step'
  );
  assert.ok(
    ciWorkflow.includes('needs.test-windows.outputs.tests_passed'),
    'ci.yml should drive the CI summary gate from the recorded Windows lane output'
  );
  assert.ok(
    ciWorkflow.includes('tests passed, but the Windows job ended as'),
    'ci.yml should report runner teardown or timeout separately when Pester passed but the job result failed'
  );
  assert.ok(
    ciWorkflow.includes('[[ "${{ needs.test-windows.result }}" == "success" ]] && \\'),
    'ci.yml should require a normal successful Windows job result before accepting the Windows lane output'
  );
  assert.ok(
    !ciWorkflow.includes('[[ "${{ needs.test-windows.result }}" == "cancelled" ]]'),
    'ci.yml should not treat a cancelled Windows lane as a successful CI outcome'
  );
  assert.ok(
    ciWorkflow.includes('CI Success is the canonical required signal for this workflow. Each lane'),
    'ci.yml should document in the summary job why CI Success is the canonical required signal'
  );
  assert.ok(
    !ciWorkflow.includes('workflow run may finish with a global cancelled conclusion'),
    'ci.yml should not document cancellation as an expected green path'
  );
  assert.ok(
    ciWorkflow.includes("- '.release-please-manifest.json'"),
    'ci.yml should trigger the canonical CI workflow when release-please metadata advances the stable version manifest'
  );
  assert.ok(
    ciWorkflow.includes("- 'release-please-config.json'"),
    'ci.yml should trigger the canonical CI workflow when release-please configuration changes'
  );
  assert.ok(
    !ciWorkflow.includes('name: Inspect Windows success marker'),
    'ci.yml should not query Windows marker-step metadata to recover a cancelled lane'
  );
  assert.ok(
    !ciWorkflow.includes('actions/upload-artifact@v7'),
    'ci.yml should avoid artifact uploads inside the Windows lane'
  );
  assert.ok(
    !ciWorkflow.includes('actions/download-artifact@v4'),
    'ci.yml should avoid artifact downloads in the summary job'
  );
  assert.ok(
    !ciWorkflow.includes('windows_success_marker_restored'),
    'ci.yml should not keep marker-restoration state for cancelled Windows lanes'
  );
  assert.ok(
    windowsProcessReporter.includes("ValidateSet('capture', 'report')"),
    'the Windows process reporter should remain available for manual investigation without being part of the required Windows lane'
  );
  assert.ok(
    windowsProcessReporter.includes('Get-CimInstance Win32_Process'),
    'the manual Windows process reporter should inspect the live Win32 process table when explicitly invoked'
  );
  for (const relativePath of [
    'windows/tests/Windows.Browser.ChromiumPolicy.Tests.ps1',
    'windows/tests/Windows.Browser.Diagnostics.Tests.ps1',
    'windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1',
    'windows/tests/Windows.Browser.NativeHost.Tests.ps1',
    'windows/tests/Windows.Browser.RequestReadiness.Tests.ps1',
  ]) {
    const browserTest = readText(relativePath);

    assert.ok(
      browserTest.includes('BeforeAll {'),
      `${relativePath} should continue to re-import its browser modules in BeforeAll`
    );
    assert.ok(
      browserTest.includes('Join-Path $PSScriptRoot ".." "lib"'),
      `${relativePath} should resolve browser module paths from PSScriptRoot inside the executable Pester scope`
    );
  }
});

test('documents hosted Windows Pester teardown history without repo-side cleanup hacks', () => {
  const agentInstructions = readText('AGENTS.md');
  const e2eReadme = readText('tests/e2e/README.md');
  const windowsPesterRunner = readText('tests/e2e/ci/run-windows-pester-isolated.ps1');

  assert.ok(
    agentInstructions.includes(
      'Do not reintroduce repo-side cleanup hacks for the historical hosted Windows Pester teardown cancellation.'
    ),
    'AGENTS.md should explicitly forbid repo-side cleanup hacks for the historical hosted Windows Pester teardown defect'
  );
  assert.match(
    agentInstructions,
    /The required Windows Pester coverage now uses two gates: the pinned self-hosted\s+OpenPath Windows runner and a GitHub-hosted `windows-2025` runner\./,
    'AGENTS.md should document the active double Windows Pester gate'
  );
  assert.ok(
    e2eReadme.includes(
      'Required Windows Pester coverage uses both the pinned OpenPath self-hosted'
    ),
    'tests/e2e/README.md should document that required Windows Pester coverage uses both hosted and self-hosted runners'
  );
  assert.match(
    e2eReadme,
    /Destructive installer and\s+student-policy Windows lanes still target the pinned self-hosted runner\./,
    'tests/e2e/README.md should document that destructive Windows lanes stay self-hosted'
  );
  assert.ok(
    e2eReadme.includes(
      'Do not reintroduce descendant process cleanup, WMI process killing, success marker recovery, or timeout-sentinel logic without new upstream runner evidence and maintainer approval.'
    ),
    'tests/e2e/README.md should tell future agents not to reattempt repo-side hosted-runner cleanup fixes'
  );
  for (const forbiddenPattern of [
    'function Stop-DescendantProcesses',
    'Get-CimInstance Win32_Process',
    'Stop-Process -Id $candidate.ProcessId',
    'ParentProcessId -eq $ParentProcessId',
  ]) {
    assert.ok(
      !windowsPesterRunner.includes(forbiddenPattern),
      `the isolated Windows Pester runner should not reintroduce repo-side descendant cleanup: ${forbiddenPattern}`
    );
  }
});

test('Linux E2E lanes restore the shared Playwright browser cache', () => {
  const setupNodeAction = readText('.github/actions/setup-node/action.yml');
  const e2eWorkflow = readText('.github/workflows/e2e-tests.yml');

  assert.ok(
    setupNodeAction.includes('cache-playwright:'),
    'setup-node should expose an opt-in Playwright browser cache'
  );
  assert.ok(
    setupNodeAction.includes('path: ~/.cache/ms-playwright'),
    'setup-node should cache the standard Linux Playwright browser directory'
  );
  assert.ok(
    setupNodeAction.includes(
      "key: ${{ runner.os }}-playwright-${{ hashFiles('package-lock.json', 'react-spa/package.json') }}"
    ),
    'setup-node should key the Playwright cache from the lockfile and browser-owning workspace manifest'
  );
  assert.ok(
    e2eWorkflow.includes('cache-playwright: true'),
    'Linux E2E jobs should opt into the shared Playwright browser cache'
  );
});

test('setup-node supports extra lockfiles for npm cache keys', () => {
  const setupNodeAction = readText('.github/actions/setup-node/action.yml');
  const e2eWorkflow = readText('.github/workflows/e2e-tests.yml');
  const windowsStudentPolicyBlock = extractWorkflowJobBlock(e2eWorkflow, 'windows-student-policy');

  assert.match(
    setupNodeAction,
    /cache-dependency-path:[\s\S]*default: '\.\/package-lock\.json'/,
    'setup-node should expose a defaulted cache-dependency-path input'
  );
  assert.match(
    setupNodeAction,
    /cache-dependency-path: \$\{\{ inputs\.cache-dependency-path \}\}/,
    'setup-node should forward the cache-dependency-path input to actions/setup-node'
  );
  assert.match(
    windowsStudentPolicyBlock,
    /cache-dependency-path: \|[\s\S]*package-lock\.json[\s\S]*tests\/selenium\/package-lock\.json/,
    'Windows student-policy should include both root and Selenium lockfiles in the npm cache key'
  );
});

test('E2E workflow gates expensive platform lanes on targeted changed paths', () => {
  const e2eWorkflow = readText('.github/workflows/e2e-tests.yml');
  const linuxE2eBlock = extractWorkflowJobBlock(e2eWorkflow, 'linux-e2e');
  const windowsE2eBlock = extractWorkflowJobBlock(e2eWorkflow, 'windows-e2e');
  const linuxStudentPolicyBlock = extractWorkflowJobBlock(e2eWorkflow, 'linux-student-policy');
  const windowsStudentPolicyBlock = extractWorkflowJobBlock(e2eWorkflow, 'windows-student-policy');

  assert.match(
    e2eWorkflow,
    /workflow_dispatch:\s*\n\s+inputs:\s*\n[\s\S]*platform:\s*\n[\s\S]*default: windows[\s\S]*options:\s*\n\s+- all\s*\n\s+- linux\s*\n\s+- windows/,
    'manual E2E diagnostics should expose a platform selector defaulting to Windows'
  );
  assert.match(
    e2eWorkflow,
    /workflow_dispatch:[\s\S]*suite:\s*\n[\s\S]*default: student-policy[\s\S]*options:\s*\n\s+- all\s*\n\s+- e2e\s*\n\s+- student-policy/,
    'manual E2E diagnostics should expose a suite selector defaulting to student-policy'
  );
  assert.match(
    e2eWorkflow,
    /workflow_dispatch:[\s\S]*student_policy_sse_group:\s*\n[\s\S]*default: auto[\s\S]*options:\s*\n\s+- auto\s*\n\s+- full\s*\n\s+- request-lifecycle\s*\n\s+- ajax-auto-allow\s*\n\s+- path-blocking\s*\n\s+- exemptions/,
    'manual Windows student-policy diagnostics should expose an SSE scenario group selector defaulting to auto'
  );
  assert.ok(
    e2eWorkflow.includes('manual_platform="${{ github.event.inputs.platform || \'windows\' }}"') &&
      e2eWorkflow.includes('manual_suite="${{ github.event.inputs.suite || \'student-policy\' }}"'),
    'workflow_dispatch should route only the selected platform and suite instead of forcing every E2E lane'
  );
  assert.doesNotMatch(
    e2eWorkflow,
    /if \[ "\$\{\{ github\.event_name \}\}" = "workflow_dispatch" \]; then[\s\S]*echo "linux_e2e=true"[\s\S]*echo "windows_e2e=true"[\s\S]*echo "linux_student_policy=true"[\s\S]*echo "windows_student_policy=true"/,
    'workflow_dispatch must not unconditionally consume every E2E runner lane'
  );

  for (const outputName of [
    'linux_e2e',
    'windows_e2e',
    'linux_student_policy',
    'windows_student_policy',
  ]) {
    const outputExpression = `${outputName}: \${{ steps.filter.outputs.${outputName} }}`;
    assert.ok(
      e2eWorkflow.includes(outputExpression),
      `e2e-tests.yml should expose ${outputName} from Detect Relevant Changes`
    );
    assert.ok(
      e2eWorkflow.includes(`echo "${outputName}=$${outputName}" >> "$GITHUB_OUTPUT"`),
      `e2e-tests.yml should emit selected ${outputName} during workflow_dispatch runs`
    );
  }

  assert.ok(
    e2eWorkflow.includes('release_infra_only: ${{ steps.filter.outputs.release_infra_only }}'),
    'e2e-tests.yml should expose release_infra_only from Detect Relevant Changes'
  );
  assert.ok(
    e2eWorkflow.includes('release_infra_only=true') &&
      e2eWorkflow.includes('release_infra_only=false'),
    'e2e-tests.yml should classify release-infrastructure-only diffs explicitly'
  );
  assert.ok(
    e2eWorkflow.includes(
      '^(.github/workflows/(e2e-tests|installer-contracts|prerelease-deb|release-extension|release-scripts)\\.yml|scripts/(require-release-quality-gate|select-windows-student-policy-sse-group)\\.mjs|tests/repo-config/)'
    ),
    'release-infrastructure-only classification should stay limited to E2E/release workflows, release gate helpers, route selector, and repo-config contracts'
  );
  assert.ok(
    e2eWorkflow.includes(
      "firefox_runtime_pattern='firefox-extension/(manifest\\.json|package\\.json|tsconfig(\\.build)?\\.json|src/|blocked/|popup/|icons/)'"
    ),
    'Firefox path routing should identify only runtime extension files'
  );
  assert.ok(
    e2eWorkflow.includes('|$firefox_runtime_pattern|'),
    'E2E lane routing should use the shared Firefox runtime path pattern'
  );
  assert.ok(
    !e2eWorkflow.includes('|firefox-extension/|'),
    'E2E lane routing should not treat every Firefox extension file as runtime behavior'
  );
  assert.ok(
    !e2eWorkflow.includes('firefox-extension/sign-firefox-release.mjs'),
    'Firefox signing tooling should not trigger expensive E2E platform lanes'
  );
  assert.ok(
    e2eWorkflow.includes('[ "$release_infra_only" != "true" ] && echo "$changed_files" | grep -Eq'),
    'expensive E2E lane routing should skip release-infrastructure-only diffs'
  );
  assert.ok(
    linuxE2eBlock.includes("needs.detect-relevant-changes.outputs.linux_e2e == 'true'"),
    'linux-e2e should run only for Linux E2E relevant changes'
  );
  assert.ok(
    e2eWorkflow.includes("'linux/debian-package/**'"),
    'Debian package maintainer script changes should trigger E2E before prerelease package publishing'
  );
  assert.ok(
    e2eWorkflow.includes("'tests/**'"),
    'E2E workflow should start for any tests/** change so release quality gates can always find the same-commit E2E Summary required after CI'
  );
  assert.ok(
    windowsE2eBlock.includes("needs.detect-relevant-changes.outputs.windows_e2e == 'true'"),
    'windows-e2e should run only for Windows E2E relevant changes'
  );
  assert.ok(
    windowsE2eBlock.includes('runs-on: [self-hosted, Windows, X64, proxmox, openpath]'),
    'windows-e2e should run on the pinned OpenPath self-hosted Windows runner'
  );
  assert.ok(
    e2eWorkflow.includes(
      '^(windows/|runtime/|tests/e2e/(Windows-E2E\\.Tests\\.ps1|ci/run-windows-e2e\\.ps1|ci/report-windows-processes\\.ps1|validation/)|package\\.json$|package-lock\\.json$|scripts/require-release-quality-gate\\.mjs$|\\.github/workflows/(e2e-tests|installer-contracts|prerelease-deb|release-extension|release-scripts)\\.yml$)'
    ),
    'windows-e2e should stay focused on installer, runtime, and Windows-specific destructive paths'
  );
  assert.ok(
    !e2eWorkflow.includes(
      '^(windows/|runtime/|firefox-extension/|tests/e2e/(Windows-E2E\\.Tests\\.ps1|ci/run-windows-e2e\\.ps1|ci/report-windows-processes\\.ps1|validation/)|package\\.json$|package-lock\\.json$|scripts/require-release-quality-gate\\.mjs$|\\.github/workflows/(e2e-tests|installer-contracts|prerelease-deb|release-extension|release-scripts)\\.yml$)'
    ),
    'windows-e2e should not trigger on Firefox extension diffs because browser readiness lives in Windows student-policy'
  );
  assert.ok(
    !windowsE2eBlock.includes('${{ matrix.os }}') && !windowsE2eBlock.includes('matrix:'),
    'windows-e2e should not keep a hosted-runner matrix after moving to the pinned self-hosted Windows runner'
  );
  assert.ok(
    windowsE2eBlock.includes('name: Prepare self-hosted Windows runner state') &&
      windowsE2eBlock.includes('name: Restore self-hosted Windows runner state') &&
      windowsE2eBlock.includes('tests/e2e/ci/reset-self-hosted-windows-runner.ps1'),
    'windows-e2e should reset persistent self-hosted Windows state before and after the installer flow'
  );
  assert.ok(
    linuxStudentPolicyBlock.includes(
      "needs.detect-relevant-changes.outputs.linux_student_policy == 'true'"
    ),
    'linux-student-policy should run only for Linux student-policy relevant changes'
  );
  assert.ok(
    windowsStudentPolicyBlock.includes(
      "needs.detect-relevant-changes.outputs.windows_student_policy == 'true'"
    ),
    'windows-student-policy should run only for Windows student-policy relevant changes'
  );
  assert.ok(
    e2eWorkflow.includes(
      'windows_student_policy_sse_group: ${{ steps.filter.outputs.windows_student_policy_sse_group }}'
    ),
    'e2e-tests.yml should expose the selected Windows student-policy SSE group'
  );
  assert.ok(
    e2eWorkflow.includes('scripts/select-windows-student-policy-sse-group.mjs'),
    'changed-path detection should use the maintained Windows student-policy SSE selector'
  );
  assert.ok(
    windowsStudentPolicyBlock.includes(
      'OPENPATH_WINDOWS_STUDENT_SSE_GROUP: ${{ needs.detect-relevant-changes.outputs.windows_student_policy_sse_group }}'
    ),
    'windows-student-policy should pass the selected SSE group to the runner'
  );
  assert.ok(
    windowsStudentPolicyBlock.includes('runs-on: [self-hosted, Windows, X64, proxmox, openpath]'),
    'windows-student-policy should run on the pinned OpenPath self-hosted Windows runner'
  );
  assert.ok(
    windowsStudentPolicyBlock.includes('name: Prepare self-hosted Windows runner state') &&
      windowsStudentPolicyBlock.includes('name: Restore self-hosted Windows runner state') &&
      windowsStudentPolicyBlock.includes('tests/e2e/ci/reset-self-hosted-windows-runner.ps1'),
    'windows-student-policy should reset persistent self-hosted Windows state before and after the Selenium flow'
  );
  assert.ok(
    windowsStudentPolicyBlock.indexOf('name: Restore self-hosted Windows runner state') <
      windowsStudentPolicyBlock.indexOf('name: Upload Windows student-policy diagnostics'),
    'windows-student-policy should restore external DNS before uploading diagnostics artifacts'
  );
  assert.ok(
    !e2eWorkflow.includes('runs-on: windows-2022'),
    'e2e-tests.yml should stop using hosted windows-2022 runners for Windows lanes'
  );
  assert.ok(
    e2eWorkflow.includes('ci/run-windows-student-flow\\.ps1'),
    'windows-student-policy should be triggered by its own runner script'
  );
  assert.ok(
    e2eWorkflow.includes('tests/selenium/|'),
    'student-policy lanes should be triggered by shared Selenium student-policy helpers'
  );
  assert.ok(
    e2eWorkflow.includes('ci/run-linux-student-flow\\.sh'),
    'linux-student-policy should be triggered by its own runner script'
  );
  assert.ok(
    e2eWorkflow.includes('SKIPPED'),
    'E2E summary should report skipped lanes explicitly instead of printing them as failures'
  );
  assert.ok(
    e2eWorkflow.includes('needs.detect-relevant-changes.result'),
    'E2E summary should fail if changed-path detection fails before lane gating'
  );
});

test('Firefox runtime extension changes exercise platform readiness gates before release evidence', () => {
  const e2eWorkflow = readText('.github/workflows/e2e-tests.yml');
  const linuxStudentPolicyBlock = extractWorkflowJobBlock(e2eWorkflow, 'linux-student-policy');
  const windowsStudentPolicyBlock = extractWorkflowJobBlock(e2eWorkflow, 'windows-student-policy');

  assert.match(
    e2eWorkflow,
    /linux_student_policy=[\s\S]*\$firefox_runtime_pattern/,
    'Firefox runtime extension changes should trigger Linux student-policy so native-host readiness is validated on Linux'
  );
  assert.match(
    e2eWorkflow,
    /windows_student_policy=[\s\S]*\$firefox_runtime_pattern/,
    'Firefox runtime extension changes should trigger Windows student-policy so browser readiness is validated on Windows'
  );
  assert.ok(
    linuxStudentPolicyBlock.includes('run-linux-student-flow.sh'),
    'Linux student-policy workflow should continue using the runner that gates Selenium on DNS and Firefox readiness'
  );
  assert.ok(
    windowsStudentPolicyBlock.includes('run-windows-student-flow.ps1'),
    'Windows student-policy workflow should continue using the runner that gates Selenium on Acrylic and Firefox readiness'
  );
});

test('release artifact workflows wait for same-commit quality evidence before publishing', () => {
  const prereleaseWorkflow = readText('.github/workflows/prerelease-deb.yml');
  const scriptsReleaseWorkflow = readText('.github/workflows/release-scripts.yml');
  const extensionReleaseWorkflow = readText('.github/workflows/release-extension.yml');
  const gateScript = readText('scripts/require-release-quality-gate.mjs');

  assert.ok(
    gateScript.includes('listWorkflowRuns') &&
      gateScript.includes('ghJson') &&
      gateScript.includes("'run',") &&
      gateScript.includes("'view',"),
    'release quality gate should inspect GitHub Actions runs and their summary jobs with gh'
  );
  assert.ok(
    gateScript.includes('--require') &&
      gateScript.includes('workflowName') &&
      gateScript.includes('jobName'),
    'release quality gate should require workflow/job pairs for the same SHA'
  );

  assert.ok(
    prereleaseWorkflow.includes('release-quality-gate:'),
    'prerelease-deb.yml should define a dedicated release quality gate job'
  );
  assert.ok(
    prereleaseWorkflow.includes('--sha "${{ github.event.workflow_run.head_sha }}"'),
    'prerelease-deb.yml should gate the same commit that triggered CI'
  );
  assert.ok(
    prereleaseWorkflow.includes('--require "CI::CI Success"') &&
      prereleaseWorkflow.includes('--require "E2E Tests::E2E Summary"') &&
      prereleaseWorkflow.includes('--require "Installer Contracts::Installer Contracts Success"'),
    'prerelease-deb.yml should require CI, E2E, and installer contract summary jobs before publishing'
  );
  assert.ok(
    prereleaseWorkflow.includes('needs: ci-success'),
    'prerelease build should start as soon as CI Success is recovered so package build work runs in parallel with the release quality gate'
  );
  assert.ok(
    !prereleaseWorkflow.includes('needs: [ci-success, release-quality-gate]'),
    'prerelease build should not serialize behind the release quality gate'
  );
  assert.ok(
    prereleaseWorkflow.includes('needs: [build-prerelease, release-quality-gate]'),
    'prerelease publish should remain blocked on both the package build and the same-SHA release quality gate'
  );
  assert.ok(
    prereleaseWorkflow.includes('ref: ${{ github.event.workflow_run.head_sha }}'),
    'prerelease build should checkout the exact commit that passed the gate'
  );

  for (const [relativePath, workflow] of [
    ['.github/workflows/release-scripts.yml', scriptsReleaseWorkflow],
    ['.github/workflows/release-extension.yml', extensionReleaseWorkflow],
  ]) {
    assert.ok(
      workflow.includes('actions: read'),
      `${relativePath} should grant read access to Actions metadata for the quality gate`
    );
    assert.ok(
      workflow.includes('node scripts/require-release-quality-gate.mjs') &&
        workflow.includes('--sha "${{ github.sha }}"') &&
        workflow.includes('--require "CI::CI Success"') &&
        workflow.includes('--require "E2E Tests::E2E Summary"'),
      `${relativePath} should wait for same-SHA CI and E2E summary jobs before publishing`
    );
    assert.ok(
      workflow.indexOf('node scripts/require-release-quality-gate.mjs') <
        workflow.indexOf('name: Create and push tag'),
      `${relativePath} should run the quality gate before creating a tag`
    );
    assert.ok(
      workflow.indexOf('name: Create and push tag') <
        workflow.indexOf('uses: softprops/action-gh-release@v3'),
      `${relativePath} should create the tag only after local package validation and before publishing the GitHub release`
    );
  }

  assert.ok(
    scriptsReleaseWorkflow.includes('--require "Installer Contracts::Installer Contracts Success"'),
    'release-scripts.yml should require installer contract evidence before publishing installer artifacts'
  );
  assert.ok(
    !scriptsReleaseWorkflow.includes('npm run test:installer:contracts'),
    'release-scripts.yml should not duplicate installer contract execution after requiring same-SHA installer evidence'
  );
  assert.ok(
    extensionReleaseWorkflow.includes('npm test --workspace=@openpath/firefox-extension'),
    'release-extension.yml should run the Firefox extension tests in the release job before publishing'
  );
});

test('release scripts workflow triggers for every packaged installer input', () => {
  const scriptsReleaseWorkflow = readText('.github/workflows/release-scripts.yml');

  for (const pathPattern of [
    'VERSION',
    'package.json',
    'package-lock.json',
    'linux/**',
    'windows/**',
    'runtime/**',
    'firefox-extension/**',
    'tests/e2e/**',
    'tests/selenium/**',
    '.github/workflows/release-scripts.yml',
  ]) {
    assert.ok(
      scriptsReleaseWorkflow.includes(`- '${pathPattern}'`),
      `release-scripts.yml should trigger when ${pathPattern} changes`
    );
  }
});

test('E2E release evidence is not cancelled by newer pushes on the same branch', () => {
  const e2eWorkflow = readText('.github/workflows/e2e-tests.yml');

  assert.ok(
    e2eWorkflow.includes('cancel-in-progress: false'),
    'e2e-tests.yml should preserve in-flight same-SHA release evidence instead of cancelling it on the next push'
  );
});
