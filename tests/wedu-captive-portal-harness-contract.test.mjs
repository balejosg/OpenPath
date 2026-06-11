import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const harness = readFileSync('tests/e2e/ci/run-windows-captive-portal-wedu-lab.ps1', 'utf8');

function readSource(path) {
  return readFileSync(path, 'utf8');
}

function sourceBetween(content, startMarker, endMarker) {
  const start = content.indexOf(startMarker);
  assert.notEqual(start, -1, `Expected source marker ${startMarker}`);
  const end = content.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(end, -1, `Expected source marker ${endMarker}`);
  return content.slice(start, end);
}

test('WEDU native recovery relies on declared config, not pre-injected recovery hosts', () => {
  const invocation = harness.match(
    /\$nativeRecovery = Invoke-NativeHostAction -Message @\{[\s\S]*?source = 'wedu-lab-captive'[\s\S]*?\}/
  );

  assert.ok(invocation, 'wedu-lab-captive native recovery invocation exists');
  assert.match(invocation[0], /triggerHost = \$script:WeduHost/);
  // Recovery hosts must come from the declared captivePortalDomains in the runner
  // config (the production path), never from a harness-injected host list.
  assert.doesNotMatch(invocation[0], /portalRecoveryHosts/);
  assert.match(harness, /captivePortalDomains/);
});

test('WEDU lab proves the autonomous post-auth exit before the native reconcile confirmation', () => {
  assert.match(harness, /function Invoke-WeduWatchdogUntilProtectedRestored/);
  // Authentication must remain the browser login (production-faithful); the
  // harness must never flip the gateway through the control endpoint.
  assert.doesNotMatch(harness, /Invoke-GatewayControl[\s\S]*gateway-authenticated/);
  assert.match(harness, /via = 'browser-login'/);

  const exitCallIndex = harness.indexOf(
    '$autonomousExit = Invoke-WeduWatchdogUntilProtectedRestored'
  );
  const reconcileCallIndex = harness.indexOf('$nativeReconcile = Invoke-NativeHostAction');
  assert.ok(exitCallIndex !== -1, 'autonomous exit phase exists');
  assert.ok(reconcileCallIndex !== -1, 'native reconcile confirmation exists');
  assert.ok(
    exitCallIndex < reconcileCallIndex,
    'the watchdog-driven exit must run BEFORE the native reconcile, so the reconcile is confirmation only'
  );

  const successExpression = harness.match(/\$success\s*=\s*\[bool\]\(([\s\S]*?)\n\s*\)/)?.[1] ?? '';
  assert.match(successExpression, /\$autonomousExit\.exitedProtected/);
  assert.match(successExpression, /\$protectedModeExitedVia -eq 'autonomous-watchdog-close'/);
  assert.match(successExpression, /\$postAuthMarkerCleared/);
  assert.match(successExpression, /postAuthPortalHostStillNetworkOnly/);
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

test('captive portal evidence contract keeps discovery diagnostic-only', () => {
  const module = readSource('windows/lib/CaptivePortal.psm1');
  const diagnosticsModule = readSource(
    'windows/lib/internal/CaptivePortal.DiagnosticsDiscovery.ps1'
  );
  const nativeHostActions = readSource('windows/lib/internal/NativeHost.Actions.ps1');
  const limitedModeBody = sourceBetween(
    module,
    'function Enable-OpenPathCaptivePortalLimitedMode',
    'function New-OpenPathLimitedCaptivePortalHostsDefinition'
  );
  const limitedModeReadyExpression =
    limitedModeBody.match(/\$limitedModeReady\s*=\s*([^\n]+)/)?.[1] ?? '';
  const recentSuccessBody = sourceBetween(
    nativeHostActions,
    'function Test-NativeHostRecentCaptivePortalSuccessEligible',
    'function Test-NativeHostBlockedSubdomainMatch'
  );
  const successExpression = harness.match(/\$success\s*=\s*\[bool\]\(([\s\S]*?)\n\s*\)/)?.[1] ?? '';
  const exportBody = sourceBetween(module, 'Export-ModuleMember -Function @(', ')');

  assert.match(
    module,
    /\. \(Join-Path \$PSScriptRoot 'internal\\CaptivePortal\.DiagnosticsDiscovery\.ps1'\)/
  );
  assert.doesNotMatch(
    module,
    /^function Get-OpenPathCaptivePortalDynamicHosts\b/m,
    'diagnostics discovery implementation should live in the internal module'
  );
  assert.match(diagnosticsModule, /^function Get-OpenPathCaptivePortalDynamicHosts\b/m);
  assert.match(diagnosticsModule, /^function Get-OpenPathCaptivePortalEvidenceContract\b/m);
  assert.match(exportBody, /'Get-OpenPathCaptivePortalDynamicHosts'/);
  assert.doesNotMatch(exportBody, /Get-OpenPathCaptivePortalEvidenceContract/);

  for (const category of ['productGate', 'postAuthGate', 'diagnosticOnly', 'compatibility']) {
    assert.match(diagnosticsModule, new RegExp(`${category}\\s*=`));
  }

  for (const field of [
    'observedRuntimeHosts',
    'pendingRuntimeHosts',
    'discoveryTruncated',
    'redirectHosts',
    'resourceHosts',
  ]) {
    assert.match(
      diagnosticsModule,
      new RegExp(`diagnosticOnly[\\s\\S]*'${field}'`),
      `${field} must be documented as diagnostic-only`
    );
    assert.doesNotMatch(
      limitedModeReadyExpression,
      new RegExp(field),
      `${field} must not decide limited-mode readiness`
    );
    assert.doesNotMatch(
      successExpression,
      new RegExp(field, 'i'),
      `${field} must not decide WEDU lab success`
    );
    assert.doesNotMatch(
      recentSuccessBody,
      new RegExp(field, 'i'),
      `${field} must not decide RecentSuccess`
    );
    assert.match(harness, new RegExp(`${field}\\s*=`), `${field} must remain diagnostic output`);
  }

  assert.doesNotMatch(limitedModeBody, /Get-OpenPathCaptivePortalDynamicHosts/);
  assert.equal(
    limitedModeReadyExpression,
    '($declaredRecoveryHostsApplied -and $configuredCaptivePortalDomainsApplied)'
  );
});
