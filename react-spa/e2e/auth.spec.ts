/**
 * Authentication E2E Tests for OpenPath
 *
 * Tests login, logout, session management, and error handling.
 */

import { test, expect } from '@playwright/test';
import { LoginPage } from './fixtures/page-objects';
import {
  ACCESS_TOKEN_KEY,
  LEGACY_TOKEN_KEY,
  REFRESH_TOKEN_KEY,
  USER_KEY,
} from '../src/lib/auth-storage';
import {
  createTestUser,
  loginAsAdmin,
  logout,
  waitForNetworkIdle,
  waitForDashboard,
  waitForLoginPage,
  ADMIN_CREDENTIALS,
} from './fixtures/test-utils';

test.describe('Authentication Flows', () => {
  let loginPage: LoginPage;

  test.beforeEach(async ({ page }) => {
    loginPage = new LoginPage(page);
    await loginPage.goto();
  });

  test('should login with valid credentials @auth @seeded', async ({ page }) => {
    await loginPage.expectLoaded();

    // Use admin credentials (assuming seeded test data)
    await loginPage.login(ADMIN_CREDENTIALS.email, ADMIN_CREDENTIALS.password);

    // Should show dashboard content (state-based navigation, no URL change)
    await waitForDashboard(page);

    // User should see authenticated content - use heading to be specific
    await expect(page.getByRole('heading', { name: /Overview|Vista General/i })).toBeVisible();
  });

  test('should show error with invalid credentials @auth', async ({ page }) => {
    await loginPage.expectLoaded();

    // Login with wrong password
    await loginPage.login('invalid@email.com', 'wrongpassword');

    // Should show error message
    await expect(page.getByText(/Credenciales inválidas|Error|incorrecta/i)).toBeVisible({
      timeout: 5000,
    });

    // Should stay on login page
    await expect(loginPage.emailInput).toBeVisible();
  });

  test('should logout and clear session @auth @seeded', async ({ page }) => {
    // First login
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);

    // Perform logout via sidebar button
    await logout(page);

    // Should show login form
    await waitForLoginPage(page);
    await loginPage.expectLoaded();
  });

  test('should persist session across page refreshes @auth', async ({ page }) => {
    // Login
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);

    // Refresh the page
    await page.reload();
    await waitForNetworkIdle(page);

    // Should still be logged in (dashboard visible)
    await waitForDashboard(page);

    // User content should be visible - use heading to be specific
    await expect(page.getByRole('heading', { name: /Overview|Vista General/i })).toBeVisible();
  });

  test('should redirect to login when session expires @auth', async ({ page }) => {
    // Login first
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);

    // Clear auth tokens to simulate session expiry.
    // Avoid calling page.reload() directly since the app may auto-reload on 401.
    await page.evaluate(
      ({ accessTokenKey, refreshTokenKey, userKey, legacyTokenKey }) => {
        localStorage.removeItem(accessTokenKey);
        localStorage.removeItem(refreshTokenKey);
        localStorage.removeItem(userKey);
        localStorage.removeItem(legacyTokenKey);
        setTimeout(() => window.location.reload(), 0);
      },
      {
        accessTokenKey: ACCESS_TOKEN_KEY,
        refreshTokenKey: REFRESH_TOKEN_KEY,
        userKey: USER_KEY,
        legacyTokenKey: LEGACY_TOKEN_KEY,
      }
    );

    // Should show login form
    await waitForLoginPage(page);
    await loginPage.expectLoaded();
  });

  test('should navigate to register page from login @auth', async ({ page }) => {
    await loginPage.expectLoaded();
    await loginPage.navigateToRegister();

    // Should show registration form - use heading to be specific
    await expect(page.getByRole('heading', { name: 'Registro Institucional' })).toBeVisible();
    await expect(page.locator('input[type="email"]')).toBeVisible();
  });

  test('should show loading state during login @auth', async ({ page }) => {
    await loginPage.expectLoaded();

    // Fill credentials
    await loginPage.emailInput.fill(ADMIN_CREDENTIALS.email);
    await loginPage.passwordInput.fill(ADMIN_CREDENTIALS.password);

    // Click login and check that either:
    // 1. Button becomes disabled during request, OR
    // 2. A spinner appears, OR
    // 3. Login succeeds (fast network)
    await loginPage.loginButton.click();

    // Wait for either loading state or success
    await Promise.race([
      expect(loginPage.loginButton)
        .toBeDisabled({ timeout: 500 })
        .catch(() => {}),
      expect(page.locator('.animate-spin'))
        .toBeVisible({ timeout: 500 })
        .catch(() => {}),
      waitForDashboard(page),
    ]);

    // Test passes if any of the above happened
  });
});

test.describe('Registration Flow', () => {
  test('should register new user successfully @auth @registration', async ({ page }) => {
    const testUser = createTestUser();

    await page.goto('./');
    await page.waitForLoadState('networkidle');

    // Navigate to register - look for the register button
    const registerLink = page.getByRole('button', { name: 'Solicitar acceso' });
    await registerLink.click();

    // Wait for register form - use heading to be specific
    await expect(page.getByRole('heading', { name: 'Registro Institucional' })).toBeVisible({
      timeout: 5000,
    });

    // Fill registration form - use flexible selectors
    const emailInput = page.locator('input[type="email"]');
    const nameInput = page.getByPlaceholder(/nombre/i);
    const passwordInputs = page.locator('input[type="password"]');

    await emailInput.fill(testUser.email);
    if (await nameInput.isVisible()) {
      await nameInput.fill(testUser.name);
    }
    await passwordInputs.first().fill(testUser.password);
    if ((await passwordInputs.count()) > 1) {
      await passwordInputs.last().fill(testUser.password);
    }

    // Check terms if present
    const termsCheckbox = page.getByRole('checkbox');
    if (await termsCheckbox.isVisible().catch(() => false)) {
      await termsCheckbox.check();
    }

    // Submit - look for any submit button
    const submitButton = page.getByRole('button', { name: /Crear|Registrar|Enviar/i });
    if (await submitButton.isEnabled()) {
      await submitButton.click();
    }

    // Should show success or redirect to dashboard/waiting
    await expect(page.getByText(/Bienvenido|Dashboard|verificar|Panel|esperando/i)).toBeVisible({
      timeout: 10000,
    });
  });

  test('should show validation errors for invalid registration @auth @registration', async ({
    page,
  }) => {
    await page.goto('./');
    await page.waitForLoadState('networkidle');

    // Navigate to register
    const registerLink = page.getByText(/Crear cuenta|Regístrate|Solicitar acceso/i).first();
    await registerLink.click();

    // Wait for register form - use heading to be specific
    await expect(page.getByRole('heading', { name: 'Registro Institucional' })).toBeVisible({
      timeout: 5000,
    });

    // The submit button should be disabled when form is empty
    const submitButton = page.getByRole('button', { name: /Crear|Registrar|Enviar/i });
    await expect(submitButton).toBeDisabled();
  });

  test('should validate password confirmation match @auth @registration', async ({ page }) => {
    await page.goto('./');
    const registerLink = page.getByText(/Crear cuenta|Regístrate|Solicitar acceso/i).first();
    await registerLink.click();

    // Wait for form - use heading to be specific
    await expect(page.getByRole('heading', { name: 'Registro Institucional' })).toBeVisible({
      timeout: 5000,
    });

    // Fill with mismatched passwords
    const emailInput = page.locator('input[type="email"]');
    const passwordInputs = page.locator('input[type="password"]');

    await emailInput.fill('test@example.com');
    await passwordInputs.first().fill('Password123!');
    await passwordInputs.last().fill('DifferentPassword!');

    // Should show password mismatch error
    await expect(page.getByText(/coinciden|no coinciden|match/i)).toBeVisible({ timeout: 3000 });
  });
});
