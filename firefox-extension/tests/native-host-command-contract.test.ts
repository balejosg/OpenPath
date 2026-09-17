import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

void test('native host probes the installed OpenPath CLI before legacy whitelist command', () => {
  const source = readFileSync(
    new URL('../native/openpath-native-host.py', import.meta.url),
    'utf8'
  );

  const openpathIndex = source.indexOf('"/usr/local/bin/openpath"');
  const legacyIndex = source.indexOf('"/usr/local/bin/whitelist"');

  assert.notEqual(openpathIndex, -1);
  assert.notEqual(legacyIndex, -1);
  assert.ok(openpathIndex < legacyIndex);
  assert.doesNotMatch(source, /^WHITELIST_CMD = "\/usr\/local\/bin\/whitelist"$/m);
});

void test('native host reports an explicit policy verdict independently from DNS', () => {
  const source = readFileSync(
    new URL('../native/openpath-native-host.py', import.meta.url),
    'utf8'
  );

  assert.match(source, /"policy_decision": "unknown",/);
  assert.match(source, /policy_decision="blocked", policy_reason="default-deny"/);
});

void test('native host exposes get-policy-version from the same policy snapshot', () => {
  const source = readFileSync(
    new URL('../native/openpath-native-host.py', import.meta.url),
    'utf8'
  );

  assert.match(source, /def get_policy_version\(\):/);
  assert.match(source, /elif action == "get-policy-version":\n\s*return get_policy_version\(\)/);
  assert.match(source, /snapshot = read_policy_snapshot\(\)/);
  assert.match(source, /hashlib\.sha256\(version_material\)\.hexdigest\(\)/);
});
