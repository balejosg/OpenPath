import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const script = readFileSync(
  resolve(repoRoot, 'windows/scripts/Collect-WeduCaptivePortalDiagnostics.ps1'),
  'utf8'
);

test('WEDU diagnostics captures missing scheduled tasks without noisy errors', () => {
  assert.match(script, /function Get-OpenPathScheduledTaskInfoSnapshot/);
  assert.match(script, /Get-ScheduledTask -TaskName \$TaskName -ErrorAction SilentlyContinue/);
  assert.match(script, /found = \$false/);
  assert.match(
    script,
    /recoveryTask = Get-OpenPathScheduledTaskInfoSnapshot -TaskName 'OpenPath-CaptivePortalRecovery'/
  );
  assert.match(
    script,
    /dnsHealthTask = Get-OpenPathScheduledTaskInfoSnapshot -TaskName 'OpenPath-DNSHealth'/
  );
  assert.doesNotMatch(script, /Invoke-OpenPathDiagnosticCapture \{ Get-ScheduledTask -TaskName/);
});

test('WEDU diagnostics has a quick mode and visible progress for affected machines', () => {
  assert.match(script, /\[switch\]\$Quick/);
  assert.match(script, /function Write-OpenPathDiagnosticStep/);
  assert.match(script, /Write-OpenPathDiagnosticStep -Message 'Capturing OpenPath state'/);
  assert.match(script, /Write-OpenPathDiagnosticStep -Message 'Capturing DNS probes'/);
  assert.match(script, /if \(\$Quick\) \{/);
  assert.match(script, /skipped = \$true/);
  assert.match(script, /reason = 'quick-mode'/);
});

test('WEDU diagnostics avoids unbounded DNS helper commands by default', () => {
  assert.match(script, /function Invoke-OpenPathDnsProbe/);
  assert.match(script, /Resolve-DnsName @resolveArgs/);
  assert.match(script, /QuickTimeout/);
  assert.doesNotMatch(script, /nslookup \$PortalHost/);
});
