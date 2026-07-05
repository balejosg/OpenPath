// This test reads and asserts over the source text of the native-messaging
// registration chain: firefox-extension/native/whitelist_native_host.json,
// linux/lib/browser.sh, windows/lib/Browser.FirefoxNativeHost.psm1, and the
// extension sources that declare NATIVE_HOST_NAME. Shared fixture:
// tests/contracts/browser-firefox-native-host.json. Registry: docs/contract-tests.md.
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { readJson, readText } from './support.mjs';

const fixture = readJson('tests/contracts/browser-firefox-native-host.json');

describe('Firefox native-host manifest contract (shared fixture)', () => {
  test('fixture pins the canonical native-host shape', () => {
    assert.equal(fixture.name, 'whitelist_native_host');
    assert.equal(fixture.type, 'stdio');
    assert.equal(fixture.manifestFilename, `${fixture.name}.json`);
    assert.equal(fixture.allowedExtensions.length, 1);
  });

  test('fixture allowed extension matches the canonical gecko id', () => {
    const manifest = readJson('firefox-extension/manifest.json');
    assert.deepEqual(fixture.allowedExtensions, [manifest.browser_specific_settings.gecko.id]);
  });

  test('the shipped manifest template matches the fixture', () => {
    const template = readJson('firefox-extension/native/whitelist_native_host.json');
    assert.equal(template.name, fixture.name);
    assert.equal(template.type, fixture.type);
    assert.deepEqual(template.allowed_extensions, fixture.allowedExtensions);
  });

  test('Linux registration derives host name and filename from one constant', () => {
    const src = readText('linux/lib/browser.sh');
    assert.ok(
      src.includes(
        `OPENPATH_FIREFOX_NATIVE_HOST_NAME="\${OPENPATH_FIREFOX_NATIVE_HOST_NAME:-${fixture.name}}"`
      ),
      'linux/lib/browser.sh must default OPENPATH_FIREFOX_NATIVE_HOST_NAME to the fixture name'
    );
    assert.ok(
      src.includes(
        'OPENPATH_FIREFOX_NATIVE_HOST_FILENAME="${OPENPATH_FIREFOX_NATIVE_HOST_FILENAME:-${OPENPATH_FIREFOX_NATIVE_HOST_NAME}.json}"'
      ),
      'linux/lib/browser.sh must derive the manifest filename from the host name'
    );
  });

  test('Windows registration uses the fixture name, filename, stdio type and dual HKLM views', () => {
    const src = readText('windows/lib/Browser.FirefoxNativeHost.psm1');
    assert.ok(src.includes(`return '${fixture.name}'`), 'Get-OpenPathFirefoxNativeHostName');
    assert.ok(src.includes(`\\${fixture.manifestFilename}`), 'manifest path filename');
    assert.ok(src.includes(`type = '${fixture.type}'`), 'manifest type');
    assert.ok(
      src.includes(`HKLM\\SOFTWARE\\Mozilla\\NativeMessagingHosts\\${fixture.name}`),
      '64-bit registry view'
    );
    assert.ok(
      src.includes(`HKLM\\SOFTWARE\\WOW6432Node\\Mozilla\\NativeMessagingHosts\\${fixture.name}`),
      '32-bit registry view'
    );
  });

  test('every extension source connects to the fixture host name', () => {
    for (const file of [
      'firefox-extension/src/background.ts',
      'firefox-extension/src/blocked-page.ts',
      'firefox-extension/src/lib/background-runtime.ts',
      'firefox-extension/src/lib/config-storage-native.ts',
    ]) {
      assert.ok(
        readText(file).includes(`const NATIVE_HOST_NAME = '${fixture.name}';`),
        `${file} must declare NATIVE_HOST_NAME = '${fixture.name}'`
      );
    }
  });
});
