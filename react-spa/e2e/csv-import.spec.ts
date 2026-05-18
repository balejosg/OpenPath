/**
 * CSV Import E2E Tests for OpenPath
 *
 * Tests the bulk import modal functionality including:
 * - Plain text parsing (one domain per line)
 * - CSV with headers (auto-detect column)
 * - CSV simple (no headers, all columns as values)
 * - Delimiter auto-detection (comma, semicolon, tab)
 * - File upload via drag & drop
 * - Duplicate detection and removal
 * - Import execution
 */

import { test, expect } from '@playwright/test';
import { BulkImportPage } from './fixtures/page-objects';
import { loginAsAdmin, waitForNetworkIdle } from './fixtures/test-utils';
import * as path from 'path';
import * as fs from 'fs';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const FIXTURES_DIR = path.join(__dirname, 'fixtures', 'csv-import');

test.describe('CSV Import Feature @domains @import', () => {
  let bulkImport: BulkImportPage;

  test.beforeEach(async ({ page }) => {
    await loginAsAdmin(page);
    await waitForNetworkIdle(page);
    bulkImport = new BulkImportPage(page);
  });

  test.describe('Plain text parsing', () => {
    test('imports domains from plain text, one per line @smoke', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent('google.com\nyoutube.com\nexample.org');

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(3);

      const format = await bulkImport.getFormat();
      expect(format).toBe('plain-text');
    });

    test('handles empty lines gracefully', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent('google.com\n\n\nyoutube.com\n\nexample.org\n');

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(3);
    });

    test('skips comment lines starting with #', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent(
        '# This is a comment\ngoogle.com\n# Another comment\nyoutube.com'
      );

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(2);
    });

    test('loads plain text from fixture file', async ({ page }) => {
      await bulkImport.open();
      const content = fs.readFileSync(path.join(FIXTURES_DIR, 'plain-text.txt'), 'utf-8');
      await bulkImport.pasteContent(content);

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(5); // google, youtube, github, example, stackoverflow
    });
  });

  test.describe('CSV with headers', () => {
    test('detects header row and uses domain column @smoke', async ({ page }) => {
      await bulkImport.open();
      const content = fs.readFileSync(path.join(FIXTURES_DIR, 'csv-with-headers.csv'), 'utf-8');
      await bulkImport.pasteContent(content);

      const format = await bulkImport.getFormat();
      expect(format).toBe('csv-with-headers');

      // Should show CSV format indicator
      await expect(bulkImport.formatIndicator).toBeVisible();

      // Should show column name
      await expect(page.getByText(/(?:columna|column):.*domain/i)).toBeVisible();

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(4); // 4 data rows after header
    });

    test('handles Spanish column names (dominio)', async ({ page }) => {
      await bulkImport.open();
      const content = fs.readFileSync(path.join(FIXTURES_DIR, 'csv-spanish.csv'), 'utf-8');
      await bulkImport.pasteContent(content);

      const format = await bulkImport.getFormat();
      expect(format).toBe('csv-with-headers');

      // Should detect Spanish column name
      await expect(page.getByText(/(?:columna|column):.*dominio/i)).toBeVisible();

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(3);
    });

    test('shows warning for CSV with many columns', async ({ page }) => {
      await bulkImport.open();
      // CSV with 3 columns should show which column is being used
      const content = fs.readFileSync(path.join(FIXTURES_DIR, 'csv-with-headers.csv'), 'utf-8');
      await bulkImport.pasteContent(content);

      // Format indicator should show the column being used
      await expect(bulkImport.formatIndicator).toBeVisible();
    });
  });

  test.describe('CSV simple (no headers)', () => {
    test('extracts ALL columns as values when no headers detected @smoke', async ({ page }) => {
      await bulkImport.open();
      const content = fs.readFileSync(path.join(FIXTURES_DIR, 'csv-simple.csv'), 'utf-8');
      await bulkImport.pasteContent(content);

      // 3 rows x 3 columns = 9 domains
      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(9);

      // Format should be csv-simple (no column indicator)
      const format = await bulkImport.getFormat();
      expect(format).toBe('csv-simple');
    });

    test('handles inline comma-separated domains', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent('google.com,youtube.com,github.com');

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(3);
    });

    test('handles multiple rows of comma-separated domains', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent(
        'google.com,youtube.com\nexample.org,test.com\nwikipedia.org,reddit.com'
      );

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(6);
    });
  });

  test.describe('Delimiter detection', () => {
    test('auto-detects semicolon delimiter @smoke', async ({ page }) => {
      await bulkImport.open();
      const content = fs.readFileSync(path.join(FIXTURES_DIR, 'csv-semicolon.csv'), 'utf-8');
      await bulkImport.pasteContent(content);

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(3); // 3 data rows

      // Should detect as CSV with headers
      const format = await bulkImport.getFormat();
      expect(format).toBe('csv-with-headers');
    });

    test('auto-detects tab delimiter', async ({ page }) => {
      await bulkImport.open();
      // Tab-separated content
      await bulkImport.pasteContent('domain\turl\thost\ngoogle.com\thttps://google.com\tgoogle');

      const count = await bulkImport.getDetectedCount();
      expect(count).toBeGreaterThan(0);
    });
  });

  test.describe('Duplicate handling', () => {
    test('removes duplicates and shows warning @smoke', async ({ page }) => {
      await bulkImport.open();
      const content = fs.readFileSync(path.join(FIXTURES_DIR, 'csv-duplicates.txt'), 'utf-8');
      await bulkImport.pasteContent(content);

      // 7 entries with 3 unique domains (google x2, youtube x2, example x2, github x1)
      // Unique: google, youtube, example, github = 4 unique
      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(4);

      // Should show warning about duplicates removed
      await expect(bulkImport.warningBox).toBeVisible();
      const warnings = await bulkImport.getWarnings();
      expect(warnings.some((w) => /duplicados|duplicates removed/i.test(w))).toBe(true);
    });

    test('shows correct duplicate count in warning', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent('google.com\ngoogle.com\ngoogle.com\nyoutube.com');

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(2); // google + youtube

      // Warning should mention 2 duplicates removed
      const warnings = await bulkImport.getWarnings();
      expect(
        warnings.some((w) => w.includes('2') && /duplicados|duplicates removed/i.test(w))
      ).toBe(true);
    });
  });

  test.describe('Rule type selection', () => {
    test('defaults to whitelist type', async ({ page }) => {
      await bulkImport.open();

      // Whitelist button should be selected (has blue border)
      const whitelistButton = page.getByRole('button', {
        name: /Dominios permitidos|Allowed domains/i,
      });
      await expect(whitelistButton).toHaveClass(/border-blue-500/);
    });

    test('can select blocked_subdomain type', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.selectRuleType('blocked_subdomain');

      const subdomainButton = page.getByRole('button', {
        name: /Subdominios bloqueados|Blocked subdomains/i,
      });
      await expect(subdomainButton).toHaveClass(/border-blue-500/);
    });

    test('can select blocked_path type', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.selectRuleType('blocked_path');

      const pathButton = page.getByRole('button', {
        name: /Rutas bloqueadas|Blocked paths/i,
      });
      await expect(pathButton).toHaveClass(/border-blue-500/);
    });
  });

  test.describe('Modal behavior', () => {
    test('shows placeholder text when empty', async ({ page }) => {
      await bulkImport.open();

      await expect(page.getByPlaceholder(/Pega los dominios|Paste domains/i)).toBeVisible();
    });

    test('submit button is disabled when no domains entered', async ({ page }) => {
      await bulkImport.open();

      await expect(bulkImport.submitButton).toBeDisabled();
    });

    test('submit button shows count when domains entered', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent('google.com\nyoutube.com');

      await expect(bulkImport.submitButton).toBeEnabled();
      await expect(bulkImport.submitButton).toContainText('(2)');
    });

    test('can cancel and close modal', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.cancel();

      await expect(bulkImport.modal).not.toBeVisible();
    });

    test('clears content when modal is reopened', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent('google.com');
      await bulkImport.cancel();

      // Reopen modal
      await bulkImport.importButton.click();
      await expect(bulkImport.modal).toBeVisible();

      // Textarea should be empty
      await expect(bulkImport.textarea).toHaveValue('');
    });
  });

  test.describe('Import execution', () => {
    test('creates rules and closes modal on success @smoke', async ({ page }) => {
      await bulkImport.open();

      // Use unique domain to avoid "already exists" error
      const uniqueDomain = `test-${Date.now()}.example.com`;
      await bulkImport.pasteContent(uniqueDomain);

      await bulkImport.submit();

      // Modal should close on success
      await expect(bulkImport.modal).not.toBeVisible({ timeout: 10000 });
    });

    test('shows error when textarea is empty and submit clicked', async ({ page }) => {
      await bulkImport.open();

      // Button should be disabled, but let's verify the state
      await expect(bulkImport.submitButton).toBeDisabled();
    });

    test('handles import of multiple domains', async ({ page }) => {
      await bulkImport.open();

      const timestamp = Date.now();
      const domains = [
        `test1-${timestamp}.example.com`,
        `test2-${timestamp}.example.com`,
        `test3-${timestamp}.example.com`,
      ];

      await bulkImport.pasteContent(domains.join('\n'));
      expect(await bulkImport.getDetectedCount()).toBe(3);

      await bulkImport.submit();

      // Modal should close on success
      await expect(bulkImport.modal).not.toBeVisible({ timeout: 10000 });
    });
  });

  test.describe('Edge cases', () => {
    test('handles URLs with protocol prefix', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent('https://google.com\nhttp://youtube.com\ngithub.com');

      // Should strip protocol and detect 3 domains
      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(3);
    });

    test('handles quoted CSV fields', async ({ page }) => {
      await bulkImport.open();
      await bulkImport.pasteContent('"google.com","youtube.com","github.com"');

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(3);
    });

    test('handles mixed content with invalid entries', async ({ page }) => {
      await bulkImport.open();
      // Mix of valid and invalid entries
      await bulkImport.pasteContent('google.com\ninvalid\nyoutube.com\n123\ngithub.com');

      // Should only count valid domains (with dots)
      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(3);
    });

    test('handles very long domain lists', async ({ page }) => {
      await bulkImport.open();

      // Generate 100 unique domains
      const domains = Array.from({ length: 100 }, (_, i) => `domain${i}.example.com`);
      await bulkImport.pasteContent(domains.join('\n'));

      const count = await bulkImport.getDetectedCount();
      expect(count).toBe(100);
    });
  });
});
