/**
 * Domain Management E2E Tests for OpenPath
 *
 * Tests domain requests, approvals, rejections, and whitelist management.
 */

import { test, expect, type Page } from '@playwright/test';
import { DomainRequestsPage, GroupsPage } from './fixtures/page-objects';
import {
  loginAsAdmin,
  loginAsTeacher,
  createTestDomain,
  waitForNetworkIdle,
} from './fixtures/test-utils';
import { ACCESS_TOKEN_KEY, COOKIE_SESSION_MARKER, LEGACY_TOKEN_KEY } from '../src/lib/auth-storage';

const TEST_GROUP_ID = 'test-e2e-group';
const TEST_REQUESTER_EMAIL = 'student@openpath.local';

interface TrpcBrowserResponse<T> {
  ok: boolean;
  status: number;
  body: {
    result?: {
      data?: T;
    };
    error?: {
      message?: string;
    };
  };
}

interface DomainRequestRecord {
  id: string;
  domain: string;
  groupId: string;
  status: 'pending' | 'approved' | 'rejected';
}

async function callTrpcFromBrowser<T>(
  page: Page,
  params: {
    procedure: string;
    input?: unknown;
    method?: 'GET' | 'POST';
    requiresAuth?: boolean;
  }
): Promise<T> {
  const response = await page.evaluate(
    async ({
      procedure,
      input,
      method,
      requiresAuth,
      accessTokenKey,
      legacyTokenKey,
      cookieSessionMarker,
    }): Promise<TrpcBrowserResponse<T>> => {
      const accessToken = requiresAuth ? window.localStorage.getItem(accessTokenKey) : null;
      const legacyToken = requiresAuth ? window.localStorage.getItem(legacyTokenKey) : null;
      const hasCookieSession = accessToken === cookieSessionMarker;
      const token = accessToken && accessToken !== cookieSessionMarker ? accessToken : legacyToken;

      if (requiresAuth && !token && !hasCookieSession) {
        return {
          ok: false,
          status: 401,
          body: { error: { message: 'Missing auth token in browser storage' } },
        };
      }

      const query =
        method === 'GET' && input !== undefined
          ? `?input=${encodeURIComponent(JSON.stringify(input))}`
          : '';
      const response = await fetch(`/trpc/${procedure}${query}`, {
        method,
        headers: {
          ...(method === 'POST' ? { 'Content-Type': 'application/json' } : {}),
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: method === 'POST' ? JSON.stringify(input ?? {}) : undefined,
        credentials: 'include',
      });

      return {
        ok: response.ok,
        status: response.status,
        body: (await response.json()) as TrpcBrowserResponse<T>['body'],
      };
    },
    {
      procedure: params.procedure,
      input: params.input,
      method: params.method ?? 'POST',
      requiresAuth: params.requiresAuth ?? false,
      accessTokenKey: ACCESS_TOKEN_KEY,
      legacyTokenKey: LEGACY_TOKEN_KEY,
      cookieSessionMarker: COOKIE_SESSION_MARKER,
    }
  );

  if (!response.ok || response.body.error || response.body.result?.data === undefined) {
    throw new Error(
      `tRPC ${params.procedure} failed with status ${String(response.status)}: ${response.body.error?.message ?? 'Missing result data'}`
    );
  }

  return response.body.result.data;
}

async function createPendingDomainRequest(
  page: Page,
  overrides: Partial<{
    domain: string;
    reason: string;
    requesterEmail: string;
    groupId: string;
    machineHostname: string;
  }> = {}
): Promise<DomainRequestRecord> {
  const seed = createTestDomain();

  return await callTrpcFromBrowser<DomainRequestRecord>(page, {
    procedure: 'requests.create',
    input: {
      domain: overrides.domain ?? seed.domain,
      reason: overrides.reason ?? seed.reason,
      requesterEmail: overrides.requesterEmail ?? TEST_REQUESTER_EMAIL,
      groupId: overrides.groupId ?? TEST_GROUP_ID,
      machineHostname: overrides.machineHostname ?? 'e2e-workstation-01',
      source: 'manual',
    },
  });
}

async function approveDomainRequestViaApi(page: Page, requestId: string): Promise<void> {
  await callTrpcFromBrowser(page, {
    procedure: 'requests.approve',
    input: { id: requestId },
    requiresAuth: true,
  });
}

async function deleteDomainRequestViaApi(page: Page, requestId: string): Promise<void> {
  await callTrpcFromBrowser(page, {
    procedure: 'requests.delete',
    input: { id: requestId },
    requiresAuth: true,
  });
}

function getRequestRow(page: Page, domain: string) {
  return page.locator('[data-testid="request-row"]').filter({ hasText: domain }).first();
}

test.describe('Domain Request Management', () => {
  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);
  });

  test('should display pending domain requests @domains', async ({ page }) => {
    const request = await createPendingDomainRequest(page);
    try {
      const requestsPage = new DomainRequestsPage(page);
      await requestsPage.goto();

      await expect(
        page.getByRole('heading', { name: /Access Requests|Solicitudes de Acceso/i })
      ).toBeVisible();
      await expect(getRequestRow(page, request.domain)).toHaveAttribute('data-status', 'pending');
    } finally {
      await deleteDomainRequestViaApi(page, request.id);
    }
  });

  test('should approve a domain request @domains', async ({ page }) => {
    const request = await createPendingDomainRequest(page);
    try {
      const requestsPage = new DomainRequestsPage(page);
      await requestsPage.goto();
      const pendingRow = getRequestRow(page, request.domain);

      await expect(pendingRow).toHaveAttribute('data-status', 'pending');
      await pendingRow.getByTitle('Aprobar').click();
      await expect(page.getByRole('heading', { name: 'Aprobar Solicitud' })).toBeVisible();
      await page.getByRole('button', { name: 'Aprobar' }).last().click();
      await expect(pendingRow).toHaveAttribute('data-status', 'approved');
    } finally {
      await deleteDomainRequestViaApi(page, request.id);
    }
  });

  test('should reject a domain request with reason @domains', async ({ page }) => {
    const request = await createPendingDomainRequest(page);
    try {
      const requestsPage = new DomainRequestsPage(page);
      await requestsPage.goto();
      const pendingRow = getRequestRow(page, request.domain);

      await expect(pendingRow).toHaveAttribute('data-status', 'pending');
      await pendingRow.getByTitle('Rechazar').click();
      await expect(page.getByRole('heading', { name: 'Rechazar Solicitud' })).toBeVisible();
      await page
        .getByPlaceholder('Explica por qué se rechaza esta solicitud...')
        .fill('Not allowed per school policy');
      await page.getByRole('button', { name: 'Rechazar' }).last().click();
      await expect(pendingRow).toHaveAttribute('data-status', 'rejected');
    } finally {
      await deleteDomainRequestViaApi(page, request.id);
    }
  });

  test('should filter requests by status @domains', async ({ page }) => {
    const approvedRequest = await createPendingDomainRequest(page);
    await approveDomainRequestViaApi(page, approvedRequest.id);
    const pendingRequest = await createPendingDomainRequest(page);
    try {
      const requestsPage = new DomainRequestsPage(page);
      await requestsPage.goto();

      const statusFilter = page.getByRole('combobox', { name: /Filtrar por estado/i });
      await expect(statusFilter).toBeVisible();
      await statusFilter.selectOption('approved');

      await expect(page.locator('.animate-spin')).toBeHidden();
      await expect(getRequestRow(page, approvedRequest.domain)).toHaveAttribute(
        'data-status',
        'approved'
      );
      await expect(getRequestRow(page, pendingRequest.domain)).toHaveCount(0);
    } finally {
      await deleteDomainRequestViaApi(page, approvedRequest.id);
      await deleteDomainRequestViaApi(page, pendingRequest.id);
    }
  });

  test('should render domain details inline in the request row @domains', async ({ page }) => {
    const request = await createPendingDomainRequest(page, {
      reason: 'Request detail coverage',
      machineHostname: 'inline-detail-host',
    });

    try {
      const requestsPage = new DomainRequestsPage(page);
      await requestsPage.goto();

      const row = getRequestRow(page, request.domain);
      await expect(row).toHaveAttribute('data-status', 'pending');
      await expect(row).toContainText(request.domain);
      await expect(row).toContainText('Request detail coverage');
      await expect(row).toContainText('inline-detail-host');
      await expect(row).toContainText(/Manual\/API/i);
    } finally {
      await deleteDomainRequestViaApi(page, request.id);
    }
  });
});

test.describe('Teacher Access Boundaries', () => {
  test('should keep domain request navigation admin-only for teachers @domains @teacher', async ({
    page,
  }) => {
    await loginAsTeacher(page);
    await waitForNetworkIdle(page);

    await expect(
      page.getByRole('button', { name: /Domain Control|Control de Dominios/i })
    ).toHaveCount(0);
    await expect(page.getByRole('heading', { name: /My Dashboard|Mi Panel/i })).toBeVisible();
  });

  test('should show the teacher allowed policies on the panel @domains @teacher', async ({
    page,
  }) => {
    await loginAsTeacher(page);
    await waitForNetworkIdle(page);

    const policySelect = page.locator('#teacher-control-group');
    await expect(policySelect).toBeVisible();
    await expect(policySelect).toContainText('E2E Test Group');
  });
});

test.describe('Whitelist Management', () => {
  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);
  });

  test('should display whitelist domains in group @domains @whitelist', async ({ page }) => {
    const groupsPage = new GroupsPage(page);
    await groupsPage.goto();

    // Click on first group
    const firstGroup = page.locator('[data-testid="group-card"]').first();

    if (await firstGroup.isVisible()) {
      await firstGroup.click();

      // Should show domains list
      await expect(page.getByText(/Dominios|Domains|Whitelist/i)).toBeVisible({ timeout: 5000 });
    }
  });

  test('should add domain to whitelist manually @domains @whitelist', async ({ page }) => {
    const groupsPage = new GroupsPage(page);
    await groupsPage.goto();

    // Open first group
    const firstGroup = page.locator('[data-testid="group-card"]').first();
    if (await firstGroup.isVisible()) {
      await firstGroup.click();
      await waitForNetworkIdle(page);

      // Click add domain
      const addButton = page.getByRole('button', { name: /Añadir|Add|Nuevo/i });
      if (await addButton.isVisible()) {
        await addButton.click();

        const testDomain = createTestDomain();

        // Fill domain form
        await page.getByLabel(/Dominio|Domain/i).fill(testDomain.domain);
        await page.getByRole('button', { name: /Guardar|Save|Añadir/i }).click();

        // Should show success
        await expect(page.getByText(/añadido|added|éxito/i)).toBeVisible({ timeout: 5000 });
      }
    }
  });

  test('should remove domain from whitelist @domains @whitelist', async ({ page }) => {
    const groupsPage = new GroupsPage(page);
    await groupsPage.goto();

    const firstGroup = page.locator('[data-testid="group-card"]').first();
    if (await firstGroup.isVisible()) {
      await firstGroup.click();
      await waitForNetworkIdle(page);

      // Find a domain to remove
      const domainRow = page.locator('[data-testid="domain-row"]').first();
      if (await domainRow.isVisible()) {
        // Click remove/delete button
        await domainRow.getByRole('button', { name: /Eliminar|Remove|Delete/i }).click();

        // Confirm deletion
        await page.getByRole('button', { name: /Confirmar|Confirm|Sí/i }).click();

        // Should show success
        await expect(page.getByText(/eliminado|removed|éxito/i)).toBeVisible({ timeout: 5000 });
      }
    }
  });

  test('should search domains within whitelist @domains @whitelist', async ({ page }) => {
    const groupsPage = new GroupsPage(page);
    await groupsPage.goto();

    const firstGroup = page.locator('[data-testid="group-card"]').first();
    if (await firstGroup.isVisible()) {
      await firstGroup.click();
      await waitForNetworkIdle(page);

      // Use search input
      const searchInput = page.getByPlaceholder(/Buscar|Search/i);
      if (await searchInput.isVisible()) {
        await searchInput.fill('google');
        await waitForNetworkIdle(page);

        // Results should be filtered
        const visibleDomains = page.locator('[data-testid="domain-row"]:visible');
        const count = await visibleDomains.count();

        // All visible domains should contain 'google'
        for (let i = 0; i < count; i++) {
          const text = await visibleDomains.nth(i).textContent();
          expect(text?.toLowerCase()).toContain('google');
        }
      }
    }
  });
});
