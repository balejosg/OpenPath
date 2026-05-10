import fs from 'node:fs';
import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright configuration optimized for local development speed.
 *
 * Key optimizations:
 * - fullyParallel: true - allow safe cross-file parallelism
 * - reuseExistingServer: opt-in - only reuse API when explicitly requested
 * - Only Chromium (no Firefox/WebKit) for speed
 * - Shorter timeouts locally
 * - No retries locally (fast feedback)
 *
 * Test Tags:
 * - @smoke: Quick sanity tests (run on every commit)
 * - @auth: Authentication flow tests
 * - @domains: Domain management tests
 * - @dashboard: Dashboard functionality tests
 * - @visual: Visual regression tests
 * - @performance: Performance/speed tests
 * - @slow: Tests that take longer to run
 */

const isCI = !!process.env.CI;
// E2E API port (3001 locally to avoid conflict with Docker containers on 3000)
// On CI, API runs on 3000 (no Docker conflict)
// Locally, Vite runs on 5173, API on 3001
const apiPort = isCI ? 3000 : 3001;
const baseURL = process.env.BASE_URL || `http://localhost:${apiPort}/`;

function resolveChromiumExecutablePath(): string | undefined {
  const explicitPath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH?.trim();
  if (explicitPath) {
    return explicitPath;
  }

  const bundledExecutable =
    '/datos_nvme/run0/.cache/ms-playwright/chromium_headless_shell-1208/chrome-headless-shell-linux64/chrome-headless-shell';
  if (fs.existsSync(bundledExecutable)) {
    return undefined;
  }

  for (const candidate of ['/usr/bin/google-chrome-stable', '/usr/bin/google-chrome']) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return undefined;
}

const chromiumExecutablePath = resolveChromiumExecutablePath();

export default defineConfig({
  testDir: './e2e',

  /* Run tests in files in parallel */
  fullyParallel: true,

  /* Fail the build on CI if you accidentally left test.only in the source code. */
  forbidOnly: isCI,

  /* Retry on CI only - fail fast locally */
  retries: isCI ? 2 : 0,

  /* Keep E2E startup stable against the shared local API server. */
  workers: 2,

  /* Reporter: minimal locally for speed, html in CI */
  reporter: isCI ? [['html'], ['junit', { outputFile: 'e2e/test-results/results.xml' }]] : 'list',

  /* Shared settings for all the projects below. */
  use: {
    /* Base URL to use in actions like `await page.goto('/')`. */
    baseURL,

    /* Collect trace when retrying the failed test. */
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'on-first-retry',

    /* Faster timeouts locally */
    navigationTimeout: isCI ? 30000 : 15000,
    actionTimeout: isCI ? 15000 : 10000,
  },

  /* Faster expect timeouts locally */
  expect: {
    timeout: isCI ? 10000 : 5000,
    /* Visual regression settings */
    toHaveScreenshot: {
      maxDiffPixelRatio: 0.01,
      animations: 'disabled',
    },
    toMatchSnapshot: {
      maxDiffPixelRatio: 0.01,
    },
  },

  /* Configure projects for different test types */
  projects: [
    /* Default: Chromium for speed */
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        ...(chromiumExecutablePath
          ? { launchOptions: { executablePath: chromiumExecutablePath } }
          : {}),
      },
    },
    /* Mobile viewport for responsive tests - use Pixel 5 (chromium-based) */
    {
      name: 'mobile',
      use: {
        ...devices['Pixel 5'],
        ...(chromiumExecutablePath
          ? { launchOptions: { executablePath: chromiumExecutablePath } }
          : {}),
      },
      grep: /@responsive|@mobile/,
    },
    /* Tablet viewport - use Galaxy Tab S4 (chromium-based) */
    {
      name: 'tablet',
      use: {
        ...devices['Galaxy Tab S4'],
        ...(chromiumExecutablePath
          ? { launchOptions: { executablePath: chromiumExecutablePath } }
          : {}),
      },
      grep: /@responsive|@tablet/,
    },
  ],

  /* Run your local dev server before starting the tests */
  webServer: [
    {
      // Use test database (Docker on port 5433) for E2E tests
      command: `PORT=${apiPort} bash ../scripts/start-api-e2e.sh`,
      url: `http://127.0.0.1:${apiPort}/trpc/healthcheck.ready`,
      reuseExistingServer: process.env.PLAYWRIGHT_REUSE_SERVER === '1',
      timeout: 120000,
    },
  ],

  /* Output directory for test artifacts */
  outputDir: './e2e/test-results',

  /* Snapshot directory for visual regression */
  snapshotDir: './e2e/snapshots',

  /* Global timeout for each test */
  timeout: isCI ? 60000 : 30000,
});
