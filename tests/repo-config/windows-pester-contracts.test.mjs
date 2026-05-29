import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readText } from './support.mjs';

function extractPesterContext(testText, contextName) {
  const escapedContextName = contextName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const contextPattern = new RegExp(
    `Context "${escapedContextName}" \\{[\\s\\S]*?(?=\\n    Context "|\\n\\})`
  );
  const match = testText.match(contextPattern);

  assert.ok(match, `Windows.Common.Mocked.Tests.ps1 should define ${contextName}`);
  return match[0];
}

test('checkpoint restore Pester test keeps DNS and firewall helpers module-scoped', () => {
  const commonMockedTests = readText('windows/tests/Windows.Common.Mocked.Tests.ps1');
  const checkpointContext = extractPesterContext(
    commonMockedTests,
    'Restore-OpenPathLatestCheckpoint'
  );

  for (const helperName of [
    'Update-AcrylicHost',
    'Restart-AcrylicService',
    'Get-AcrylicPath',
    'Set-OpenPathFirewall',
    'Set-LocalDNS',
    'Enable-OpenPathFirewall',
  ]) {
    assert.match(
      checkpointContext,
      new RegExp(`Mock ${helperName} \\{[\\s\\S]*?\\} -ModuleName Common`),
      `${helperName} must be mocked inside the Common module so hosted Pester does not mutate DNS/firewall state`
    );
  }

  for (const helperName of [
    'Update-AcrylicHost',
    'Restart-AcrylicService',
    'Get-AcrylicPath',
    'Set-OpenPathFirewall',
    'Set-LocalDNS',
  ]) {
    assert.match(
      checkpointContext,
      new RegExp(`Should -Invoke ${helperName} -ModuleName Common -Times 1 -Exactly`),
      `${helperName} should be asserted through the Common module mock`
    );
  }

  assert.match(
    checkpointContext,
    /Should -Invoke Enable-OpenPathFirewall -ModuleName Common -Times 0 -Exactly/,
    'Enable-OpenPathFirewall fallback should stay mocked and unused in the checkpoint restore test'
  );
});

test('Windows aggregate Pester entrypoint includes installer cleanup regressions', () => {
  const aggregateSuite = readText('windows/tests/Windows.Tests.ps1');
  const cleanupSuite = readText('windows/tests/Windows.Installer.Cleanup.Tests.ps1');

  assert.match(
    aggregateSuite,
    /"Windows\.Installer\.Cleanup\.Tests\.ps1"/,
    'Windows.Tests.ps1 should include installer cleanup contracts for local aggregate runs'
  );
  assert.match(
    cleanupSuite,
    /Ignores AppLocker policies without rule collections/,
    'installer cleanup contracts should cover AppLocker policies that have no RuleCollection nodes'
  );
  assert.match(
    cleanupSuite,
    /Set-AppLockerPolicy should not be called when no OpenPath rules are present/,
    'installer cleanup contracts should prove cleanup skips AppLocker writes when no OpenPath rules exist'
  );
  assert.match(
    cleanupSuite,
    /Ignores a corrupt firewall manifest and still removes OpenPath firewall rules/,
    'installer cleanup contracts should fail CI when corrupt firewall manifests can abort reinstall cleanup'
  );
  assert.match(
    cleanupSuite,
    /Get-OpenPathInstallerFirewallManifestRuleNames/,
    'installer cleanup contracts should keep manifest parsing isolated from cleanup fallback removal'
  );
});

test('Windows AppControl Pester suite keeps Appx AppLocker regression coverage', () => {
  const appControlSuite = readText('windows/tests/Windows.AppControl.Tests.ps1');

  assert.match(
    appControlSuite,
    /Generates Appx FilePublisherRules instead of leaving packaged apps NotConfigured/,
    'Windows.AppControl.Tests.ps1 should keep the Appx AppLocker regression test'
  );

  assert.match(
    appControlSuite,
    /Generates Appx denies for unapproved Edge products[\s\S]*Microsoft\.MicrosoftEdge[\s\S]*Microsoft\.MicrosoftEdge\.Stable/,
    'Windows.AppControl.Tests.ps1 should keep explicit Appx Edge deny coverage'
  );

  assert.match(
    appControlSuite,
    /Does not treat a partial managed AppLocker policy as an active browser boundary[\s\S]*Requires AppIDSvc to be running/,
    'Windows.AppControl.Tests.ps1 should prove active detection validates the full enforced boundary'
  );

  for (const marker of ['Appx', 'FilePublisherRule', 'NotConfigured']) {
    assert.match(
      appControlSuite,
      new RegExp(marker),
      `Windows.AppControl.Tests.ps1 should keep explicit ${marker} coverage for packaged apps`
    );
  }
});
