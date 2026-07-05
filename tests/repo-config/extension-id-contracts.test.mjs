// This test reads and asserts over the source text of every file that
// hard-codes the Firefox extension id. Canonical source:
// firefox-extension/manifest.json (browser_specific_settings.gecko.id).
// Before renaming the id or adding a new hard-coded occurrence, update
// EXTENSION_ID_SITES here and the registry entry in docs/contract-tests.md.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { describe, test } from 'node:test';
import { projectRoot, readJson, readText } from './support.mjs';

const CANONICAL_ID =
  readJson('firefox-extension/manifest.json').browser_specific_settings?.gecko?.id ?? '';

// Definition sites: every non-test, non-doc file that hard-codes the id, with
// the exact source context that must embed it. A rename must touch all of these.
const EXTENSION_ID_SITES = [
  {
    file: 'firefox-extension/native/whitelist_native_host.json',
    contexts: (id) => [`"allowed_extensions": ["${id}"]`],
  },
  {
    file: 'windows/lib/Browser.FirefoxNativeHost.psm1',
    contexts: (id) => [`allowed_extensions = @('${id}')`],
  },
  {
    file: 'windows/lib/Browser.FirefoxPolicy.psm1',
    contexts: (id) => [`return '${id}'`],
  },
  {
    file: 'linux/lib/firefox-policy.sh',
    contexts: (id) => [`FIREFOX_MANAGED_EXTENSION_ID="\${FIREFOX_MANAGED_EXTENSION_ID:-${id}}"`],
  },
  {
    file: 'linux/lib/browser-request-readiness.sh',
    contexts: (id) => [
      `FIREFOX_EXTENSION_ID="\${FIREFOX_EXTENSION_ID:-\${FIREFOX_MANAGED_EXTENSION_ID:-${id}}}"`,
    ],
  },
  {
    file: 'linux/lib/runtime-cli-system.sh',
    contexts: (id) => [
      `extension_id=${id}`,
      `\${FIREFOX_EXTENSION_ID:-\${FIREFOX_MANAGED_EXTENSION_ID:-${id}}}`,
    ],
  },
  {
    file: 'linux/lib/common-config-persistence.sh',
    contexts: (id) => [`grep -q "${id}"`],
  },
  {
    file: 'linux/scripts/runtime/openpath-browser-setup.sh',
    contexts: (id) => [`FIREFOX_EXTENSION_ID="\${OPENPATH_FIREFOX_EXTENSION_ID:-${id}}"`],
  },
  { file: 'linux/uninstall.sh', contexts: (id) => [id] },
  { file: 'linux/debian-package/DEBIAN/postrm', contexts: (id) => [id] },
  {
    file: 'firefox-extension/verify-firefox-amo-version.mjs',
    contexts: (id) => [`const defaultAddonId = '${id}';`],
  },
  {
    file: 'firefox-extension/upload-firefox-amo-source.mjs',
    contexts: (id) => [`const defaultAddonId = '${id}';`],
  },
  {
    file: 'firefox-extension/sync-firefox-amo-policy.mjs',
    contexts: (id) => [`const defaultAddonId = '${id}';`],
  },
  {
    file: 'tests/contracts/browser-firefox-managed-extension.json',
    contexts: (id) => [`"extensionId": "${id}"`],
  },
];

// Tracked files that may mention the id without being definition sites:
// tests assert it, docs document it, and the stable-client checker's header
// comment records the 2026-05-10 rename incident.
const ALLOWED_MENTION_PREFIXES = [
  'tests/',
  'windows/tests/',
  'api/tests/',
  'firefox-extension/tests/',
  'docs/',
];
const ALLOWED_MENTION_FILES = [
  'firefox-extension/AGENTS.md',
  'firefox-extension/README.md',
  'firefox-extension/AMO.md',
  'scripts/verify-stable-client-extension-id.mjs',
];

describe('extension id contract: one canonical source', () => {
  test('manifest gecko id is non-empty and matches the pinned contract fixture', () => {
    assert.notEqual(CANONICAL_ID, '', 'firefox-extension/manifest.json must declare a gecko id');
    const fixture = readJson('tests/contracts/browser-firefox-managed-extension.json');
    assert.equal(
      fixture.extensionId,
      CANONICAL_ID,
      'tests/contracts/browser-firefox-managed-extension.json extensionId must match the manifest gecko id'
    );
  });

  for (const site of EXTENSION_ID_SITES) {
    test(`${site.file} embeds the canonical extension id in its expected context`, () => {
      const source = readText(site.file);
      for (const context of site.contexts(CANONICAL_ID)) {
        assert.ok(
          source.includes(context),
          `${site.file} must contain: ${context}\n` +
            'If the extension id was renamed, update this occurrence; if this context was ' +
            'refactored, update EXTENSION_ID_SITES in tests/repo-config/extension-id-contracts.test.mjs.'
        );
      }
    });
  }

  test('the extension id appears only at inventoried sites, tests, and docs', () => {
    const trackedMatches = execFileSync('git', ['grep', '-l', '-F', CANONICAL_ID], {
      cwd: projectRoot,
      encoding: 'utf8',
    })
      .split('\n')
      .filter(Boolean);

    const knownFiles = new Set([
      'firefox-extension/manifest.json',
      ...EXTENSION_ID_SITES.map((site) => site.file),
      ...ALLOWED_MENTION_FILES,
    ]);

    const unexpected = trackedMatches.filter(
      (file) =>
        !knownFiles.has(file) && !ALLOWED_MENTION_PREFIXES.some((prefix) => file.startsWith(prefix))
    );

    assert.deepEqual(
      unexpected,
      [],
      `New hard-coded extension-id occurrence(s): ${unexpected.join(', ')}. ` +
        'Derive the id from firefox-extension/manifest.json (or the owning platform env-default ' +
        'seam) instead of adding another literal. If a new literal is genuinely required, add it ' +
        'to EXTENSION_ID_SITES here and to docs/contract-tests.md.'
    );
  });
});
