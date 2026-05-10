import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';

const extensionRoot = path.resolve(import.meta.dirname, '..');

interface FirefoxManifest {
  browser_specific_settings?: {
    gecko?: {
      data_collection_permissions?: {
        optional?: string[];
        required?: string[];
      };
      id?: string;
      strict_min_version?: string;
    };
    gecko_android?: {
      strict_min_version?: string;
    };
  };
  name?: string;
  description?: string;
  content_security_policy?: {
    extension_pages?: string;
  };
  content_scripts?: {
    js?: string[];
    matches?: string[];
    run_at?: string;
    world?: string;
  }[];
  permissions?: string[];
  host_permissions?: string[];
  action?: {
    default_popup?: string;
    default_title?: string;
  };
}

async function readManifest(): Promise<FirefoxManifest> {
  return JSON.parse(
    await readFile(path.join(extensionRoot, 'manifest.json'), 'utf8')
  ) as FirefoxManifest;
}

void describe('Firefox extension manifest policy', () => {
  void test('keeps store-facing metadata concise and OpenPath-specific', async () => {
    const manifest = await readManifest();
    const description = manifest.description ?? '';

    assert.match(manifest.name ?? '', /Monitor de Bloqueos/);
    assert.match(description, /OpenPath/);
    assert.ok(
      description.length <= 132,
      `manifest description should stay short for browser and store UIs, got ${String(description.length)} characters`
    );
  });

  void test('does not upgrade configured HTTP request API endpoints to HTTPS', async () => {
    const manifest = await readManifest();
    const extensionPolicy = manifest.content_security_policy?.extension_pages ?? '';

    assert.match(extensionPolicy, /script-src 'self'/);
    assert.doesNotMatch(extensionPolicy, /upgrade-insecure-requests/);
  });

  void test('keeps network host permissions broad enough for configured tenant APIs', async () => {
    const manifest = await readManifest();

    assert.deepEqual(manifest.host_permissions, ['<all_urls>']);
  });

  void test('keeps manifest permissions documented in AMO and privacy notes', async () => {
    const manifest = await readManifest();
    const privacy = await readFile(path.join(extensionRoot, 'PRIVACY.md'), 'utf8');
    const amo = await readFile(path.join(extensionRoot, 'AMO.md'), 'utf8');
    const documentedPermissions = [
      ...(manifest.permissions ?? []),
      ...(manifest.host_permissions ?? []),
    ];

    for (const permission of documentedPermissions) {
      const escapedPermission = permission.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const documentedPermission = new RegExp(`\`${escapedPermission}\``);

      assert.match(privacy, documentedPermission, `PRIVACY.md should document ${permission}`);
      assert.match(amo, documentedPermission, `AMO.md should document ${permission}`);
    }
  });

  void test('keeps classic Firefox permissions required by the desktop extension', async () => {
    const manifest = await readManifest();

    assert.deepEqual(manifest.permissions, [
      'webRequest',
      'webRequestBlocking',
      'webNavigation',
      'tabs',
      'clipboardWrite',
      'nativeMessaging',
      'storage',
    ]);
  });

  void test('declares Firefox desktop data collection consent and runtime', async () => {
    const manifest = await readManifest();

    assert.deepEqual(manifest.browser_specific_settings, {
      gecko: {
        id: 'openpath-block-monitor@openpath',
        strict_min_version: '140.0',
        data_collection_permissions: {
          required: ['none'],
          optional: ['browsingActivity'],
        },
      },
      gecko_android: {
        strict_min_version: '142.0',
      },
    });
  });

  void test('does not declare content scripts in the desktop-only Firefox manifest', async () => {
    const manifest = await readManifest();

    assert.equal(manifest.content_scripts, undefined);
  });

  void test('keeps popup action in Firefox Core', async () => {
    const manifest = await readManifest();
    const action = manifest.action;
    assert.ok(action);

    assert.equal(action.default_popup, 'popup/popup.html');
    assert.equal(action.default_title, 'Monitor de Bloqueos');
  });
});
