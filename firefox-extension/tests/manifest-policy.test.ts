import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';

const extensionRoot = path.resolve(import.meta.dirname, '..');

interface FirefoxManifest {
  browser_specific_settings?: {
    gecko?: {
      data_collection_permissions?: {
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
  host_permissions?: string[];
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

  void test('declares Firefox data collection consent and compatible runtimes', async () => {
    const manifest = await readManifest();

    assert.deepEqual(manifest.browser_specific_settings, {
      gecko: {
        id: 'monitor-bloqueos@openpath',
        strict_min_version: '140.0',
        data_collection_permissions: {
          required: ['browsingActivity', 'websiteActivity', 'websiteContent'],
        },
      },
      gecko_android: {
        strict_min_version: '142.0',
      },
    });
  });

  void test('wakes the background runtime at document start on normal web pages', async () => {
    const manifest = await readManifest();

    assert.deepEqual(manifest.content_scripts, [
      {
        matches: ['http://*/*', 'https://*/*'],
        js: ['dist/page-activity-content.js'],
        run_at: 'document_start',
      },
      {
        matches: ['http://*/*', 'https://*/*'],
        js: ['dist/page-resource-observer-main.js'],
        run_at: 'document_start',
        world: 'MAIN',
      },
      {
        matches: ['http://*/*', 'https://*/*'],
        js: ['dist/google-search-game-guard-content.js'],
        run_at: 'document_start',
      },
    ]);
  });
});
