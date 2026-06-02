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

test('WEDU network assertion accepts lab DNS through local Acrylic resolver', () => {
  assert.match(harness, /function Get-WeduAcrylicDnsSnapshot/);
  assert.match(harness, /acrylic = Get-WeduAcrylicDnsSnapshot/);

  const assertion = harness.match(
    /function Assert-WeduLabNetwork \{[\s\S]*?\n\}\n\nfunction Invoke-GatewayControl/
  );

  assert.ok(assertion, 'Assert-WeduLabNetwork function exists');
  assert.match(assertion[0], /\$adapterDnsMatches/);
  assert.match(assertion[0], /\$acrylicDnsMatches/);
  assert.match(assertion[0], /\$server -eq '127\.0\.0\.1'/);
  assert.match(
    assertion[0],
    /\$adapterDnsMatches\.Count -eq 0 -and \$acrylicDnsMatches\.Count -eq 0/
  );
});
