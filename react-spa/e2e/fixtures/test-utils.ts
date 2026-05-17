/**
 * Test Utilities for OpenPath E2E Tests
 *
 * Provides test data factories, helpers, and common setup functions.
 */

import { Page, BrowserContext } from '@playwright/test';
import { randomUUID } from 'node:crypto';

// ============================================================================
// Test Data Factories
// ============================================================================

export interface TestUser {
  email: string;
  password: string;
  name: string;
}

export interface TestGroup {
  name: string;
  description: string;
}

export interface TestDomain {
  domain: string;
  reason: string;
}

function createUniqueFixtureSuffix(): string {
  return `${String(Date.now())}-${randomUUID().slice(0, 8)}`;
}

/**
 * Creates a unique test user with timestamp-based email
 */
export function createTestUser(overrides: Partial<TestUser> = {}): TestUser {
  const uniqueSuffix = createUniqueFixtureSuffix();
  return {
    email: `test-${uniqueSuffix}@e2e-openpath.local`,
    password: 'SecurePassword123!',
    name: `E2E User ${uniqueSuffix}`,
    ...overrides,
  };
}

/**
 * Creates a unique test group
 */
export function createTestGroup(overrides: Partial<TestGroup> = {}): TestGroup {
  const uniqueSuffix = createUniqueFixtureSuffix();
  return {
    name: `Test Group ${uniqueSuffix}`,
    description: `E2E test group created at ${new Date().toISOString()}`,
    ...overrides,
  };
}

/**
 * Creates a test domain request
 */
export function createTestDomain(overrides: Partial<TestDomain> = {}): TestDomain {
  const uniqueSuffix = createUniqueFixtureSuffix();
  return {
    // Manual request flows normalize subdomains to root domains.
    domain: `test-${uniqueSuffix}.test`,
    reason: 'Needed for E2E testing purposes',
    ...overrides,
  };
}

// ============================================================================
// Authentication Helpers
// ============================================================================

/**
 * Detect if we're running against staging environment
 */
function isStaging(): boolean {
  const baseUrl = process.env.BASE_URL || '';
  return baseUrl.includes('staging');
}

/**
 * Admin credentials for test environment
 * Auto-detects staging vs local and uses appropriate credentials
 */
export const ADMIN_CREDENTIALS = isStaging()
  ? {
      email: 'test-admin@staging.local',
      password: 'TestAdmin123!',
    }
  : {
      email: 'admin@openpath.local',
      password: 'AdminPassword123!',
    };

/**
 * Teacher credentials for test environment
 * Auto-detects staging vs local and uses appropriate credentials
 */
export const TEACHER_CREDENTIALS = isStaging()
  ? {
      email: 'test-teacher@staging.local',
      password: 'TestTeacher123!',
    }
  : {
      email: 'teacher@openpath.local',
      password: 'TeacherPassword123!',
    };

const LOGOUT_BUTTON_NAME = /Cerrar Ses(?:i[oó]n)?/i;
const LOGIN_ERROR_TEXT = /Credenciales inv[aá]lidas|error de conexi[oó]n/i;

/**
 * Waits for the authenticated layout (role-agnostic).
 * Use this after login instead of admin-only dashboard assertions.
 */
export async function waitForAuthenticatedLayout(page: Page, timeout = 15000): Promise<void> {
  // Sidebar logout button is present for all authenticated roles.
  await page.getByRole('button', { name: LOGOUT_BUTTON_NAME }).waitFor({ timeout });
}

async function loginThroughForm(
  page: Page,
  credentials: { email: string; password: string },
  retryOnError = true
): Promise<void> {
  const maxAttempts = retryOnError ? 4 : 1;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    await page.goto('./');
    await page.waitForLoadState('networkidle');
    await waitForLoginPage(page);

    await page.locator('input[type="email"]').fill(credentials.email);
    await page.locator('input[type="password"]').fill(credentials.password);
    await page.getByRole('button', { name: 'Entrar' }).click();

    const result = await Promise.race([
      page
        .getByRole('button', { name: LOGOUT_BUTTON_NAME })
        .waitFor({ timeout: 15000 })
        .then(() => 'authenticated' as const),
      page
        .getByText(LOGIN_ERROR_TEXT)
        .first()
        .waitFor({ timeout: 15000 })
        .then(() => 'error' as const),
    ]);

    if (result === 'authenticated') {
      return;
    }

    if (attempt === maxAttempts) {
      break;
    }

    await page.waitForTimeout(500 * attempt);
  }

  await waitForAuthenticatedLayout(page);
}

/**
 * Logs in as admin user - assumes test database is seeded
 * Note: SPA uses state-based navigation, not URL routing
 */
export async function loginAsAdmin(page: Page): Promise<void> {
  await loginThroughForm(page, ADMIN_CREDENTIALS);
}

/**
 * Logs in as teacher user - assumes test database is seeded
 */
export async function loginAsTeacher(page: Page): Promise<void> {
  await loginThroughForm(page, TEACHER_CREDENTIALS);
}

/**
 * Logs out the current user
 * Note: SPA uses state-based navigation, looks for logout button in sidebar
 */
export async function logout(page: Page): Promise<void> {
  // Try sidebar logout button first
  const logoutButton = page.getByRole('button', { name: LOGOUT_BUTTON_NAME });
  if (await logoutButton.isVisible({ timeout: 2000 }).catch(() => false)) {
    await logoutButton.click();
    // Wait for login form to appear
    await page.waitForSelector('input[type="email"]', { timeout: 5000 });
    return;
  }

  // Fallback to user menu
  const userMenu = page.locator('[data-testid="user-menu"]');
  if (await userMenu.isVisible()) {
    await userMenu.click();
    await page.getByRole('menuitem', { name: /Cerrar sesión|Logout/i }).click();
    await page.waitForSelector('input[type="email"]', { timeout: 5000 });
  }
}

/**
 * Clears authentication state
 */
export async function clearAuth(context: BrowserContext): Promise<void> {
  await context.clearCookies();
  await context.storageState({ path: undefined as unknown as string });
}

// ============================================================================
// Wait Helpers
// ============================================================================

/**
 * Waits for authenticated dashboard to appear
 * Use this instead of waitForURL since SPA uses state-based navigation
 */
export async function waitForDashboard(page: Page, timeout = 15000): Promise<void> {
  // Dashboard has "Estado del Sistema" banner and stat cards like "Grupos Activos"
  await page
    .getByText(/Estado del Sistema|Grupos Activos|Dominios Permitidos/i)
    .first()
    .waitFor({ timeout });
}

/**
 * Waits for login page to appear
 */
export async function waitForLoginPage(page: Page, timeout = 10000): Promise<void> {
  await page.locator('input[type="email"]').waitFor({ timeout });
  await page.locator('input[type="password"]').waitFor({ timeout });
}

/**
 * Waits for register page to appear
 */
export async function waitForRegisterPage(page: Page, timeout = 10000): Promise<void> {
  await page.getByRole('heading', { name: 'Registro Institucional' }).first().waitFor({ timeout });
}

/**
 * Waits for network to be idle (no pending requests)
 */
export async function waitForNetworkIdle(page: Page, timeout = 5000): Promise<void> {
  await page.waitForLoadState('networkidle', { timeout });
}

/**
 * Waits for a toast/notification to appear
 */
export async function waitForToast(page: Page, text: string): Promise<void> {
  await page.getByText(text).waitFor({ state: 'visible', timeout: 5000 });
}

/**
 * Waits for loading spinner to disappear
 */
export async function waitForLoadingComplete(page: Page): Promise<void> {
  const spinner = page.locator('.animate-spin');
  if (await spinner.isVisible()) {
    await spinner.waitFor({ state: 'hidden', timeout: 10000 });
  }
}

// ============================================================================
// API Helpers (for test setup/teardown)
// ============================================================================

const API_BASE = process.env.API_URL || 'http://localhost:3000';

/**
 * Resets test database via API (if endpoint available)
 */
export async function resetTestDatabase(): Promise<void> {
  try {
    await fetch(`${API_BASE}/api/test/reset`, { method: 'POST' });
  } catch {
    // Endpoint may not exist in production
  }
}

/**
 * Seeds test data via API (if endpoint available)
 */
export async function seedTestData(): Promise<void> {
  try {
    await fetch(`${API_BASE}/api/test/seed`, { method: 'POST' });
  } catch {
    // Endpoint may not exist in production
  }
}

// ============================================================================
// Assertion Helpers
// ============================================================================

/**
 * Checks if current URL matches expected pattern
 */
export async function expectUrl(page: Page, pattern: string | RegExp): Promise<void> {
  const url = page.url();
  if (typeof pattern === 'string') {
    if (!url.includes(pattern)) {
      throw new Error(`Expected URL to contain "${pattern}", got "${url}"`);
    }
  } else {
    if (!pattern.test(url)) {
      throw new Error(`Expected URL to match ${pattern}, got "${url}"`);
    }
  }
}

// ============================================================================
// Performance Helpers
// ============================================================================

/**
 * Measures page load time
 */
export async function measurePageLoad(page: Page, url: string): Promise<number> {
  const start = Date.now();
  await page.goto(url);
  await page.waitForLoadState('networkidle');
  return Date.now() - start;
}

/**
 * Collects performance metrics
 */
export async function getPerformanceMetrics(page: Page): Promise<{
  domContentLoaded: number;
  loadComplete: number;
  firstPaint: number;
}> {
  const metrics = await page.evaluate(() => {
    const navigation = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming;
    const paint = performance.getEntriesByType('paint').find((p) => p.name === 'first-paint');
    return {
      domContentLoaded: navigation?.domContentLoadedEventEnd || 0,
      loadComplete: navigation?.loadEventEnd || 0,
      firstPaint: paint?.startTime || 0,
    };
  });
  return metrics;
}
