import { test, expect } from '@playwright/test';

test.describe('React App Smoke Tests', () => {
  test('should load the React app without errors @smoke', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (error) => {
      errors.push(error.message);
    });

    await page.goto('./');
    await page.waitForLoadState('networkidle');

    expect(errors).toHaveLength(0);
  });

  test('should render login page @smoke', async ({ page }) => {
    await page.goto('./');
    await page.waitForLoadState('networkidle');

    // Check for actual React app login page elements (UI shows "Acceso" heading)
    await expect(
      page.getByRole('heading', { name: /Acceso seguro|Secure Sign In/i })
    ).toBeVisible();
    await expect(page.locator('input[type="email"]')).toBeVisible();
    await expect(page.locator('input[type="password"]')).toBeVisible();
    await expect(page.getByRole('button', { name: /Entrar|Sign in/i })).toBeVisible();
  });

  test('should navigate to register page @smoke', async ({ page }) => {
    await page.goto('./');
    await page.waitForLoadState('networkidle');

    // Click "Regístrate" button (accessible name contains "registro")
    const registerButton = page.getByRole('button', { name: /Solicitar acceso|Request access/i });
    await expect(registerButton).toBeVisible();
    await registerButton.click();

    // Should show registration form
    await expect(
      page.getByRole('heading', { name: /Registro institucional|Institution Registration/i })
    ).toBeVisible();
  });
});
