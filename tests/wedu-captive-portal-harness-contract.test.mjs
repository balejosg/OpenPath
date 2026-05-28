import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const harness = readFileSync('tests/e2e/ci/run-windows-captive-portal-wedu-lab.ps1', 'utf8');

test('WEDU native recovery uses triggerHost without preinjected portalRecoveryHosts', () => {
  const invocation = harness.match(
    /\$nativeRecovery = Invoke-NativeHostAction -Message @\{[\s\S]*?source = 'wedu-lab-captive'[\s\S]*?\}/
  );

  assert.ok(invocation, 'wedu-lab-captive native recovery invocation exists');
  assert.match(invocation[0], /triggerHost = \$script:WeduHost/);
  assert.doesNotMatch(invocation[0], /portalRecoveryHosts\s*=/);
});
