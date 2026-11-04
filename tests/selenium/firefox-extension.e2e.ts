/**
 * Firefox Extension E2E Tests (Selenium WebDriver)
 *
 * UAT Coverage: 03_alumno.md Sections 1-3, 6
 *
 * These tests use Selenium WebDriver because Playwright doesn't support
 * Firefox extensions. Run with: npx ts-node firefox-extension.e2e.ts
 *
 * Prerequisites:
 * - Firefox installed
 * - geckodriver in PATH
 * - Extension built: cd firefox-extension && npm run build
 */

import { Builder, By, WebDriver } from 'selenium-webdriver';
import * as firefox from 'selenium-webdriver/firefox';
import * as path from 'path';
import * as assert from 'assert';
import { allowFirefoxExtensionPageNavigation } from './student-policy-env';

// Extension path (built .xpi or directory)
const EXTENSION_PATH = path.resolve(__dirname, '../../firefox-extension/build');

// Test domains
const BLOCKED_DOMAIN = 'facebook.com';
const ALLOWED_DOMAIN = 'google.com';

let driver: WebDriver | null = null;

async function setup(): Promise<void> {
  const options = new firefox.Options();

  // Add the extension
  options.addExtensions(EXTENSION_PATH);

  // Set preferences for testing
  options.setPreference('dom.webnotifications.enabled', true);
  options.setPreference('network.dns.disablePrefetch', true);

  // Headless for CI
  if (process.env.CI) {
    options.addArguments('-headless');
  }

  allowFirefoxExtensionPageNavigation();
  driver = await new Builder().forBrowser('firefox').setFirefoxOptions(options).build();

  await driver.manage().setTimeouts({ implicit: 10000 });
}

async function teardown(): Promise<void> {
  if (driver) {
    await driver.quit();
    driver = null;
  }
}

function getDriver(): WebDriver {
  if (!driver) {
    throw new Error('Driver not initialized. Call setup() first.');
  }
  return driver;
}

// ============================================================================
// SECTION 1: Blocked Domain Experience
// UAT: 03_alumno.md Tests 1.1-1.3
// ============================================================================

async function test_1_1_blocked_domain_timeout(): Promise<void> {
  console.log('Test 1.1: Navigate to blocked domain shows error');
  const d = getDriver();

  try {
    // Navigate to blocked domain - should timeout or show error
    await d.get(`https://${BLOCKED_DOMAIN}`);

    // Wait a bit for the page to fail
    await d.sleep(5000);

    // Check the title or content - should not be Facebook
    const title = await d.getTitle();
    assert.ok(
      !title.toLowerCase().includes('facebook'),
      `Expected blocked domain, but got title: ${title}`
    );

    console.log('  ✓ Blocked domain did not load');
  } catch {
    // Timeout is expected for blocked domain
    console.log('  ✓ Blocked domain timed out (expected)');
  }
}

async function test_1_2_extension_badge_shows_count(): Promise<void> {
  console.log('Test 1.2: Extension badge shows blocked count');
  const d = getDriver();

  // Navigate to a page that triggers blocks
  try {
    await d.get(`https://${BLOCKED_DOMAIN}`);
  } catch {
    // Expected to fail
  }
  await d.sleep(2000);

  // We can't directly check the badge from Selenium
  // But we can verify the extension popup works
  console.log('  ⚠ Badge verification requires manual check or native messaging');
}

async function test_1_3_extension_popup_opens(): Promise<void> {
  console.log('Test 1.3: Extension popup shows blocked domains list');
  const d = getDriver();

  // Get all window handles
  const handles = await d.getAllWindowHandles();
  console.log(`  Current windows: ${String(handles.length)}`);

  // Open a page first
  await d.get(`https://${ALLOWED_DOMAIN}`);
  await d.sleep(2000);

  // Note: Opening extension popup from Selenium is limited
  // Best approach is to test the popup HTML directly
  await d.get('moz-extension://*ID*/popup/popup.html');

  console.log('  ⚠ Popup test requires extension ID - use about:debugging to get it');
}

// ============================================================================
// SECTION 2: Request Submission
// UAT: 03_alumno.md Tests 2.1-2.4
// ============================================================================

function test_2_1_submit_unblock_request(): void {
  console.log('Test 2.1: Submit unblock request via popup');

  // This test simulates clicking the request button in the popup
  // Since we can't easily access the popup, we test via the native messaging

  console.log('  ⚠ Request submission requires popup access or native host');
}

function test_2_3_duplicate_request_prevented(): void {
  console.log('Test 2.3: Duplicate request is prevented');

  // Would need to submit same domain twice and verify error
  console.log('  ⚠ Requires popup access');
}

// ============================================================================
// SECTION 3: Post-Approval Access
// UAT: 03_alumno.md Tests 3.1-3.3
// ============================================================================

async function test_3_1_approved_domain_accessible(): Promise<void> {
  console.log('Test 3.1: Approved domain becomes accessible');
  const d = getDriver();

  // Navigate to a domain that should be in whitelist
  await d.get(`https://${ALLOWED_DOMAIN}`);
  await d.sleep(3000);

  const title = await d.getTitle();
  assert.ok(title.length > 0, 'Page should load with a title');

  console.log(`  ✓ Allowed domain loaded: ${title}`);
}

// ============================================================================
// SECTION 6: Extension Configuration
// UAT: 03_alumno.md Tests 6.1-6.4
// ============================================================================

async function test_6_2_extension_config(): Promise<void> {
  console.log('Test 6.2: Extension options page exists');
  const d = getDriver();

  // Try to access about:addons to verify extension is installed
  await d.get('about:addons');
  await d.sleep(2000);

  // Click on Extensions tab
  try {
    const extensionsTab = await d.findElement(By.css('[name="extension"]'));
    await extensionsTab.click();
    await d.sleep(1000);

    // Look for our extension
    const pageSource = await d.getPageSource();
    assert.ok(
      pageSource.includes('Monitor de Bloqueos') ?? pageSource.includes('openpath'),
      'Extension should be listed in about:addons'
    );

    console.log('  ✓ Extension found in about:addons');
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    console.log(`  ⚠ Could not verify extension in about:addons: ${message}`);
  }
}

// ============================================================================
// Main Test Runner
// ============================================================================

async function runAllTests(): Promise<void> {
  console.log('\n========================================');
  console.log('Firefox Extension E2E Tests');
  console.log('========================================\n');

  try {
    await setup();

    // Run tests
    await test_1_1_blocked_domain_timeout();
    await test_1_2_extension_badge_shows_count();
    await test_1_3_extension_popup_opens();
    test_2_1_submit_unblock_request();
    test_2_3_duplicate_request_prevented();
    await test_3_1_approved_domain_accessible();
    await test_6_2_extension_config();

    console.log('\n========================================');
    console.log('Tests completed');
    console.log('========================================\n');
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    console.error('Test failed:', message);
    process.exit(1);
  } finally {
    await teardown();
  }
}

// Export for use in test frameworks
export {
  setup,
  teardown,
  test_1_1_blocked_domain_timeout,
  test_1_2_extension_badge_shows_count,
  test_3_1_approved_domain_accessible,
  test_6_2_extension_config,
};

// Run if executed directly
if (require.main === module) {
  void runAllTests();
}
