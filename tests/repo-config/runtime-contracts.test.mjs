import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, test } from 'node:test';
import {
  DOCKER_MANIFEST_CASES,
  compareSemver,
  listStableReleaseTags,
  projectRoot,
  readJson,
  readPackageJson,
  readText,
  walkTextFiles,
} from './support.mjs';

describe('repository verification contract', () => {
  test('release-please manifest is not behind the latest stable release tag', () => {
    const manifest = readJson('.release-please-manifest.json');
    const manifestVersion = String(manifest['.'] ?? '').trim();
    const latestStableTag = listStableReleaseTags()[0] ?? '';
    const latestStableVersion = latestStableTag.replace(/^v/, '');

    assert.ok(
      manifestVersion,
      '.release-please-manifest.json should define the root release version'
    );
    assert.ok(latestStableTag, 'repository should expose at least one stable v* tag');
    assert.ok(
      compareSemver(manifestVersion, latestStableVersion) >= 0,
      `release-please manifest (${manifestVersion}) is behind the latest stable tag (${latestStableTag})`
    );
  });

  test('verify:full starts independent static, policy, and security phases together', () => {
    const packageJson = readPackageJson();
    const verifyFull = packageJson.scripts['verify:full'];
    const verifyFullScript = readText('scripts/verify-full.sh');

    assert.equal(verifyFull, 'bash scripts/verify-full.sh');
    assert.ok(
      verifyFullScript.includes(
        "concurrently --group --names 'static,checks,security' 'npm:verify:static' 'npm:verify:checks' 'npm:verify:security'"
      ),
      'verify:full should start independent static, repository policy, and security checks together'
    );
    assert.ok(
      !verifyFullScript.includes("concurrently --group --names 'coverage,unit'"),
      'verify:full should not run coverage beside unit because verify:unit rebuilds shared/dist'
    );
    assert.match(
      verifyFullScript,
      /npm run verify:coverage\s+npm run verify:unit/,
      'verify:full should run coverage before the destructive shared rebuild in verify:unit'
    );
    assert.ok(verifyFullScript.includes('npm run e2e:full'));
  });

  test('e2e helper suite runs serially because shared fixture servers use fixed ports', () => {
    const packageJson = readPackageJson();
    const helperScript = packageJson.scripts['test:e2e:helpers'];

    assert.equal(typeof helperScript, 'string');
    assert.ok(
      helperScript.includes('--test-concurrency=1'),
      'test:e2e:helpers should run serially to avoid fixed-port fixture collisions'
    );
  });

  test('api workspace keeps versioned migrations as the default path and reserves db:push for forced syncs', () => {
    const apiPackageJson = readJson('api/package.json');
    const dbMigrate = apiPackageJson.scripts['db:migrate'];
    const dbPush = apiPackageJson.scripts['db:push'];
    const verifyMigrations = apiPackageJson.scripts['verify:migrations'];

    assert.equal(typeof dbMigrate, 'string');
    assert.equal(typeof dbPush, 'string');
    assert.equal(typeof verifyMigrations, 'string');

    assert.ok(
      dbMigrate.includes('drizzle-kit migrate'),
      'api/package.json should use drizzle-kit migrate for the default db:migrate path'
    );
    assert.ok(
      !dbMigrate.includes('drizzle-kit push'),
      'api/package.json should stop routing db:migrate through drizzle-kit push'
    );
    assert.ok(
      dbPush.includes('drizzle-kit push --force'),
      'api/package.json should keep db:push as the explicit force-sync path'
    );
    assert.ok(
      verifyMigrations.includes('drizzle-kit check'),
      'api/package.json should verify migration metadata with drizzle-kit check'
    );
  });

  test('playwright e2e startup uses a stable API server and only reuses an existing server when explicitly requested', () => {
    const playwrightConfig = readText('react-spa/playwright.config.ts');
    const e2eStartupScript = readText('scripts/start-api-e2e.sh');

    assert.ok(
      playwrightConfig.includes("reuseExistingServer: process.env.PLAYWRIGHT_REUSE_SERVER === '1'"),
      'playwright.config.ts should only reuse an existing API server when PLAYWRIGHT_REUSE_SERVER=1'
    );
    assert.ok(
      playwrightConfig.includes('workers: 2'),
      'playwright.config.ts should limit workers for stable shared-server E2E startup'
    );
    assert.ok(
      e2eStartupScript.includes('npm run build --workspace=@openpath/shared'),
      'start-api-e2e.sh should build @openpath/shared before starting the E2E API server'
    );
    assert.ok(
      e2eStartupScript.includes('npm run build --workspace=@openpath/api'),
      'start-api-e2e.sh should build @openpath/api before starting the E2E API server'
    );
    assert.ok(
      e2eStartupScript.includes('npm run start --workspace=@openpath/api'),
      'start-api-e2e.sh should launch the compiled API server for E2E runs'
    );
    assert.ok(
      !e2eStartupScript.includes('npm run dev'),
      'start-api-e2e.sh should not launch the watch-mode API server during E2E runs'
    );
  });

  test('lockfile keeps vite above the current high-severity advisory range', () => {
    const packageLock = readJson('package-lock.json');
    const viteVersion = packageLock.packages['node_modules/vite']?.version;

    assert.ok(viteVersion, 'package-lock.json should record the resolved vite version');
    assert.ok(
      compareSemver(viteVersion, '7.3.1') > 0,
      `vite ${viteVersion} is within the blocked advisory range ending at 7.3.1`
    );
  });

  test('pre-commit stays on the fast staged guard without re-running coverage', () => {
    const hook = readFileSync(resolve(projectRoot, '.husky/pre-commit'), 'utf8');

    assert.ok(
      hook.includes('[2/2] Running staged verification...'),
      'pre-commit should keep the staged verification step as its final fast guard'
    );
    assert.ok(
      !hook.includes('npm run verify:coverage'),
      'pre-commit should not run verify:coverage directly'
    );
    assert.ok(
      !hook.includes('check-test-files.sh'),
      'pre-commit should leave repo-wide test-file checks for pre-push'
    );
    assert.ok(!hook.includes('[3/3]'), 'pre-commit should keep the staged guard lean');
  });

  test('coverage verification can evaluate pushed commit ranges instead of staged files only', () => {
    const verifyFullScript = readText('scripts/verify-full.sh');
    const runChangedCoverage = readText('scripts/run-changed-coverage.js');
    const checkNewFileCoverage = readText('scripts/check-new-file-coverage.js');

    for (const script of [runChangedCoverage, checkNewFileCoverage]) {
      assert.ok(
        script.includes('--base') && script.includes('--head'),
        'coverage scripts should accept explicit --base/--head ranges for pre-push and CI-style checks'
      );
      assert.ok(
        script.includes('OPENPATH_VERIFY_BASE') && script.includes('OPENPATH_VERIFY_HEAD'),
        'coverage scripts should accept OPENPATH_VERIFY_BASE/OPENPATH_VERIFY_HEAD environment overrides'
      );
      assert.ok(
        script.includes('HEAD~1') && script.includes('git diff --cached'),
        'coverage scripts should keep staged checks but fall back to the last commit when no range is supplied'
      );
    }

    assert.ok(
      verifyFullScript.includes('OPENPATH_VERIFY_BASE') &&
        verifyFullScript.includes('OPENPATH_VERIFY_HEAD'),
      'verify:full should export a concrete coverage range so committed changes are not silently skipped'
    );
  });

  test('repository test-file enforcement covers mapped Linux and Windows client scripts', () => {
    const checkTestFilesScript = readText('scripts/check-test-files.sh');

    assert.ok(
      checkTestFilesScript.includes('SCRIPT_SOURCE_PATTERNS'),
      'check-test-files.sh should maintain an explicit list of non-TypeScript client script patterns'
    );
    assert.ok(
      checkTestFilesScript.includes('linux/*.sh') &&
        checkTestFilesScript.includes('linux/lib/*.sh') &&
        checkTestFilesScript.includes('linux/scripts/**/*.sh'),
      'check-test-files.sh should scan Linux shell entrypoints, libraries, and runtime scripts'
    );
    assert.ok(
      checkTestFilesScript.includes('windows/*.ps1') &&
        checkTestFilesScript.includes('windows/lib/**/*.ps1') &&
        checkTestFilesScript.includes('windows/lib/**/*.psm1') &&
        checkTestFilesScript.includes('windows/scripts/*.ps1'),
      'check-test-files.sh should scan Windows PowerShell entrypoints, libraries, modules, and runtime scripts'
    );
    assert.ok(
      checkTestFilesScript.includes('Missing explicit .test-file-map entry'),
      'non-TypeScript client scripts should require explicit .test-file-map coverage rather than implicit filename guesses'
    );
  });

  test('api Dockerfile uses dependency-only manifests and npm cache mounts', () => {
    const dockerfile = readFileSync(resolve(projectRoot, 'api/Dockerfile'), 'utf8');

    assert.ok(
      dockerfile.includes('# syntax=docker/dockerfile:1.7'),
      'api Dockerfile should opt into Dockerfile features required for cache mounts'
    );

    for (const manifestCase of DOCKER_MANIFEST_CASES) {
      const targetPath = manifestCase.packagePath.replace(/package\.json$/, 'package.json');
      assert.ok(
        dockerfile.includes(`COPY ${manifestCase.dockerPackagePath} ./${targetPath}`),
        `api Dockerfile should use ${manifestCase.dockerPackagePath} during npm ci`
      );
    }

    assert.ok(
      dockerfile.includes('--mount=type=cache,target=/root/.npm'),
      'api Dockerfile should cache npm downloads across repeated image builds'
    );
    assert.ok(
      dockerfile.includes('COPY runtime ./runtime') ||
        dockerfile.includes('COPY runtime/ ./runtime/'),
      'api Dockerfile should copy shared runtime assets into the builder context'
    );
    assert.ok(
      dockerfile.includes('COPY --from=builder /app/runtime ./runtime'),
      'api Dockerfile should preserve shared runtime assets in the runtime image'
    );
  });

  test('linux and windows clients do not reference the legacy classroom whitelist source', () => {
    const forbiddenFragments = ['LasEncinasIT', 'Whitelist-por-aula', 'Informatica%203.txt'];
    const clientRoots = ['linux', 'windows'];

    for (const root of clientRoots) {
      const files = walkTextFiles(root);

      for (const relativePath of files) {
        if (relativePath.includes('/node_modules/')) {
          continue;
        }

        if (
          relativePath.endsWith('.deb') ||
          relativePath.endsWith('.dll') ||
          relativePath.endsWith('.exe')
        ) {
          continue;
        }

        if (relativePath.includes('/dist/')) {
          continue;
        }

        if (relativePath.includes('/bin/')) {
          continue;
        }

        if (relativePath.includes('/obj/')) {
          continue;
        }

        const content = readText(relativePath);

        for (const forbidden of forbiddenFragments) {
          assert.ok(
            !content.includes(forbidden),
            `${relativePath} should not reference legacy classroom whitelist sources`
          );
        }
      }
    }
  });

  test('Linux CI and installer APT operations use the resilient OpenPath APT helper', () => {
    const aptHelpers = readText('linux/lib/apt.sh');
    const common = readText('linux/lib/common.sh');
    const installCoreSteps = readText('linux/lib/install-core-steps.sh');
    const browserFirefox = readText('linux/lib/browser-firefox.sh');
    const browserSetup = readText('linux/scripts/runtime/openpath-browser-setup.sh');
    const firefoxActivationPlan = readText('linux/lib/firefox-activation-plan.sh');
    const watchdog = readText('linux/scripts/runtime/dnsmasq-watchdog.sh');
    const selfUpdatePackage = readText('linux/lib/openpath-self-update-package.sh');
    const e2eDockerfile = readText('tests/e2e/Dockerfile');
    const studentDockerfile = readText('tests/e2e/Dockerfile.student');
    const batsRunnerDockerfile = readText('tests/e2e/Dockerfile.bats-runner');
    const aptContractsRunner = readText('tests/e2e/ci/run-linux-apt-contracts.sh');
    const aptSetup = readText('linux/scripts/build/apt-setup.sh');
    const aptBootstrap = readText('linux/scripts/build/apt-bootstrap.sh');
    const workflowContents = [
      ['.github/workflows/ci.yml', readText('.github/workflows/ci.yml')],
      ['.github/workflows/build-deb.yml', readText('.github/workflows/build-deb.yml')],
      [
        '.github/workflows/reusable-deb-publish.yml',
        readText('.github/workflows/reusable-deb-publish.yml'),
      ],
      ['.github/workflows/perf-test.yml', readText('.github/workflows/perf-test.yml')],
    ];

    for (const fragment of [
      'OPENPATH_APT_MIRRORS',
      'Acquire::ForceIPv4',
      'Acquire::http::Timeout',
      'rewrite_ubuntu_sources_for_mirror',
      'timeout "$timeout_seconds"',
      'openpath_apt_update_output_failed',
      'Failed to fetch',
    ]) {
      assert.ok(
        aptHelpers.includes(fragment),
        `linux/lib/apt.sh should configure resilient APT behavior with ${fragment}`
      );
    }

    assert.ok(
      common.includes('"$INSTALL_DIR/lib/apt.sh"'),
      'linux/lib/common.sh should include apt.sh in integrity checks'
    );
    assert.match(
      common,
      /for lib in apt\.sh(?: [a-z0-9-]+\.sh)* dns\.sh firewall\.sh browser\.sh services\.sh rollback\.sh;/,
      'linux/lib/common.sh should source apt.sh before runtime libraries that may install packages'
    );
    assert.ok(
      browserSetup.includes('load_libraries'),
      'linux/scripts/runtime/openpath-browser-setup.sh should load the common runtime library set before installing Firefox'
    );
    assert.ok(
      browserSetup.includes('firefox-activation-plan.sh'),
      'linux/scripts/runtime/openpath-browser-setup.sh should source the Firefox activation plan module'
    );
    assert.ok(
      firefoxActivationPlan.includes('enumerate_firefox_activation_targets') &&
        firefoxActivationPlan.includes('run_firefox_activation_probe') &&
        firefoxActivationPlan.includes('detect_firefox_extension_registration_in_profile'),
      'linux/lib/firefox-activation-plan.sh should own Firefox activation target and registration behavior'
    );
    assert.ok(
      browserSetup.includes('$INSTALL_DIR/firefox-extension') &&
        browserSetup.includes('/usr/share/openpath/firefox-extension'),
      'linux/scripts/runtime/openpath-browser-setup.sh should support both install.sh-staged and deb-packaged Firefox bundles'
    );
    assert.match(
      browserFirefox,
      /if ! command -v add-apt-repository[\s\S]*apt_update_with_retry[\s\S]*apt_install_with_retry "software-properties-common"/,
      'linux/lib/browser-firefox.sh should refresh package indexes before installing add-apt-repository on minimal Ubuntu images'
    );
    assert.ok(
      browserFirefox.includes('https://packages.mozilla.org/apt') &&
        browserFirefox.includes('/etc/apt/keyrings/packages.mozilla.org.gpg') &&
        browserFirefox.includes('Pin: origin packages.mozilla.org'),
      'linux/lib/browser-firefox.sh should prefer the official Mozilla APT repository over Ubuntu snap-wrapper Firefox packages'
    );
    assert.match(
      browserFirefox,
      /if configure_mozilla_firefox_apt_repo;[\s\S]*else[\s\S]*add-apt-repository -y ppa:mozillateam\/ppa/,
      'linux/lib/browser-firefox.sh should only use the Ubuntu PPA fallback when the official Mozilla APT repository cannot be configured'
    );

    for (const [name, content] of [
      ['tests/e2e/Dockerfile', e2eDockerfile],
      ['tests/e2e/Dockerfile.student', studentDockerfile],
      ['tests/e2e/Dockerfile.bats-runner', batsRunnerDockerfile],
      ['tests/e2e/ci/run-linux-apt-contracts.sh', aptContractsRunner],
    ]) {
      assert.ok(
        content.includes('COPY linux/lib/apt.sh /tmp/openpath-apt.sh'),
        `${name} should copy the shared APT helper before installing packages`
      );
      assert.ok(
        content.includes('. /tmp/openpath-apt.sh'),
        `${name} should source the shared APT helper during Docker builds`
      );
      assert.ok(
        content.includes('apt_install_with_retry'),
        `${name} should install Docker image packages through apt_install_with_retry`
      );
    }

    assert.ok(
      !installCoreSteps.includes('apt-get -o Acquire::Retries=3 install'),
      'linux/lib/install-core-steps.sh should rely on the shared resilient APT configuration instead of per-call retry-only flags'
    );

    for (const [name, content] of [
      ['linux/lib/install-core-steps.sh', installCoreSteps],
      ['linux/lib/browser-firefox.sh', browserFirefox],
      ['linux/scripts/runtime/dnsmasq-watchdog.sh', watchdog],
      ['linux/lib/openpath-self-update-package.sh', selfUpdatePackage],
    ]) {
      assert.ok(
        content.includes('apt_install_with_retry'),
        `${name} should use apt_install_with_retry for package installation`
      );
      assert.ok(
        !content.includes('run_maybe_verbose apt-get update') &&
          !/^\s*apt-get update\b/m.test(content),
        `${name} should not run apt-get update directly`
      );
    }

    for (const [name, content] of workflowContents) {
      assert.ok(
        content.includes('. ./linux/lib/apt.sh && apt_install_with_retry'),
        `${name} should install Ubuntu packages through the shared APT helper`
      );
      assert.ok(
        !content.includes('sudo apt-get update') && !content.includes('sudo apt-get install'),
        `${name} should not use raw sudo apt-get in CI`
      );
    }

    for (const [name, content] of [
      ['linux/scripts/build/apt-setup.sh', aptSetup],
      ['linux/scripts/build/apt-bootstrap.sh', aptBootstrap],
    ]) {
      assert.ok(
        content.includes('OPENPATH_APT_MIRRORS'),
        `${name} should carry standalone resilient APT mirror configuration`
      );
      assert.ok(
        content.includes('apt_update_with_retry'),
        `${name} should retry apt-get update with bounded timeouts`
      );
      assert.ok(
        content.includes('openpath_apt_update_output_failed') &&
          content.includes('Failed to fetch'),
        `${name} should treat apt-get update fetch warnings as retryable failures`
      );
      assert.ok(
        !content.includes('run_maybe_verbose apt-get update') &&
          !/^\s*apt-get update\b/m.test(content),
        `${name} should not run apt-get update directly`
      );
    }

    assert.ok(
      aptBootstrap.includes('https://packages.mozilla.org/apt') &&
        aptBootstrap.includes('/etc/apt/keyrings/packages.mozilla.org.gpg') &&
        aptBootstrap.includes('Pin: origin packages.mozilla.org'),
      'linux/scripts/build/apt-bootstrap.sh should use the official Mozilla APT repository before the Ubuntu PPA fallback'
    );

    assert.match(
      aptContractsRunner,
      /cleanup\(\) \{[\s\S]*return 0[\s\S]*\}/,
      'tests/e2e/ci/run-linux-apt-contracts.sh cleanup should not turn successful contracts into failed runs'
    );
  });
});
