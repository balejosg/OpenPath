/**
 * Visual Regression Tests for OpenPath
 *
 * Uses Playwright's screenshot comparison for visual consistency.
 * Run with: npx playwright test visual.spec.ts --update-snapshots to create baselines.
 */

import { test, expect } from '@playwright/test';
import { DashboardPage, GroupsPage, DomainRequestsPage } from './fixtures/page-objects';
import { loginAsAdmin, waitForNetworkIdle } from './fixtures/test-utils';

test.describe('Visual Regression - Login Page', () => {
  test('login page desktop @visual', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 720 });
    await page.goto('./');
    await page.waitForLoadState('networkidle');

    // Wait for any animations to complete
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('login-desktop.png', {
      maxDiffPixelRatio: 0.01,
      animations: 'disabled',
    });
  });

  test('login page mobile @visual', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await page.goto('./');
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('login-mobile.png', {
      maxDiffPixelRatio: 0.03,
      animations: 'disabled',
    });
  });

  test('login page tablet @visual', async ({ page }) => {
    await page.setViewportSize({ width: 768, height: 1024 });
    await page.goto('./');
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('login-tablet.png', {
      maxDiffPixelRatio: 0.01,
      animations: 'disabled',
    });
  });

  test('login page with error state @visual', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 720 });
    await page.goto('./');
    await page.waitForLoadState('networkidle');

    // Trigger error state
    await page.locator('input[type="email"]').fill('invalid@test.com');
    await page.locator('input[type="password"]').fill('wrongpassword');
    await page.getByRole('button', { name: /Entrar|Sign in/i }).click();

    // Wait for error to appear
    await page
      .getByText(/Credenciales|Invalid credentials|Error|inválid|connection error/i)
      .waitFor({ state: 'visible', timeout: 5000 })
      .catch(() => {});
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('login-error-state.png', {
      maxDiffPixelRatio: 0.02,
      animations: 'disabled',
    });
  });
});

test.describe('Visual Regression - Register Page', () => {
  test('register page desktop @visual', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 720 });
    await page.goto('./');
    await page.waitForLoadState('networkidle');

    // Navigate to register
    await page.getByRole('button', { name: /Solicitar acceso|Request access/i }).click();
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('register-desktop.png', {
      maxDiffPixelRatio: 0.03,
      animations: 'disabled',
    });
  });

  test('register page mobile @visual', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await page.goto('./');
    await page.getByRole('button', { name: /Solicitar acceso|Request access/i }).click();
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('register-mobile.png', {
      maxDiffPixelRatio: 0.04,
      animations: 'disabled',
    });
  });
});

test.describe('Visual Regression - Dashboard', () => {
  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);
  });

  test('dashboard desktop @visual', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 720 });
    await new DashboardPage(page).goto();
    await waitForNetworkIdle(page);
    await page.waitForTimeout(1000); // Wait for charts to render

    await expect(page).toHaveScreenshot('dashboard-desktop.png', {
      maxDiffPixelRatio: 0.04, // Dashboard includes dynamic timestamps/data
      animations: 'disabled',
    });
  });

  test('dashboard mobile @visual', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await new DashboardPage(page).goto();
    await waitForNetworkIdle(page);
    await page.waitForTimeout(1000);

    await expect(page).toHaveScreenshot('dashboard-mobile.png', {
      maxDiffPixelRatio: 0.04, // Dashboard includes dynamic timestamps/data
      animations: 'disabled',
    });
  });

  test('dashboard empty state @visual', async ({ page }) => {
    // Mock empty data for the dashboard by patching tRPC responses.
    await page.route('**/trpc/**', async (route) => {
      const url = new URL(route.request().url());
      const pathname = url.pathname;
      const marker = '/trpc/';
      const markerIndex = pathname.indexOf(marker);
      if (markerIndex < 0) {
        await route.continue();
        return;
      }

      const proceduresPart = pathname.slice(markerIndex + marker.length);
      const procedures = proceduresPart.split(',').filter(Boolean);

      const response = await route.fetch();
      const contentType = response.headers()['content-type'] || '';
      if (!contentType.includes('application/json')) {
        await route.fulfill({ response });
        return;
      }

      const originalBody: unknown = await response.json();

      const setJson = (entry: unknown, value: unknown): unknown => {
        if (!entry || typeof entry !== 'object') return entry;
        const e = entry as { result?: { data?: Record<string, unknown> } };
        if (!e.result || typeof e.result !== 'object') return entry;
        const result = e.result as { data?: Record<string, unknown> };
        if (!result.data || typeof result.data !== 'object') {
          result.data = {};
        }
        (result.data as Record<string, unknown>).json = value;
        return entry;
      };

      const patchOne = (entry: unknown, procedure: string): unknown => {
        switch (procedure) {
          case 'groups.stats':
            return setJson(entry, { groupCount: 0, whitelistCount: 0, blockedCount: 0 });
          case 'requests.stats':
            return setJson(entry, { pending: 0, approved: 0, rejected: 0 });
          case 'groups.systemStatus':
            return setJson(entry, { totalGroups: 0, activeGroups: 0, pausedGroups: 0 });
          case 'groups.list':
            return setJson(entry, []);
          case 'classrooms.list':
            return setJson(entry, []);
          default:
            return entry;
        }
      };

      const patchedBody = Array.isArray(originalBody)
        ? originalBody.map((entry, i) => patchOne(entry, procedures[i] ?? proceduresPart))
        : patchOne(originalBody, proceduresPart);

      await route.fulfill({ response, json: patchedBody });
    });

    await page.setViewportSize({ width: 1280, height: 720 });
    await page.reload();
    await new DashboardPage(page).goto();
    await waitForNetworkIdle(page).catch(() => {});
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('dashboard-empty.png', {
      maxDiffPixelRatio: 0.04,
      animations: 'disabled',
    });
  });
});

test.describe('Visual Regression - Groups Page', () => {
  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
  });

  test('groups list desktop @visual', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 720 });
    await new GroupsPage(page).goto();
    await waitForNetworkIdle(page);
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('groups-list-desktop.png', {
      maxDiffPixelRatio: 0.04,
      animations: 'disabled',
    });
  });

  test('groups list mobile @visual', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await new GroupsPage(page).goto();
    await waitForNetworkIdle(page);
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('groups-list-mobile.png', {
      maxDiffPixelRatio: 0.1,
      animations: 'disabled',
    });
  });
});

test.describe('Visual Regression - Domain Requests', () => {
  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
  });

  test('requests page desktop @visual', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 720 });
    await new DomainRequestsPage(page).goto();
    await waitForNetworkIdle(page);
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('requests-desktop.png', {
      maxDiffPixelRatio: 0.04,
      animations: 'disabled',
    });
  });
});

test.describe('Visual Regression - Dark Mode', () => {
  test('login page dark mode @visual @dark', async ({ page }) => {
    // Enable dark mode via media preference
    await page.emulateMedia({ colorScheme: 'dark' });

    await page.setViewportSize({ width: 1280, height: 720 });
    await page.goto('./');
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot('login-dark-mode.png', {
      maxDiffPixelRatio: 0.01,
      animations: 'disabled',
    });
  });

  test('dashboard dark mode @visual @dark', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' });

    await loginAsAdmin(page);
    await page.setViewportSize({ width: 1280, height: 720 });
    await new DashboardPage(page).goto();
    await waitForNetworkIdle(page);
    await page.waitForTimeout(1000);

    await expect(page).toHaveScreenshot('dashboard-dark-mode.png', {
      maxDiffPixelRatio: 0.04,
      animations: 'disabled',
    });
  });
});
