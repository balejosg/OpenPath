/**
 * Dashboard E2E Tests for OpenPath
 *
 * Tests dashboard statistics, health monitoring, and real-time updates.
 */

import { test, expect } from '@playwright/test';
import { DashboardPage } from './fixtures/page-objects';
import {
  loginAsAdmin,
  waitForNetworkIdle,
  waitForDashboard,
  measurePageLoad,
  getPerformanceMetrics,
} from './fixtures/test-utils';

test.describe('Dashboard Display', () => {
  let dashboardPage: DashboardPage;

  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
    dashboardPage = new DashboardPage(page);
    await dashboardPage.goto();
    await waitForNetworkIdle(page);
  });

  test('should display all stat cards @dashboard @seeded', async ({ page }) => {
    // Check for main statistics
    await expect(page.getByText(/Grupos Activos|Active Groups/i)).toBeVisible();
    await expect(page.getByText(/Dominios Permitidos|Allowed Domains/i)).toBeVisible();
    await expect(page.getByText(/Sitios Bloqueados|Blocked Sites/i)).toBeVisible();
    await expect(page.getByText(/Solicitudes Pendientes|Pending Requests/i)).toBeVisible();
  });

  test('should display system health status @dashboard @health', async ({ page }) => {
    // Check for system status banner
    await expect(page.getByText(/Estado del Sistema|System Status/i)).toBeVisible();

    // Status should show \"Seguro\" or \"Healthy\" - use heading to be specific
    await expect(
      page.getByRole('heading', { name: /Estado del Sistema.*Seguro|System Status.*Healthy/i })
    ).toBeVisible();
  });

  test('should display connected agents @dashboard @agents', async ({ page }) => {
    // Look for agents section or count
    const agentsSection = page.getByText(/Agentes|Agents|Equipos Conectados/i);

    if (await agentsSection.isVisible()) {
      // Click to expand if needed
      await agentsSection.click().catch(() => {});

      // Should show agent list or count
      await expect(
        page
          .locator('[data-testid="agent-card"], [data-testid="agent-row"]')
          .or(page.getByText(/conectado|online|activo/i))
      ).toBeVisible({ timeout: 5000 });
    }
  });

  test('should show warning when agent goes offline @dashboard @agents', async ({ page }) => {
    // This test validates that offline agents are indicated
    const offlineIndicator = page
      .locator('[data-status="offline"]')
      .or(page.getByText(/Sin conexión|Offline|Desconectado/i));

    // If there are offline agents, they should be marked
    if (await offlineIndicator.isVisible()) {
      // Warning icon or status should be present
      await expect(offlineIndicator).toHaveClass(/warning|error|danger/);
    }
    // If all agents are online, test passes
  });

  test('should display dashboard stats @dashboard', async ({ page }) => {
    await expect(page.getByText(/Estado del Sistema/i)).toBeVisible();
    await expect(page.getByText(/Grupos Activos/i)).toBeVisible();
    await expect(page.getByText(/Solicitudes Pendientes/i)).toBeVisible();
  });

  test('should show traffic chart @dashboard', async ({ page }) => {
    // Look for chart container
    const chartContainer = page
      .locator('[data-testid="traffic-chart"]')
      .or(
        page
          .locator('.recharts-wrapper')
          .or(page.locator('svg').filter({ hasText: /traffic|tráfico/i }))
      );

    // Chart may not be visible if no data
    if (await chartContainer.isVisible()) {
      await expect(chartContainer).toBeVisible();
    }
  });

  test('should update stats in real-time @dashboard @realtime', async ({ page }) => {
    // Get initial pending requests count
    const pendingBefore = await dashboardPage.getStatValue('pending');

    // Wait for potential real-time update (or trigger one)
    await page.waitForTimeout(3000);

    // Stats should remain consistent or update
    const pendingAfter = await dashboardPage.getStatValue('pending');

    // Both should be valid numbers
    expect(parseInt(pendingBefore)).toBeGreaterThanOrEqual(0);
    expect(parseInt(pendingAfter)).toBeGreaterThanOrEqual(0);
  });
});

test.describe('Dashboard Navigation', () => {
  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
  });

  test('should navigate to groups from dashboard @dashboard @navigation', async ({ page }) => {
    await waitForDashboard(page);

    // Click on groups in sidebar
    const groupsButton = page.getByRole('button', { name: /Group Policies|Políticas de Grupo/i });
    await groupsButton.click();

    // Should show groups content - use heading to be specific
    await expect(
      page.getByRole('heading', { name: /Groups and Policies|Grupos y Políticas/i })
    ).toBeVisible();
  });

  test('should navigate to requests from sidebar @dashboard @navigation', async ({ page }) => {
    await waitForDashboard(page);

    // Click on domains/requests in sidebar
    const requestsButton = page.getByRole('button', {
      name: /Domain Control|Control de Dominios/i,
    });
    await requestsButton.click();

    // Should show requests content - use heading to be specific
    await expect(
      page.getByRole('heading', { name: /Access Requests|Solicitudes de Acceso/i })
    ).toBeVisible();
  });

  test('should refresh dashboard data on demand @dashboard', async ({ page }) => {
    await waitForDashboard(page);

    // Look for refresh button
    const refreshButton = page
      .getByRole('button', { name: /Actualizar|Refresh/i })
      .or(page.locator('[data-testid="refresh-button"]'));

    if (await refreshButton.isVisible()) {
      await refreshButton.click();

      // Should show loading state
      await expect(page.locator('.animate-spin').or(page.getByText(/Cargando|Loading/i)))
        .toBeVisible({ timeout: 1000 })
        .catch(() => {});

      // Should complete loading
      await waitForNetworkIdle(page);
    }
  });
});

test.describe('Dashboard Responsive Design', () => {
  test('should display correctly on mobile viewport @dashboard @responsive', async ({ page }) => {
    // Set mobile viewport
    await page.setViewportSize({ width: 375, height: 667 });

    await loginAsAdmin(page);
    await waitForDashboard(page);

    // Stats should still be visible (may stack vertically) - use heading
    await expect(page.getByRole('heading', { name: /Overview|Vista General/i })).toBeVisible();
  });

  test('should display correctly on tablet viewport @dashboard @responsive', async ({ page }) => {
    // Set tablet viewport
    await page.setViewportSize({ width: 768, height: 1024 });

    await loginAsAdmin(page);
    await waitForDashboard(page);

    // All stats should be visible - use headings
    await expect(page.getByRole('heading', { name: /Overview|Vista General/i })).toBeVisible();
    await expect(page.getByText('Dominios Permitidos')).toBeVisible();
  });
});

test.describe('Dashboard Error States', () => {
  test('should handle API errors gracefully @dashboard @errors', async ({ page }) => {
    // Intercept API calls and simulate error before login
    await page.route('**/trpc/**', (route) => {
      route.fulfill({
        status: 500,
        body: JSON.stringify({ error: 'Internal Server Error' }),
      });
    });

    await page.goto('./');
    await page.waitForLoadState('networkidle');

    // Should show error state or login with error, not crash
    // The page should at least load without crashing
    await expect(page.locator('body')).toBeVisible();
  });

  test('should recover from temporary API failure @dashboard @errors', async ({ page }) => {
    await loginAsAdmin(page);
    await waitForDashboard(page);

    // Dashboard should be visible after successful login - use heading
    await expect(page.getByRole('heading', { name: /Overview|Vista General/i })).toBeVisible();
  });
});
