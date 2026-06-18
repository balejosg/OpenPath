import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  assertStableClientExtensionIdMatches,
  compareDebVersions,
  parseGeckoId,
  parseManagedExtensionId,
  parseStableDebCandidates,
  selectLatestDebCandidate,
} from '../scripts/verify-stable-client-extension-id.mjs';

test('parseManagedExtensionId extracts the env-default id from firefox-policy.sh', () => {
  const policy =
    '#!/bin/bash\n' +
    'FIREFOX_MANAGED_EXTENSION_ID="${FIREFOX_MANAGED_EXTENSION_ID:-openpath-block-monitor@openpath}"\n' +
    'other=1\n';
  assert.equal(parseManagedExtensionId(policy), 'openpath-block-monitor@openpath');
});

test('parseManagedExtensionId reads the legacy id from a pre-rename .deb policy', () => {
  const policy =
    'FIREFOX_MANAGED_EXTENSION_ID="${FIREFOX_MANAGED_EXTENSION_ID:-monitor-bloqueos@openpath}"\n';
  assert.equal(parseManagedExtensionId(policy), 'monitor-bloqueos@openpath');
});

test('parseManagedExtensionId fails closed when the assignment is absent', () => {
  assert.throws(() => parseManagedExtensionId('# no id here\n'), /FIREFOX_MANAGED_EXTENSION_ID/);
});

test('parseGeckoId reads browser_specific_settings.gecko.id', () => {
  const manifest = {
    browser_specific_settings: { gecko: { id: 'openpath-block-monitor@openpath' } },
  };
  assert.equal(parseGeckoId(manifest), 'openpath-block-monitor@openpath');
});

test('parseGeckoId falls back to the legacy applications.gecko.id key', () => {
  const manifest = { applications: { gecko: { id: 'legacy@openpath' } } };
  assert.equal(parseGeckoId(manifest), 'legacy@openpath');
});

test('parseGeckoId fails closed when no gecko id is present', () => {
  assert.throws(() => parseGeckoId({ name: 'x' }), /gecko id/i);
});

test('parseStableDebCandidates extracts only openpath-dnsmasq stanzas', () => {
  const packages =
    'Package: some-other-pkg\nVersion: 9.9.9-1\nFilename: pool/other.deb\n\n' +
    'Package: openpath-dnsmasq\nVersion: 4.1.25-1\nFilename: pool/stable/main/openpath-dnsmasq_4.1.25-1_all.deb\n\n' +
    'Package: openpath-dnsmasq\nVersion: 4.1.26-1\nFilename: pool/stable/main/openpath-dnsmasq_4.1.26-1_all.deb\n';
  const candidates = parseStableDebCandidates(packages);
  assert.deepEqual(
    candidates.map((c) => c.version),
    ['4.1.25-1', '4.1.26-1']
  );
  assert.equal(candidates[1].filename, 'pool/stable/main/openpath-dnsmasq_4.1.26-1_all.deb');
});

test('compareDebVersions orders patch releases and ranks timestamp prereleases below them', () => {
  assert.ok(compareDebVersions('4.1.26-1', '4.1.25-1') > 0);
  assert.ok(compareDebVersions('4.1.25-1', '4.1.26-1') < 0);
  assert.ok(compareDebVersions('4.1.26-1', '0.0.20260617101928-1') > 0);
  assert.equal(compareDebVersions('4.1.26-1', '4.1.26-1'), 0);
});

test('selectLatestDebCandidate picks the highest version a fresh install would receive', () => {
  const latest = selectLatestDebCandidate([
    { version: '4.1.25-1', filename: 'a.deb' },
    { version: '4.1.26-1', filename: 'b.deb' },
  ]);
  assert.equal(latest.version, '4.1.26-1');
  assert.equal(latest.filename, 'b.deb');
});

test('selectLatestDebCandidate fails closed when the stable suite advertises no package', () => {
  assert.throws(() => selectLatestDebCandidate([]), /no.*openpath-dnsmasq/i);
});

test('assertStableClientExtensionIdMatches passes when ids agree', () => {
  assert.doesNotThrow(() =>
    assertStableClientExtensionIdMatches({
      stableExtensionId: 'openpath-block-monitor@openpath',
      manifestExtensionId: 'openpath-block-monitor@openpath',
      stableVersion: '4.1.26-1',
    })
  );
});

test('assertStableClientExtensionIdMatches reproduces the max12 incident: legacy stable id vs renamed manifest id', () => {
  assert.throws(
    () =>
      assertStableClientExtensionIdMatches({
        stableExtensionId: 'monitor-bloqueos@openpath',
        manifestExtensionId: 'openpath-block-monitor@openpath',
        stableVersion: '4.1.25-1',
      }),
    (error) => {
      assert.match(error.message, /monitor-bloqueos@openpath/);
      assert.match(error.message, /openpath-block-monitor@openpath/);
      assert.match(error.message, /4\.1\.25-1/);
      assert.match(error.message, /v\* tag|stable release/i);
      return true;
    }
  );
});
