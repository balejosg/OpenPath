import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { waitForFirefoxExtensionUuid } from './firefox-extension-uuid';

test('waitForFirefoxExtensionUuid tolerates delayed extension UUID registration', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openpath-firefox-profile-'));
  const prefsPath = path.join(tempDir, 'prefs.js');
  const extensionId = 'openpath-block-monitor@openpath';

  fs.writeFileSync(
    prefsPath,
    'user_pref("extensions.webextensions.uuids", "{\\"other@example.com\\":\\"other-uuid\\"}");\n',
    'utf8'
  );

  setTimeout(() => {
    fs.writeFileSync(
      prefsPath,
      'user_pref("extensions.webextensions.uuids", "{\\"other@example.com\\":\\"other-uuid\\",\\"openpath-block-monitor@openpath\\":\\"expected-uuid\\"}");\n',
      'utf8'
    );
  }, 50);

  const extensionUuid = await waitForFirefoxExtensionUuid({
    profileDir: tempDir,
    extensionId,
    timeoutMs: 500,
    pollMs: 10,
  });

  assert.equal(extensionUuid, 'expected-uuid');
});

test('waitForFirefoxExtensionUuid retries when prefs.js is temporarily malformed', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openpath-firefox-profile-'));
  const prefsPath = path.join(tempDir, 'prefs.js');
  const extensionId = 'openpath-block-monitor@openpath';

  fs.writeFileSync(
    prefsPath,
    'user_pref("extensions.webextensions.uuids", "{\\"openpath-block-monitor@openpath\\":");\n',
    'utf8'
  );

  setTimeout(() => {
    fs.writeFileSync(
      prefsPath,
      'user_pref("extensions.webextensions.uuids", "{\\"openpath-block-monitor@openpath\\":\\"recovered-uuid\\"}");\n',
      'utf8'
    );
  }, 50);

  const extensionUuid = await waitForFirefoxExtensionUuid({
    profileDir: tempDir,
    extensionId,
    timeoutMs: 500,
    pollMs: 10,
  });

  assert.equal(extensionUuid, 'recovered-uuid');
});

test('waitForFirefoxExtensionUuid retries until prefs.js is created', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openpath-firefox-profile-'));
  const prefsPath = path.join(tempDir, 'prefs.js');
  const extensionId = 'openpath-block-monitor@openpath';

  setTimeout(() => {
    fs.writeFileSync(
      prefsPath,
      'user_pref("extensions.webextensions.uuids", "{\\"openpath-block-monitor@openpath\\":\\"created-later-uuid\\"}");\n',
      'utf8'
    );
  }, 50);

  const extensionUuid = await waitForFirefoxExtensionUuid({
    profileDir: tempDir,
    extensionId,
    timeoutMs: 500,
    pollMs: 10,
  });

  assert.equal(extensionUuid, 'created-later-uuid');
});

test('waitForFirefoxExtensionUuid reports profile diagnostics when UUID stays missing', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openpath-firefox-profile-'));
  const prefsPath = path.join(tempDir, 'prefs.js');
  const extensionsJsonPath = path.join(tempDir, 'extensions.json');
  const extensionId = 'openpath-block-monitor@openpath';

  fs.writeFileSync(
    prefsPath,
    'user_pref("extensions.webextensions.uuids", "{\\"other@example.com\\":\\"other-uuid\\"}");\n',
    'utf8'
  );

  fs.writeFileSync(extensionsJsonPath, JSON.stringify({ addons: [{ id: extensionId }] }), 'utf8');

  await assert.rejects(
    () =>
      waitForFirefoxExtensionUuid({
        profileDir: tempDir,
        extensionId,
        timeoutMs: 100,
        pollMs: 10,
      }),
    (error: unknown) => {
      assert.ok(error instanceof Error);
      assert.match(
        error.message,
        /Could not resolve extension UUID for openpath-block-monitor@openpath/
      );
      assert.match(error.message, /prefs\.js=uuids:\[other@example\.com\]/);
      assert.match(error.message, /extensions\.json=addons:\[openpath-block-monitor@openpath\]/);
      assert.match(error.message, /addonStartup\.json\.lz4=missing/);
      return true;
    }
  );
});

test('waitForFirefoxExtensionUuid reports empty prefs.js distinctly when UUID prefs never appear', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openpath-firefox-profile-'));
  const prefsPath = path.join(tempDir, 'prefs.js');
  const extensionId = 'openpath-block-monitor@openpath';

  fs.writeFileSync(prefsPath, '', 'utf8');

  await assert.rejects(
    () =>
      waitForFirefoxExtensionUuid({
        profileDir: tempDir,
        extensionId,
        timeoutMs: 100,
        pollMs: 10,
      }),
    (error: unknown) => {
      assert.ok(error instanceof Error);
      assert.match(error.message, /Could not find extensions\.webextensions\.uuids/);
      assert.match(error.message, /prefs\.js=empty/);
      return true;
    }
  );
});

test('waitForFirefoxExtensionUuid preserves UUID failure when diagnostic files are unreadable', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openpath-firefox-profile-'));
  const prefsPath = path.join(tempDir, 'prefs.js');
  const extensionsJsonPath = path.join(tempDir, 'extensions.json');
  const addonStartupPath = path.join(tempDir, 'addonStartup.json.lz4');
  const extensionId = 'openpath-block-monitor@openpath';

  fs.writeFileSync(
    prefsPath,
    'user_pref("extensions.webextensions.uuids", "{\\"other@example.com\\":\\"other-uuid\\"}");\n',
    'utf8'
  );

  fs.mkdirSync(extensionsJsonPath);
  fs.mkdirSync(addonStartupPath);

  await assert.rejects(
    () =>
      waitForFirefoxExtensionUuid({
        profileDir: tempDir,
        extensionId,
        timeoutMs: 100,
        pollMs: 10,
      }),
    (error: unknown) => {
      assert.ok(error instanceof Error);
      assert.match(
        error.message,
        /Could not resolve extension UUID for openpath-block-monitor@openpath/
      );
      assert.match(error.message, /extensions\.json=unreadable:EISDIR/);
      assert.match(error.message, /addonStartup\.json\.lz4=unreadable:EISDIR/);
      return true;
    }
  );
});
