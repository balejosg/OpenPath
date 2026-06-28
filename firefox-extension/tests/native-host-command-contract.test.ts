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

void test('native host reports DNS policy state independently from CLI discovery', () => {
  const source = readFileSync(
    new URL('../native/openpath-native-host.py', import.meta.url),
    'utf8'
  );

  assert.match(source, /"policy_active": is_dns_policy_active\(\),/);
  assert.doesNotMatch(
    source,
    /"policy_active": is_dns_policy_active\(\) and whitelist_cmd is not None,/
  );
});

void test('native host exposes get-policy-version derived from local whitelist stat', () => {
  const source = readFileSync(
    new URL('../native/openpath-native-host.py', import.meta.url),
    'utf8'
  );

  assert.match(source, /def get_policy_version\(\):/);
  assert.match(source, /elif action == "get-policy-version":\n\s*return get_policy_version\(\)/);
  // sello derivado de mtime_ns + size, sin hashear contenido
  assert.match(source, /st_mtime_ns/);
  assert.match(source, /st_size/);
  assert.doesNotMatch(source, /def get_policy_version\([^)]*\):[\s\S]*?hashlib/);
});
