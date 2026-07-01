/**
 * Page Object Models for OpenPath E2E Tests
 *
 * Provides reusable abstractions for common UI interactions.
 */

import { Page, Locator, expect } from '@playwright/test';

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function clickSidebarNav(page: Page, navButton: Locator): Promise<void> {
  // On mobile, the sidebar is off-canvas until the hamburger is clicked.
  const menuButton = page.getByRole('button', { name: /Abrir menú|Open menu/i });
  const menuVisible = await menuButton.isVisible({ timeout: 500 }).catch(() => false);

  if (menuVisible) {
    const sidebar = page.locator('aside').first();
    const isClosed = await sidebar
      .evaluate((el) => el.className.includes('-translate-x-full'))
      .catch(() => false);

    if (isClosed) {
      await menuButton.click();
      await expect(sidebar).not.toHaveClass(/-translate-x-full/);
      // Allow slide-in transition to settle.
      await page.waitForTimeout(50);
    }
  }

  await navButton.scrollIntoViewIfNeeded().catch(() => {});
  await navButton.click();
}

export class LoginPage {
  readonly page: Page;
  readonly emailInput: Locator;
  readonly passwordInput: Locator;
  readonly loginButton: Locator;
  readonly googleLoginButton: Locator;
  readonly registerLink: Locator;
  readonly errorMessage: Locator;
  readonly loadingSpinner: Locator;

  constructor(page: Page) {
    this.page = page;
    this.emailInput = page.locator('input[type="email"]');
    this.passwordInput = page.locator('input[type="password"]');
    this.loginButton = page.getByRole('button', { name: /Entrar|Sign in/i });
    this.googleLoginButton = page.getByRole('button', { name: /Google/i });
    this.registerLink = page.getByRole('button', { name: /Solicitar acceso|Request access/i });
    this.errorMessage = page.getByText(
      /Credenciales inv[aá]lidas|Invalid credentials|error de conexi[oó]n|connection error/i
    );
    this.loadingSpinner = page.locator('.animate-spin');
  }

  async goto() {
    for (let attempt = 1; attempt <= 4; attempt += 1) {
      await this.page.goto('./');
      await this.page.waitForLoadState('networkidle');

      const loginVisible = await this.page
        .getByRole('heading', { name: /Acceso seguro|Secure Sign In/i })
        .isVisible({ timeout: 1000 })
        .catch(() => false);

      if (loginVisible) {
        return;
      }

      const bodyText =
        (await this.page
          .locator('body')
          .textContent()
          .catch(() => '')) ?? '';
      const spaDistMissing = bodyText.includes('"code":"ENOENT"');

      if (!spaDistMissing || attempt === 4) {
        return;
      }

      await this.page.waitForTimeout(500 * attempt);
    }
  }

  async login(email: string, password: string) {
    await this.emailInput.fill(email);
    await this.passwordInput.fill(password);
    await this.loginButton.click();
  }

  async expectLoaded() {
    await expect(
      this.page.getByRole('heading', { name: /Acceso seguro|Secure Sign In/i })
    ).toBeVisible();
    await expect(this.emailInput).toBeVisible();
    await expect(this.passwordInput).toBeVisible();
  }

  async expectError() {
    await expect(this.errorMessage).toBeVisible();
  }

  async navigateToRegister() {
    await this.registerLink.click();
    await expect(
      this.page.getByRole('heading', { name: /Registro institucional|Institution Registration/i })
    ).toBeVisible();
  }
}

export class RegisterPage {
  readonly page: Page;
  readonly emailInput: Locator;
  readonly nameInput: Locator;
  readonly passwordInput: Locator;
  readonly confirmPasswordInput: Locator;
  readonly termsCheckbox: Locator;
  readonly submitButton: Locator;
  readonly errorMessage: Locator;

  constructor(page: Page) {
    this.page = page;
    this.emailInput = page.getByPlaceholder('correo@ejemplo.com');
    this.nameInput = page.getByPlaceholder(/Tu nombre completo|Your full name/i);
    this.passwordInput = page.locator('input[type="password"]').first();
    this.confirmPasswordInput = page.locator('input[type="password"]').last();
    this.termsCheckbox = page.getByLabel(/Acepto los|By registering/i);
    this.submitButton = page.getByRole('button', {
      name: /Registrarse|Crear cuenta|Create Account/i,
    });
    this.errorMessage = page.locator('[role="alert"]');
  }

  async fillForm(data: { email: string; name: string; password: string }) {
    await this.emailInput.fill(data.email);
    await this.nameInput.fill(data.name);
    await this.passwordInput.fill(data.password);
    await this.confirmPasswordInput.fill(data.password);
    await this.termsCheckbox.check();
  }

  async submit() {
    await this.submitButton.click();
  }
}

export class DashboardPage {
  readonly page: Page;
  readonly activeGroupsStat: Locator;
  readonly allowedDomainsStat: Locator;
  readonly blockedSitesStat: Locator;
  readonly pendingRequestsStat: Locator;
  readonly systemStatusBanner: Locator;
  readonly auditFeed: Locator;
  readonly trafficChart: Locator;

  constructor(page: Page) {
    this.page = page;
    this.activeGroupsStat = page.getByText(/Grupos Activos|Active Groups/i).locator('..');
    this.allowedDomainsStat = page.getByText(/Dominios Permitidos|Allowed Domains/i).locator('..');
    this.blockedSitesStat = page.getByText(/Sitios Bloqueados|Blocked Sites/i).locator('..');
    this.pendingRequestsStat = page
      .getByText(/Solicitudes Pendientes|Pending Requests/i)
      .locator('..');
    this.systemStatusBanner = page.getByText(/Estado del Sistema|System Status/i);
    this.auditFeed = page.getByText(/Auditoría Reciente|Recent Audit/i).locator('..');
    this.trafficChart = page.locator('[data-testid="traffic-chart"]');
  }

  async goto() {
    // SPA uses state-based navigation, click sidebar if already logged in
    // Otherwise just ensure we're on the page
    const sidebarDashboard = this.page.getByRole('button', { name: /Dashboard|Panel de Control/i });
    await clickSidebarNav(this.page, sidebarDashboard);
    await this.page.waitForLoadState('networkidle');
  }

  async expectLoaded() {
    await expect(this.activeGroupsStat).toBeVisible();
    await expect(this.systemStatusBanner).toBeVisible();
  }

  async getStatValue(statName: 'groups' | 'domains' | 'blocked' | 'pending'): Promise<string> {
    const statMap = {
      groups: this.activeGroupsStat,
      domains: this.allowedDomainsStat,
      blocked: this.blockedSitesStat,
      pending: this.pendingRequestsStat,
    };
    const value = await statMap[statName].locator('text=/\\d+/').textContent();
    return value || '0';
  }
}

export class GroupsPage {
  readonly page: Page;
  readonly newGroupButton: Locator;
  readonly groupList: Locator;
  readonly searchInput: Locator;

  constructor(page: Page) {
    this.page = page;
    this.newGroupButton = page.getByRole('button', { name: /Nuevo Grupo|New Group/i });
    this.groupList = page.locator('[data-testid="group-list"]');
    this.searchInput = page.getByPlaceholder(/Buscar|Search/i);
  }

  async goto() {
    // SPA uses state-based navigation, click sidebar
    const sidebarGroups = this.page.getByRole('button', {
      name: /Group Policies|Políticas de Grupo/i,
    });
    await clickSidebarNav(this.page, sidebarGroups);
    await this.page.waitForLoadState('networkidle');
  }

  async expectLoaded() {
    await expect(
      this.page.getByText(/Groups and Policies|Grupos y Políticas|Políticas de Grupo/i)
    ).toBeVisible();
  }

  async getGroupCount(): Promise<number> {
    const groups = await this.page.locator('[data-testid="group-card"]').count();
    return groups;
  }

  async clickManageDomains(groupName: string) {
    const group = this.page.getByText(groupName).locator('..').locator('..');
    await group.getByRole('button', { name: /Gestionar dominios|Manage domains/i }).click();
  }

  async createGroup(name: string, description: string) {
    await this.newGroupButton.click();
    await this.page.getByLabel(/Nombre/i).fill(name);
    await this.page.getByLabel(/Descripción/i).fill(description);
    await this.page.getByRole('button', { name: /Crear|Guardar/i }).click();
  }
}

export class DomainRequestsPage {
  readonly page: Page;
  readonly filterDropdown: Locator;

  constructor(page: Page) {
    this.page = page;
    this.filterDropdown = page.getByRole('combobox');
  }

  async goto() {
    // SPA uses state-based navigation, click sidebar
    const domainsButton = this.page.getByRole('button', {
      name: /Domain Control|Control de Dominios/i,
    });
    await clickSidebarNav(this.page, domainsButton);
    await this.page.waitForLoadState('networkidle');
  }

  async approveRequest(domain: string) {
    const row = this.page.getByText(domain).locator('..').locator('..');
    await row.getByRole('button', { name: /Aprobar/i }).click();
    await this.page.getByRole('button', { name: /Confirmar/i }).click();
  }

  async rejectRequest(domain: string, reason: string) {
    const row = this.page.getByText(domain).locator('..').locator('..');
    await row.getByRole('button', { name: /Rechazar/i }).click();
    await this.page.getByLabel(/Motivo|Razón/i).fill(reason);
    await this.page.getByRole('button', { name: /Confirmar/i }).click();
  }

  async getPendingCount(): Promise<number> {
    return await this.page.locator('[data-testid="request-row"][data-status="pending"]').count();
  }
}

export class UsersPage {
  readonly page: Page;
  readonly newUserButton: Locator;
  readonly userList: Locator;

  constructor(page: Page) {
    this.page = page;
    this.newUserButton = page.getByRole('button', { name: /Nuevo Usuario|Añadir/i });
    this.userList = page.locator('[data-testid="user-list"]');
  }

  async goto() {
    const usersButton = this.page.getByRole('button', {
      name: /Users and Roles|Usuarios y Roles/i,
    });
    await clickSidebarNav(this.page, usersButton);
    await this.page.waitForLoadState('networkidle');
  }

  async createUser(email: string, role: 'admin' | 'teacher') {
    await this.newUserButton.click();
    await this.page.getByLabel(/Email|Correo/i).fill(email);
    await this.page.getByRole('combobox', { name: /Rol/i }).selectOption(role);
    await this.page.getByRole('button', { name: /Crear|Guardar/i }).click();
  }
}

// Bulk Import Modal page object
export class BulkImportPage {
  readonly page: Page;
  readonly importButton: Locator;
  readonly modal: Locator;
  readonly textarea: Locator;
  readonly dropZone: Locator;
  readonly formatIndicator: Locator;
  readonly warningBox: Locator;
  readonly countDisplay: Locator;
  readonly submitButton: Locator;
  readonly cancelButton: Locator;

  constructor(page: Page) {
    this.page = page;
    // The import button in RulesManager has text "Importar" with Upload icon
    this.importButton = page.getByRole('button', { name: /Importar|Import/i }).first();
    this.modal = page.getByRole('dialog');
    this.textarea = page.locator('textarea');
    this.dropZone = page.locator('[data-testid="drop-zone"]');
    this.formatIndicator = page.getByText(/Formato CSV detectado|CSV format detected/i);
    this.warningBox = page.locator('.bg-amber-50');
    // BulkImportModal shows counts like: "(3 detectados)" / "(1 detectado)"
    this.countDisplay = page.getByText(/\(\s*\d+\s+(detectad[oa]s?|detected)\s*\)/i);
    // Submit button in modal shows "Importar (N)" when there are domains
    this.submitButton = page
      .getByRole('dialog')
      .getByRole('button', { name: /^(Importar|Import)/i });
    this.cancelButton = page.getByRole('button', { name: /Cancelar|Cancel/i });
  }

  /**
   * Navigate to group policies page, select a group, and open bulk import modal
   */
  async open(): Promise<void> {
    // Navigate to Políticas de Grupo via sidebar
    const groupsButton = this.page.getByRole('button', {
      name: /Group Policies|Políticas de Grupo/i,
    });
    await clickSidebarNav(this.page, groupsButton);
    await this.page.waitForLoadState('networkidle');

    // Wait for groups page to load
    await this.page.waitForTimeout(500);

    // Prefer the seeded E2E group so the RulesManager opens on a stable dataset.
    // The my/admin card now navigates straight to RulesManager (no intermediate modal).
    const seededGroupCard = this.page
      .locator('div.bg-white.border.border-slate-200.rounded-lg')
      .filter({ hasText: /E2E Test Group/i })
      .first();
    const seededManageButton = seededGroupCard.getByRole('button', {
      name: /Gestionar dominios|Manage domains/i,
    });

    const manageButton = await Promise.race([
      seededManageButton
        .waitFor({ state: 'visible', timeout: 5000 })
        .then(() => seededManageButton),
      this.page
        .getByRole('button', { name: /Gestionar dominios|Manage domains/i })
        .first()
        .waitFor({ state: 'visible', timeout: 5000 })
        .then(() =>
          this.page.getByRole('button', { name: /Gestionar dominios|Manage domains/i }).first()
        ),
    ]);
    await manageButton.waitFor({ state: 'visible', timeout: 5000 });
    await manageButton.click();
    await this.page.waitForLoadState('networkidle');

    // Wait for RulesManager to load (look for the import button)
    await this.importButton.waitFor({ state: 'visible', timeout: 10000 });

    // Click the import button to open modal
    await this.importButton.click();
    await expect(this.modal).toBeVisible({ timeout: 5000 });
  }

  /**
   * Select a rule type in the modal
   */
  async selectRuleType(type: 'whitelist' | 'blocked_subdomain' | 'blocked_path'): Promise<void> {
    const labels: Record<string, RegExp> = {
      whitelist: /Dominios permitidos|Allowed domains/i,
      blocked_subdomain: /Subdominios bloqueados|Blocked subdomains/i,
      blocked_path: /Rutas bloqueadas|Blocked paths/i,
    };
    await this.page.getByRole('button', { name: labels[type] }).click();
  }

  /**
   * Paste content directly into the textarea
   */
  async pasteContent(content: string): Promise<void> {
    await this.textarea.fill(content);
    // Wait for parsing to complete
    await this.page.waitForTimeout(100);
  }

  /**
   * Upload a file using the file input (simulates drag & drop)
   */
  async uploadFile(filePath: string): Promise<void> {
    // Create a file input element and trigger file selection
    const fileInput = await this.page.evaluateHandle(() => {
      const input = document.createElement('input');
      input.type = 'file';
      input.style.display = 'none';
      document.body.appendChild(input);
      return input;
    });

    await (fileInput as unknown as Locator).setInputFiles(filePath);

    // Read file content and paste it (since actual drag-drop is complex in Playwright)
    const fs = await import('fs');
    const content = fs.readFileSync(filePath, 'utf-8');
    await this.textarea.fill(content);
    await this.page.waitForTimeout(100);
  }

  /**
   * Get the number of detected domains
   */
  async getDetectedCount(): Promise<number> {
    await this.countDisplay.waitFor({ state: 'visible', timeout: 5000 });
    const countText = await this.countDisplay.textContent();
    if (!countText) return 0;
    const match = countText.match(/(\d+)\s+(?:detectad[oa]s?|detected)/i);
    return match ? parseInt(match[1], 10) : 0;
  }

  /**
   * Get the detected format type
   */
  async getFormat(): Promise<'plain-text' | 'csv-with-headers' | 'csv-simple' | 'unknown'> {
    const hasFormatIndicator = await this.formatIndicator.isVisible().catch(() => false);
    if (!hasFormatIndicator) {
      return 'plain-text';
    }
    const hasColumnInfo = await this.page
      .getByText(/(?:columna|column):/i)
      .isVisible()
      .catch(() => false);
    return hasColumnInfo ? 'csv-with-headers' : 'csv-simple';
  }

  /**
   * Get all warning messages
   */
  async getWarnings(): Promise<string[]> {
    const warnings: string[] = [];
    const warningElements = this.warningBox.locator('div');
    const count = await warningElements.count();
    for (let i = 0; i < count; i++) {
      const text = await warningElements.nth(i).textContent();
      if (text) warnings.push(text);
    }
    return warnings;
  }

  /**
   * Get the column name being used (if CSV with headers)
   */
  async getColumnName(): Promise<string | null> {
    const columnInfo = this.page.getByText(/(?:columna|column):/i);
    if (await columnInfo.isVisible().catch(() => false)) {
      const text = await columnInfo.textContent();
      const match = text?.match(/(?:columna|column):\s*(\w+)/i);
      return match ? match[1] : null;
    }
    return null;
  }

  /**
   * Submit the import form
   */
  async submit(): Promise<void> {
    await this.submitButton.click();
  }

  /**
   * Close the modal without importing
   */
  async cancel(): Promise<void> {
    await this.cancelButton.click();
  }

  /**
   * Check if the modal is open
   */
  async isOpen(): Promise<boolean> {
    return await this.modal.isVisible().catch(() => false);
  }
}

// Header navigation component
export class Header {
  readonly page: Page;
  readonly userMenu: Locator;
  readonly logoutButton: Locator;

  constructor(page: Page) {
    this.page = page;
    this.userMenu = page.locator('[data-testid="user-menu"]');
    this.logoutButton = page.getByRole('menuitem', { name: /Cerrar sesión|Logout/i });
  }

  async logout() {
    await this.userMenu.click();
    await this.logoutButton.click();
  }
}

// Rules Manager page object for inline editing tests
export class RulesManagerPage {
  readonly page: Page;
  readonly rulesTable: Locator;
  readonly searchInput: Locator;
  readonly addRuleInput: Locator;
  readonly addRuleButton: Locator;

  constructor(page: Page) {
    this.page = page;
    this.rulesTable = page.locator('table');
    this.searchInput = page.getByPlaceholder(/Buscar en|Search across/i);
    this.addRuleInput = page.getByPlaceholder(/Añadir dominio|Add domain, subdomain, or path/i);
    this.addRuleButton = page.getByRole('button', { name: /Añadir|Add/i });
  }

  async search(value: string): Promise<void> {
    await this.searchInput.fill(value);
    await this.page.waitForTimeout(200);
  }

  async clearSearch(): Promise<void> {
    await this.searchInput.fill('');
    await this.page.waitForTimeout(200);
  }

  /**
   * Navigate to RulesManager for the first group
   */
  async open(): Promise<void> {
    // Navigate to Políticas de Grupo via sidebar
    const groupsButton = this.page.getByRole('button', {
      name: /Group Policies|Políticas de Grupo/i,
    });
    await clickSidebarNav(this.page, groupsButton);
    await this.page.waitForLoadState('networkidle');

    await this.page.waitForTimeout(500);

    // The my/admin card now navigates straight to RulesManager (no intermediate modal).
    const manageButton = this.page
      .getByRole('button', { name: /Gestionar dominios|Manage domains/i })
      .first();
    await manageButton.waitFor({ state: 'visible', timeout: 5000 });
    await manageButton.click();
    await this.page.waitForLoadState('networkidle');

    // Wait for RulesManager to load. Seed a baseline rule if the selected group is empty,
    // otherwise the table is intentionally replaced by the empty-state card.
    const emptyState = this.page.getByText(/No hay reglas configuradas|No rules configured/i);

    const loadedState = await Promise.race([
      this.rulesTable.waitFor({ state: 'visible', timeout: 10000 }).then(() => 'table' as const),
      emptyState.waitFor({ state: 'visible', timeout: 10000 }).then(() => 'empty' as const),
    ]);

    if (loadedState === 'empty') {
      await this.addRuleInput.fill('baseline-inline-edit.example.com');
      await this.addRuleButton.click();
      await this.page.waitForLoadState('networkidle').catch(() => {});
      await this.page.reload();
      await this.page.waitForLoadState('networkidle');
      await this.rulesTable.waitFor({ state: 'visible', timeout: 10000 });
    }
  }

  /**
   * Add a new rule
   */
  async addRule(value: string): Promise<void> {
    await this.addRuleInput.fill(value);
    await this.addRuleButton.click();
    // Rows may be paginated/sorted; use search to make the new row visible reliably.
    await this.search(value);
    await expect(this.getRuleRow(value)).toBeVisible({ timeout: 10000 });
    await this.clearSearch();
  }

  /**
   * Get a rule row by value
   */
  getRuleRow(value: string): Locator {
    return this.page.locator('tbody tr').filter({
      has: this.page.locator('span.font-mono', {
        hasText: new RegExp(`^${escapeRegExp(value)}$`),
      }),
    });
  }

  /**
   * Click edit button on a rule row
   */
  async clickEditButton(value: string): Promise<void> {
    const row = this.getRuleRow(value);
    await expect(row).toBeVisible({ timeout: 10000 });
    await row.hover();
    await row.getByTestId('edit-button').click();
  }

  /**
   * Click on a rule value to start inline editing (click-to-edit)
   */
  async clickToEdit(value: string): Promise<void> {
    const row = this.getRuleRow(value);
    await row.locator('span.font-mono').click();
  }

  /**
   * Double-click on a rule value to start inline editing
   */
  async doubleClickToEdit(value: string): Promise<void> {
    const row = this.getRuleRow(value);
    await row.locator('span.font-mono').dblclick();
  }

  /**
   * Check if a row is in edit mode
   */
  async isEditing(value: string): Promise<boolean> {
    const row = this.getRuleRow(value);
    return await row
      .getByTestId('edit-value-input')
      .isVisible()
      .catch(() => false);
  }

  /**
   * Get the value input in edit mode
   */
  getEditValueInput(): Locator {
    return this.page.getByTestId('edit-value-input');
  }

  /**
   * Get the comment input in edit mode
   */
  getEditCommentInput(): Locator {
    return this.page.getByTestId('edit-comment-input');
  }

  /**
   * Save the current edit
   */
  async saveEdit(): Promise<void> {
    const saveButton = this.page.getByTestId('save-edit-button');
    await saveButton.click();
    await expect(saveButton).toBeHidden({ timeout: 10000 });
  }

  /**
   * Cancel the current edit
   */
  async cancelEdit(): Promise<void> {
    await this.page.getByTestId('cancel-edit-button').click();
  }

  /**
   * Edit a rule's value inline
   */
  async editRuleValue(oldValue: string, newValue: string): Promise<void> {
    await this.clickEditButton(oldValue);
    const input = this.getEditValueInput();
    await input.clear();
    await input.fill(newValue);
    await this.saveEdit();
  }

  /**
   * Edit a rule's comment inline
   */
  async editRuleComment(value: string, newComment: string): Promise<void> {
    await this.clickEditButton(value);
    const input = this.getEditCommentInput();
    await input.clear();
    await input.fill(newComment);
    await this.saveEdit();
  }

  /**
   * Check if a rule exists in the table
   */
  async ruleExists(value: string): Promise<boolean> {
    return await this.getRuleRow(value)
      .isVisible()
      .catch(() => false);
  }

  /**
   * Get the comment text for a rule
   */
  async getRuleComment(value: string): Promise<string> {
    const row = this.getRuleRow(value);
    const commentCell = row.locator('td').nth(3); // Comment is the 4th column (0-indexed: checkbox, value, type, comment)
    return (await commentCell.textContent()) ?? '';
  }

  /**
   * Delete a rule
   */
  async deleteRule(value: string): Promise<void> {
    const row = this.getRuleRow(value);
    await row.hover();
    await row.getByTitle(/Eliminar|Delete|Revoke auto-approval/i).click();
    await this.page.waitForTimeout(500);
  }
}
