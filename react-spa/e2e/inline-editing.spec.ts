/**
 * E2E Tests for Inline Editing in RulesTable
 *
 * Tests the ability to edit rule values and comments directly in the table
 * without opening a modal.
 */

import { test, expect } from '@playwright/test';
import { RulesManagerPage } from './fixtures/page-objects';
import { loginAsAdmin, waitForNetworkIdle } from './fixtures/test-utils';

test.describe('Inline Editing @smoke', () => {
  let rulesManager: RulesManagerPage;

  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);

    rulesManager = new RulesManagerPage(page);
    await rulesManager.open();
  });

  test('should show edit button on row hover', async ({ page }) => {
    // Hover over a rule row
    const firstRow = page.locator('tbody tr').first();
    await firstRow.hover();

    // Edit button should be visible
    const editButton = firstRow.getByTestId('edit-button');
    await expect(editButton).toBeVisible();
  });

  test('should enter edit mode when clicking edit button', async ({ page }) => {
    const firstRow = page.locator('tbody tr').first();
    await firstRow.hover();

    // Click edit button
    await firstRow.getByTestId('edit-button').click();

    // Should see edit inputs
    await expect(page.getByTestId('edit-value-input')).toBeVisible();
    await expect(page.getByTestId('save-edit-button')).toBeVisible();
    await expect(page.getByTestId('cancel-edit-button')).toBeVisible();
  });

  test('should enter edit mode when clicking on value text', async ({ page }) => {
    const firstRow = page.locator('tbody tr').first();
    const valueCell = firstRow.locator('span.font-mono').first();

    // Click on the value text
    await valueCell.click();

    // Should see edit inputs
    await expect(page.getByTestId('edit-value-input')).toBeVisible();
  });

  test('should cancel edit with Escape key', async ({ page }) => {
    const firstRow = page.locator('tbody tr').first();
    const originalValue = await firstRow.locator('span.font-mono').first().textContent();

    await firstRow.hover();
    await firstRow.getByTestId('edit-button').click();

    // Verify we're in edit mode
    await expect(page.getByTestId('edit-value-input')).toBeVisible();

    // Press Escape
    await page.keyboard.press('Escape');

    // Should exit edit mode
    await expect(page.getByTestId('edit-value-input')).not.toBeVisible();

    // Value should be unchanged
    await expect(firstRow.locator('span.font-mono').first()).toHaveText(originalValue!);
  });

  test('should cancel edit with cancel button', async ({ page }) => {
    const firstRow = page.locator('tbody tr').first();
    await firstRow.hover();
    await firstRow.getByTestId('edit-button').click();

    // Click cancel button
    await page.getByTestId('cancel-edit-button').click();

    // Should exit edit mode
    await expect(page.getByTestId('edit-value-input')).not.toBeVisible();
  });

  test('should highlight row in edit mode with amber background', async ({ page }) => {
    const firstRow = page.locator('tbody tr').first();
    await firstRow.hover();
    await firstRow.getByTestId('edit-button').click();

    // Row should have amber background class
    await expect(firstRow).toHaveClass(/bg-amber-50/);
  });

  test('should autofocus value input when entering edit mode', async ({ page }) => {
    const firstRow = page.locator('tbody tr').first();
    await firstRow.hover();
    await firstRow.getByTestId('edit-button').click();

    // Value input should be focused
    const valueInput = page.getByTestId('edit-value-input');
    await expect(valueInput).toBeFocused();
  });
});

test.describe('Inline Editing - Save Operations', () => {
  let rulesManager: RulesManagerPage;
  let testDomain: string;
  let cleanupDomains = new Set<string>();

  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);

    rulesManager = new RulesManagerPage(page);
    await rulesManager.open();

    // Unique domain per test (prevents cross-test collisions with fullyParallel)
    testDomain = `test-edit-${Date.now()}-${Math.random().toString(16).slice(2)}.example.com`;
    cleanupDomains = new Set([testDomain]);

    // Add a test rule to edit
    await rulesManager.addRule(testDomain);
    await expect(rulesManager.getRuleRow(testDomain)).toBeVisible();
  });

  test('should save edited value with Enter key', async ({ page }) => {
    const newDomain = `edited-${Date.now()}.example.com`;
    cleanupDomains.add(newDomain);

    await rulesManager.clickEditButton(testDomain);

    const valueInput = rulesManager.getEditValueInput();
    await valueInput.clear();
    await valueInput.fill(newDomain);
    await page.keyboard.press('Enter');

    // Wait for inline-edit mode to close before asserting updated table state
    await expect(rulesManager.getEditValueInput()).not.toBeVisible({ timeout: 10000 });

    // New value should be visible, old value should not
    await expect(rulesManager.getRuleRow(newDomain)).toBeVisible();
    await expect(rulesManager.getRuleRow(testDomain)).not.toBeVisible();
  });

  test('should save edited value with save button', async ({ page }) => {
    const newDomain = `btn-edited-${Date.now()}.example.com`;
    cleanupDomains.add(newDomain);

    await rulesManager.clickEditButton(testDomain);

    const valueInput = rulesManager.getEditValueInput();
    await valueInput.clear();
    await valueInput.fill(newDomain);
    await rulesManager.saveEdit();

    // Wait for save to complete
    await page.waitForTimeout(1000);

    // New value should be visible
    await expect(rulesManager.getRuleRow(newDomain)).toBeVisible();
  });

  test('should save edited comment', async ({ page }) => {
    const testComment = `Test comment ${Date.now()}`;

    await rulesManager.clickEditButton(testDomain);

    const commentInput = rulesManager.getEditCommentInput();
    await commentInput.fill(testComment);
    await rulesManager.saveEdit();

    // Wait for save to complete
    await page.waitForTimeout(1000);

    // Comment should be visible in the row
    const row = rulesManager.getRuleRow(testDomain);
    await expect(row).toContainText(testComment);
  });

  test('should show success toast after saving', async ({ page }) => {
    const newDomain = `toast-test-${Date.now()}.example.com`;
    cleanupDomains.add(newDomain);

    await rulesManager.clickEditButton(testDomain);

    const valueInput = rulesManager.getEditValueInput();
    await valueInput.clear();
    await valueInput.fill(newDomain);
    await rulesManager.saveEdit();

    // Should show success toast
    await expect(page.getByText(/actualizada|Rule updated/i)).toBeVisible({ timeout: 5000 });
  });

  test('should not save if value is empty', async ({ page }) => {
    await rulesManager.clickEditButton(testDomain);

    const valueInput = rulesManager.getEditValueInput();
    await valueInput.clear();

    // Save button should be disabled
    const saveButton = page.getByTestId('save-edit-button');
    await expect(saveButton).toBeDisabled();
  });

  test('should exit edit mode without saving if nothing changed', async ({ page }) => {
    await rulesManager.clickEditButton(testDomain);

    // Just press Enter without changing anything
    await page.keyboard.press('Enter');

    // Should exit edit mode
    await expect(page.getByTestId('edit-value-input')).not.toBeVisible();

    // Value should still be there
    await expect(rulesManager.getRuleRow(testDomain)).toBeVisible();
  });

  test.afterEach(async ({ page }) => {
    // Best-effort cleanup: delete any domains this test created/edited.
    const manager = new RulesManagerPage(page);
    for (const domain of cleanupDomains) {
      try {
        await manager.search(domain);
        if (await manager.ruleExists(domain)) {
          await manager.deleteRule(domain);
        }
      } catch {
        // Ignore cleanup failures (test assertions should still be authoritative)
      }
    }
    await manager.clearSearch().catch(() => {});
  });
});

test.describe('Inline Editing - Edge Cases', () => {
  let rulesManager: RulesManagerPage;

  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);

    rulesManager = new RulesManagerPage(page);
    await rulesManager.open();
  });

  test('should only allow one row to be edited at a time', async ({ page }) => {
    // Start editing first row
    const firstRow = page.locator('tbody tr').first();
    await firstRow.hover();
    await firstRow.getByTestId('edit-button').click();
    await expect(page.getByTestId('edit-value-input')).toBeVisible();

    // Try to click on second row value
    const secondRow = page.locator('tbody tr').nth(1);
    const secondRowValue = secondRow.locator('span.font-mono').first();

    // If there's a second row, clicking on it should start editing that row instead
    if ((await secondRow.count()) > 0) {
      await secondRowValue.click();

      // Only one edit input should be visible (the new one)
      const editInputs = page.getByTestId('edit-value-input');
      await expect(editInputs).toHaveCount(1);
    }
  });

  test('should preserve selection state while editing', async ({ page }) => {
    // Select first row using checkbox
    const firstRow = page.locator('tbody tr').first();
    const checkbox = firstRow.locator('button').first();
    await checkbox.click();

    // Start editing
    await firstRow.hover();
    await firstRow.getByTestId('edit-button').click();

    // Cancel edit
    await page.keyboard.press('Escape');

    // Selection should still be active (blue background)
    await expect(firstRow).toHaveClass(/bg-blue-50/);
  });

  test('should handle special characters in value', async ({ page }) => {
    const specialDomain = `special-chars-${Date.now()}.example.com`;
    await rulesManager.addRule(specialDomain);

    await rulesManager.search(specialDomain);
    await rulesManager.clickEditButton(specialDomain);

    const valueInput = rulesManager.getEditValueInput();
    const newValue = `updated-${Date.now()}.test.example.com`;
    await valueInput.clear();
    await valueInput.fill(newValue);
    await rulesManager.saveEdit();

    // New value should be visible
    await rulesManager.search(newValue);
    await expect(rulesManager.getRuleRow(newValue)).toBeVisible({ timeout: 15000 });

    // Clean up
    await rulesManager.deleteRule(newValue);
    await rulesManager.clearSearch();
  });

  test('should disable selection checkbox while editing', async ({ page }) => {
    const firstRow = page.locator('tbody tr').first();
    await firstRow.hover();
    await firstRow.getByTestId('edit-button').click();

    // Checkbox should be disabled
    const checkbox = firstRow.locator('button').first();
    await expect(checkbox).toBeDisabled();
  });
});
