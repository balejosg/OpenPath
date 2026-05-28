import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import process from 'node:process';
import { describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  extractUsableGuestIPv4,
  getWindowsDirectArtifactSpecsForModes,
  parseRunnerRepoRootCandidates,
  selectPreferredRunnerRepoRoot,
} from '../scripts/run-windows-runner-direct.mjs';
import { resolveWindowsDirectDiagnosticMode } from '../scripts/lib/windows-direct-diagnostic-modes.mjs';
import { readPackageJson, readText } from './repo-config/support.mjs';

const currentFilePath = fileURLToPath(import.meta.url);
const projectRoot = resolve(dirname(currentFilePath), '..');
const scriptPath = resolve(projectRoot, 'scripts/run-windows-runner-direct.mjs');

function runDirectDiagnostic(args) {
  return spawnSync(process.execPath, [scriptPath, ...args], {
    cwd: projectRoot,
    encoding: 'utf8',
    env: {
      ...process.env,
      OPENPATH_WINDOWS_DIRECT_DRY_RUN: '1',
    },
  });
}

function runWorkspaceWrapper(args) {
  const workspaceRoot = process.env.WHITELIST_WORKSPACE_ROOT
    ? resolve(process.env.WHITELIST_WORKSPACE_ROOT)
    : resolve(projectRoot, '..');
  const wrapperPath = resolve(workspaceRoot, 'scripts', 'validate-hypothesis.sh');
  return spawnSync('bash', [wrapperPath, ...args], {
    cwd: workspaceRoot,
    encoding: 'utf8',
  });
}

function extractDryRunCommand(stdout) {
  const commandLine = stdout.split(/\r?\n/).find((line) => line.startsWith('Command: '));

  assert.ok(commandLine, `Expected dry-run Command line in output:\n${stdout}`);
  return commandLine.slice('Command: '.length).trim().split(/\s+/);
}

function assertWindowsDirectCommand(result, expectedOptions = []) {
  assert.equal(result.status, 0, result.stderr);

  const tokens = extractDryRunCommand(result.stdout);
  assert.deepEqual(tokens.slice(0, 5), [
    'npm',
    'run',
    'diagnostics:windows:direct',
    '--',
    '--source-mode',
  ]);

  for (const expectedOption of expectedOptions) {
    const optionIndex = tokens.indexOf(expectedOption.name);
    assert.notEqual(optionIndex, -1, `Expected ${expectedOption.name} in ${tokens.join(' ')}`);
    assert.equal(tokens[optionIndex + 1], expectedOption.value);
  }

  return tokens;
}

describe('direct OpenPath Windows runner diagnostic', () => {
  test('resolver exposes direct Windows diagnostic mode metadata', () => {
    const expectations = [
      {
        mode: 'browser-boundary',
        artifactRoot:
          'C:\\actions-runner*\\_work\\Openpath\\Openpath\\tests\\e2e\\artifacts\\windows-student-policy',
        completionFileName: 'direct-browser-boundary-completion.json',
        runnerScriptPath: 'tests\\e2e\\ci\\run-windows-browser-boundary-ci.ps1',
      },
      {
        mode: 'dns-discovery-spike',
        artifactRoot: 'C:\\Windows\\Temp\\openpath-dns-discovery-spike',
        completionFileName: 'direct-dns-discovery-spike-completion.json',
        runnerScriptPath: 'tests\\e2e\\ci\\run-windows-dns-discovery-spike.ps1',
      },
      {
        mode: 'dns-evidence-matrix',
        artifactRoot: 'C:\\Windows\\Temp\\openpath-dns-evidence-matrix',
        completionFileName: 'direct-dns-evidence-matrix-completion.json',
        runnerScriptPath: 'tests\\e2e\\ci\\run-windows-dns-evidence-matrix.ps1',
      },
      {
        mode: 'dns-evidence-matrix-v2',
        artifactRoot: 'C:\\Windows\\Temp\\openpath-dns-evidence-matrix-v2',
        completionFileName: 'direct-dns-evidence-matrix-v2-completion.json',
        runnerScriptPath: 'tests\\e2e\\ci\\run-windows-dns-evidence-matrix-v2.ps1',
      },
      {
        mode: 'dns-observability-controls',
        artifactRoot: 'C:\\Windows\\Temp\\openpath-dns-observability-controls',
        completionFileName: 'direct-dns-observability-controls-completion.json',
        runnerScriptPath: 'tests\\e2e\\ci\\run-windows-dns-observability-controls.ps1',
      },
      {
        mode: 'acrylic-purgecache-spike',
        artifactRoot: 'C:\\Windows\\Temp\\openpath-acrylic-purgecache-spike',
        completionFileName: 'direct-acrylic-purgecache-spike-completion.json',
        runnerScriptPath: 'tests\\e2e\\ci\\run-windows-acrylic-purgecache-spike.ps1',
      },
      {
        mode: 'browser-dependency-observability-spike',
        artifactRoot: 'C:\\Windows\\Temp\\openpath-browser-dependency-observability-spike',
        completionFileName: 'direct-browser-dependency-observability-spike-completion.json',
        runnerScriptPath: 'tests\\e2e\\ci\\run-windows-browser-dependency-observability-spike.ps1',
      },
      {
        mode: 'captive-portal-navigation',
        artifactRoot: 'C:\\Windows\\Temp\\openpath-captive-portal-navigation',
        completionFileName: 'direct-captive-portal-navigation-completion.json',
        runnerScriptPath: 'tests\\e2e\\ci\\run-windows-captive-portal-navigation.ps1',
      },
      {
        mode: 'captive-portal-wedu-lab',
        artifactRoot: 'C:\\Windows\\Temp\\openpath-captive-portal-wedu-lab',
        completionFileName: 'direct-captive-portal-wedu-lab-completion.json',
        runnerScriptPath: 'tests\\e2e\\ci\\run-windows-captive-portal-wedu-lab.ps1',
        skipPreRunReset: true,
        includeInAll: false,
        allowLocalOverlay: false,
      },
    ];

    for (const expectation of expectations) {
      assert.deepEqual(resolveWindowsDirectDiagnosticMode(expectation.mode), {
        ...expectation,
        requiresSharedPowerShellPreamble: true,
      });
    }
  });

  test('CLI usage still advertises the supported direct diagnostic modes', () => {
    const result = runDirectDiagnostic(['--help']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(
      result.stderr,
      /pester, browser-boundary, dns-discovery-spike, dns-evidence-matrix, dns-evidence-matrix-v2, dns-observability-controls, acrylic-purgecache-spike, browser-dependency-observability-spike, captive-portal-navigation, captive-portal-wedu-lab, or all/
    );
  });

  test('package.json exposes the direct Windows diagnostic entrypoint', () => {
    const packageJson = readPackageJson();

    assert.equal(
      packageJson.scripts['diagnostics:windows:direct'],
      'node scripts/run-windows-runner-direct.mjs'
    );
  });

  test('plans a direct Proxmox guest-agent diagnostic for the Windows runner VM', () => {
    const result = runDirectDiagnostic([]);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /artifact_dir=/);
    assert.match(result.stdout, /source_mode=runner-checkout/);
    assert.match(result.stdout, /mode=pester/);
    assert.match(result.stdout, /runner_repo_root=<auto-detect-on-runner>/);
    assert.match(result.stdout, /ssh whitelist-proxmox qm guest exec 103 -- powershell\.exe/);
    assert.match(result.stdout, /direct OpenPath Windows runner diagnostic complete/);
  });

  test('plans direct diagnostics with an explicit Proxmox SSH identity', () => {
    const result = runDirectDiagnostic([
      '--proxmox-host',
      'proxmox.example',
      '--ssh-key-path',
      '/tmp/openpath-wedu-ci',
    ]);

    assert.equal(result.status, 0, result.stderr);
    assert.match(
      result.stdout,
      /ssh -i \/tmp\/openpath-wedu-ci -o IdentitiesOnly=yes proxmox\.example qm guest exec 103 -- powershell\.exe/
    );
  });

  test('plans a local overlay source without starting the overlay server in dry-run', () => {
    const result = runDirectDiagnostic(['--source-mode', 'local-overlay']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=local-overlay/);
    assert.match(result.stdout, /overlay_host=<auto-detect-from-guest-route>/);
    assert.match(
      result.stdout,
      /git archive --format=zip --output .*openpath-local-overlay\.zip HEAD/
    );
    assert.match(
      result.stdout,
      /Invoke-WebRequest -Uri http:\/\/<overlay-host>:<port>\/openpath-local-overlay\.zip/
    );
    assert.match(
      result.stdout,
      /Expand-Archive -LiteralPath <temp-zip> -DestinationPath %TEMP%\\openpath-direct-overlay-<guid> -Force/
    );
  });

  test('allows overriding the Windows runner repo root explicitly', () => {
    const result = runDirectDiagnostic(['--runner-repo-root', 'C:\\runner\\OpenPath']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /runner_repo_root=C:\\runner\\OpenPath/);
  });

  test('prefers the openpath-specific runner root over the legacy checkout', () => {
    const repoRoot = selectPreferredRunnerRepoRoot([
      'C:\\actions-runner\\_work\\Openpath\\Openpath',
      'C:\\actions-runner-openpath\\_work\\Openpath\\Openpath',
    ]);

    assert.equal(repoRoot, 'C:\\actions-runner-openpath\\_work\\Openpath\\Openpath');
  });

  test('falls back to the legacy runner root when it is the only candidate', () => {
    const repoRoot = selectPreferredRunnerRepoRoot([
      'C:\\actions-runner\\_work\\Openpath\\Openpath',
    ]);

    assert.equal(repoRoot, 'C:\\actions-runner\\_work\\Openpath\\Openpath');
  });

  test('parses singleton and array JSON candidate payloads from the runner', () => {
    assert.deepEqual(
      parseRunnerRepoRootCandidates(
        '"C:\\\\actions-runner-openpath\\\\_work\\\\Openpath\\\\Openpath"'
      ),
      ['C:\\actions-runner-openpath\\_work\\Openpath\\Openpath']
    );
    assert.deepEqual(
      parseRunnerRepoRootCandidates(
        '["C:\\\\actions-runner\\\\_work\\\\Openpath\\\\Openpath","C:\\\\actions-runner-openpath\\\\_work\\\\Openpath\\\\Openpath"]'
      ),
      [
        'C:\\actions-runner\\_work\\Openpath\\Openpath',
        'C:\\actions-runner-openpath\\_work\\Openpath\\Openpath',
      ]
    );
  });

  test('extracts the first usable IPv4 address from Proxmox guest network output', () => {
    const output = JSON.stringify([
      {
        name: 'Loopback Pseudo-Interface 1',
        'ip-addresses': [
          {
            'ip-address-type': 'ipv4',
            'ip-address': '127.0.0.1',
          },
        ],
      },
      {
        name: 'Ethernet',
        'ip-addresses': [
          {
            'ip-address-type': 'ipv6',
            'ip-address': 'fe80::1234',
          },
          {
            'ip-address-type': 'ipv4',
            'ip-address': '192.168.1.103',
          },
        ],
      },
    ]);

    assert.equal(extractUsableGuestIPv4(output), '192.168.1.103');
  });

  test('ignores link-local IPv4 addresses from guest network output', () => {
    const output = JSON.stringify([
      {
        name: 'Ethernet',
        'ip-addresses': [
          {
            'ip-address-type': 'ipv4',
            'ip-address': '169.254.10.20',
          },
        ],
      },
    ]);

    assert.equal(extractUsableGuestIPv4(output), '');
  });

  test('fails clearly when runner autodetection returns no candidate roots', () => {
    assert.throws(
      () => selectPreferredRunnerRepoRoot([]),
      /Unable to auto-detect the OpenPath checkout root/
    );
  });

  test('direct diagnostic resets the runner before invoking isolated Pester', () => {
    const script = readText('scripts/run-windows-runner-direct.mjs');

    assert.match(script, /OPENPATH_WINDOWS_DIRECT_RUNNER_REPO_ROOT/);
    assert.match(script, /OPENPATH_WINDOWS_DIRECT_SOURCE_MODE/);
    assert.match(script, /OPENPATH_WINDOWS_DIRECT_OVERLAY_HOST/);
    assert.match(script, /actions-runner\*/);
    assert.match(script, /selectPreferredRunnerRepoRoot/);
    assert.match(script, /git', 'archive', '--format=zip'/);
    assert.match(script, /Invoke-WebRequest/);
    assert.match(script, /Expand-Archive/);
    assert.match(script, /openpath-direct-overlay-/);
    assert.match(script, /reset-self-hosted-windows-runner\.ps1/);
    assert.match(script, /run-windows-pester-isolated\.ps1/);
    assert.match(script, /windows-test-results\.xml/);
    assert.match(script, /qm guest exec/);
  });

  test('browser enforcement report option invokes the Phase 5 report and collects artifacts', () => {
    const result = runDirectDiagnostic(['--browser-enforcement-report']);
    const script = readText('scripts/run-windows-runner-direct.mjs');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /browser_enforcement_report=enabled/);
    assert.match(script, /windows-browser-enforcement\.ps1/);
    assert.match(script, /-Scope Report/);
    assert.match(script, /windows-browser-enforcement-report\.json/);
    assert.match(script, /windows-browser-enforcement-report\.txt/);
  });

  test('browser-boundary mode plans the student flow and boundary CI script', () => {
    const result = runDirectDiagnostic([
      '--mode',
      'browser-boundary',
      '--source-mode',
      'local-overlay',
    ]);
    const script = readText('scripts/run-windows-runner-direct.mjs');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=local-overlay/);
    assert.match(result.stdout, /mode=browser-boundary/);
    assert.match(script, /OPENPATH_WINDOWS_DIRECT_MODE/);
    assert.match(script, /Ensure-OpenPathDirectNode/);
    assert.match(script, /Ensure-OpenPathDirectDependencies/);
    assert.match(script, /node_modules\\\\\.bin\\\\tsc\.cmd/);
    assert.match(script, /npm\.cmd ci --prefer-offline --no-audit --fund=false/);
    assert.match(script, /https:\/\/nodejs\.org\/dist\/index\.json/);
    assert.match(script, /OPENPATH_WINDOWS_STUDENT_SSE_GROUP = 'path-blocking'/);
    assert.match(script, /OPENPATH_KEEP_CLIENT_FOR_BROWSER_BOUNDARY = '1'/);
    assert.match(script, /run-windows-browser-boundary-ci\.ps1/);
    assert.match(script, /browser-boundary-summary\.json/);
  });

  test('dns-discovery-spike mode runs the local-overlay spike and collects artifacts', () => {
    const result = runDirectDiagnostic([
      '--mode',
      'dns-discovery-spike',
      '--source-mode',
      'local-overlay',
    ]);
    const script = readText('scripts/run-windows-runner-direct.mjs');
    const spikeScript = readText('tests/e2e/ci/run-windows-dns-discovery-spike.ps1');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=local-overlay/);
    assert.match(result.stdout, /mode=dns-discovery-spike/);
    assert.match(result.stdout, /step=run-windows-dns-discovery-spike/);
    assert.match(script, /run-windows-dns-discovery-spike\.ps1/);
    assert.match(script, /windows-dns-discovery-spike/);
    assert.match(script, /dns-discovery-spike-result\.json/);
    assert.match(script, /acrylic-dns-discovery-spike\.log/);
    assert.match(spikeScript, /AcrylicConfiguration\.ini/);
    assert.match(spikeScript, /C:\\OpenPath\\data\\logs\\acrylic-dns-discovery-spike\.log/);
    assert.match(spikeScript, /HitLogFileWhat=XHCFRU/);
    assert.match(spikeScript, /HitLogMaxPendingHits=512/);
    assert.match(spikeScript, /FileShare\]::ReadWrite/);
    assert.match(spikeScript, /cold-origin/);
    assert.match(spikeScript, /warm-approved-origin/);
    assert.match(spikeScript, /dnsOnlyViable/);
    assert.match(spikeScript, /fallbackRequired/);
    assert.match(spikeScript, /insufficientEvidence/);
  });

  test('dns-evidence-matrix mode runs the matrix harness and collects DNS artifacts', () => {
    const result = runDirectDiagnostic([
      '--mode',
      'dns-evidence-matrix',
      '--source-mode',
      'local-overlay',
    ]);
    const script = readText('scripts/run-windows-runner-direct.mjs');
    const matrixScript = readText('tests/e2e/ci/run-windows-dns-evidence-matrix.ps1');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=local-overlay/);
    assert.match(result.stdout, /mode=dns-evidence-matrix/);
    assert.match(result.stdout, /step=run-windows-dns-evidence-matrix/);
    assert.equal(
      resolveWindowsDirectDiagnosticMode('dns-evidence-matrix').artifactRoot,
      'C:\\Windows\\Temp\\openpath-dns-evidence-matrix'
    );
    assert.match(script, /run-windows-dns-evidence-matrix\.ps1/);
    assert.match(script, /dns-evidence-matrix-result\.json/);
    assert.match(script, /dns-evidence-matrix-browser-artifact\.json/);
    assert.match(script, /pktmon/);
    assert.match(script, /dns-evidence-matrix-packet-events\.json/);
    assert.match(matrixScript, /AcrylicConfiguration\.ini/);
    assert.match(matrixScript, /AcrylicHosts\.txt/);
    assert.match(matrixScript, /HitLogFileWhat=XHCFRU/);
    assert.match(matrixScript, /HitLogMaxPendingHits=1/);
    assert.match(matrixScript, /HitLogFullDump=No/);
    assert.match(matrixScript, /pktmon filter add OpenPathDnsEvidenceMatrix -p 53/);
    assert.match(matrixScript, /pktmon start --capture --pkt-size 0 --file-name/);
    assert.match(matrixScript, /pktmon etl2txt/);
    assert.match(matrixScript, /pktmon etl2pcap/);
    for (const phase of [
      'direct-dns-calibration',
      'direct-dns-cache-warm',
      'browser-cold-navigation',
      'browser-warm-ajax',
      'browser-multi-anchor',
      'sinkhole-capture',
    ]) {
      assert.match(matrixScript, new RegExp(phase));
    }
    for (const decision of [
      'dnsOnlyViable',
      'fallbackRequired',
      'hitLogUnusable',
      'sinkholeDiagnosticOnly',
      'insufficientEvidence',
    ]) {
      assert.match(matrixScript, new RegExp(decision));
    }
  });

  test('dns-evidence-matrix-v2 mode runs the controlled DNS evidence harness', () => {
    const result = runDirectDiagnostic([
      '--mode',
      'dns-evidence-matrix-v2',
      '--source-mode',
      'local-overlay',
    ]);
    const script = readText('scripts/run-windows-runner-direct.mjs');
    const matrixScript = readText('tests/e2e/ci/run-windows-dns-evidence-matrix-v2.ps1');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=local-overlay/);
    assert.match(result.stdout, /mode=dns-evidence-matrix-v2/);
    assert.match(result.stdout, /step=run-windows-dns-evidence-matrix-v2/);
    assert.equal(
      resolveWindowsDirectDiagnosticMode('dns-evidence-matrix-v2').artifactRoot,
      'C:\\Windows\\Temp\\openpath-dns-evidence-matrix-v2'
    );
    assert.match(script, /run-windows-dns-evidence-matrix-v2\.ps1/);
    assert.match(script, /dns-evidence-matrix-v2-result\.json/);
    assert.match(script, /direct-dns-evidence-matrix-v2-completion\.json/);
    assert.match(matrixScript, /AcrylicConfiguration\.ini/);
    assert.match(matrixScript, /AcrylicHosts\.txt/);
    assert.match(matrixScript, /HitLogFileWhat=XHCFRU/);
    assert.match(matrixScript, /HitLogMaxPendingHits=1/);
    assert.match(matrixScript, /HitLogFullDump=No/);
    assert.match(matrixScript, /OPENPATH_STUDENT_HOST_SUFFIX/);
    assert.match(matrixScript, /sslip\.io/);
    assert.match(
      matrixScript,
      /Resolve-DnsName -Name '\$encodedHost' -Server 127\.0\.0\.1 -DnsOnly -Type A/
    );
    assert.match(matrixScript, /Add-FwDependencyRules/);
    for (const phase of [
      'direct-dns-control',
      'browser-nx',
      'browser-fw',
      'browser-warm-multi-anchor',
    ]) {
      assert.match(matrixScript, new RegExp(phase));
    }
    for (const decision of [
      'browserDnsObservable',
      'browserForwardOnly',
      'directOnly',
      'ambiguousCorrelation',
      'insufficientEvidence',
    ]) {
      assert.match(matrixScript, new RegExp(decision));
    }
  });

  test('dns-observability-controls mode runs the positive HitLog controls', () => {
    const result = runDirectDiagnostic([
      '--mode',
      'dns-observability-controls',
      '--source-mode',
      'local-overlay',
    ]);
    const script = readText('scripts/run-windows-runner-direct.mjs');
    const controlsScript = readText('tests/e2e/ci/run-windows-dns-observability-controls.ps1');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=local-overlay/);
    assert.match(result.stdout, /mode=dns-observability-controls/);
    assert.match(result.stdout, /step=run-windows-dns-observability-controls/);
    assert.equal(
      resolveWindowsDirectDiagnosticMode('dns-observability-controls').artifactRoot,
      'C:\\Windows\\Temp\\openpath-dns-observability-controls'
    );
    assert.match(script, /run-windows-dns-observability-controls\.ps1/);
    assert.match(script, /dns-observability-controls-result\.json/);
    assert.match(script, /direct-dns-observability-controls-completion\.json/);
    assert.match(controlsScript, /AcrylicConfiguration\.ini/);
    assert.match(controlsScript, /AcrylicHosts\.txt/);
    assert.match(controlsScript, /HitLogFileWhat=XHCFRU/);
    assert.match(controlsScript, /HitLogMaxPendingHits=1/);
    assert.match(controlsScript, /HitLogFullDump=No/);
    assert.match(controlsScript, /raw\.githubusercontent\.com/);
    assert.match(controlsScript, /openpath-hitlog-nx-/);
    assert.match(
      controlsScript,
      /Resolve-DnsName -Name '\$encodedHost' -Server 127\.0\.0\.1 -DnsOnly -Type A/
    );
    assert.match(controlsScript, /pktmon filter add OpenPathDnsObservabilityForward -p 53/);
    assert.match(controlsScript, /purpose = 'forward-upstream-control-only'/);
    for (const decision of [
      'hitLogUsable',
      'hitLogForwardOnly',
      'hitLogUnusable',
      'insufficientEvidence',
    ]) {
      assert.match(controlsScript, new RegExp(decision));
    }
  });

  test('browser-dependency-observability-spike mode runs the browser/native spike without Acrylic HitLog', () => {
    const result = runDirectDiagnostic([
      '--mode',
      'browser-dependency-observability-spike',
      '--source-mode',
      'local-overlay',
    ]);
    const script = readText('scripts/run-windows-runner-direct.mjs');
    const spikeScript = readText(
      'tests/e2e/ci/run-windows-browser-dependency-observability-spike.ps1'
    );

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=local-overlay/);
    assert.match(result.stdout, /mode=browser-dependency-observability-spike/);
    assert.match(result.stdout, /step=run-windows-browser-dependency-observability-spike/);
    assert.equal(
      resolveWindowsDirectDiagnosticMode('browser-dependency-observability-spike').artifactRoot,
      'C:\\Windows\\Temp\\openpath-browser-dependency-observability-spike'
    );
    assert.match(script, /run-windows-browser-dependency-observability-spike\.ps1/);
    assert.match(script, /browser-dependency-observability-spike-result\.json/);
    assert.match(script, /direct-browser-dependency-observability-spike-completion\.json/);
    assert.doesNotMatch(spikeScript, /HitLog/i);
    assert.doesNotMatch(spikeScript, /AcrylicConfiguration\.ini/);
    assert.match(
      spikeScript,
      /OPENPATH_WINDOWS_STUDENT_COVERAGE_PROFILE = 'browser-dependency-observability-spike'/
    );
    for (const decision of [
      'runtimeRouteViable',
      'observerOnlyViable',
      'nativeOnlyViable',
      'ambiguousCorrelation',
      'insufficientEvidence',
    ]) {
      assert.match(spikeScript, new RegExp(decision));
    }
  });

  test('captive-portal-navigation mode runs the recovery retry fixture and collects artifacts', () => {
    const result = runDirectDiagnostic([
      '--mode',
      'captive-portal-navigation',
      '--source-mode',
      'local-overlay',
    ]);
    const script = readText('scripts/run-windows-runner-direct.mjs');
    const captiveScript = readText('tests/e2e/ci/run-windows-captive-portal-navigation.ps1');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=local-overlay/);
    assert.match(result.stdout, /mode=captive-portal-navigation/);
    assert.match(result.stdout, /step=run-windows-captive-portal-navigation/);
    assert.equal(
      resolveWindowsDirectDiagnosticMode('captive-portal-navigation').artifactRoot,
      'C:\\Windows\\Temp\\openpath-captive-portal-navigation'
    );
    assert.match(script, /run-windows-captive-portal-navigation\.ps1/);
    assert.match(script, /captive-portal-navigation-result\.json/);
    assert.match(script, /captive-portal-recovery-result/);
    assert.match(script, /captive-portal-recovery-queue/);
    assert.match(script, /captive-portal-recovery-progress/);
    assert.match(script, /captive-portal-task-state\.json/);
    assert.match(script, /Captive portal navigation result was not successful/);
    assert.match(script, /captive-portal-dns-before\.json/);
    assert.match(script, /captive-portal-dns-after\.json/);
    assert.match(script, /captive-portal-observation\.json/);
    assert.match(script, /captive-portal-firefox-navigation-result\.json/);
    assert.match(script, /captive-portal-config-snapshot\.json/);
    assert.match(script, /AcrylicHosts\.txt\.captive-portal-snapshot/);
    assert.match(script, /AcrylicConfiguration\.ini\.captive-portal-snapshot/);
    assert.match(script, /direct-captive-portal-navigation-completion\.json/);
    assert.match(captiveScript, /nce\.127\.0\.0\.1\.sslip\.io/);
    assert.match(captiveScript, /fixtureDoesNotProveRealWeduCaptiveDns/);
    assert.match(captiveScript, /captive-portal-recovery-fixture-state\.json/);
    assert.match(captiveScript, /Recover-CaptivePortal\.ps1\.product-backup/);
    assert.match(captiveScript, /Ensure-OpenPathDirectRunnerConfig/);
    assert.match(captiveScript, /Copy-CaptivePortalEnvironmentSnapshots/);
    assert.match(captiveScript, /captive-portal-config-snapshot\.json/);
    assert.match(captiveScript, /AcrylicHosts\.txt\.captive-portal-snapshot/);
    assert.match(captiveScript, /AcrylicConfiguration\.ini\.captive-portal-snapshot/);
    assert.match(captiveScript, /Copy-RecoveryDiagnosticArtifacts/);
    assert.match(captiveScript, /captive-portal-recovery-queue-manifest\.json/);
    assert.match(captiveScript, /captive-portal-recovery-progress-manifest\.json/);
    assert.match(captiveScript, /captive-portal-task-state\.json/);
    assert.match(captiveScript, /windows-direct-runtime-staging\.ps1/);
    assert.match(captiveScript, /Stage-OpenPathDirectRunnerRuntime/);
    assert.match(captiveScript, /C:\\OpenPath/);
    assert.match(captiveScript, /Install-LocalOnlyCaptivePortalRecoveryFixture/);
    assert.match(captiveScript, /Restore-LocalOnlyCaptivePortalRecoveryFixture/);
    assert.match(
      captiveScript,
      /Installed recovery script already contains the direct-runner fixture bypass/
    );
    assert.match(captiveScript, /direct-runner-captive-portal-navigation/);
    assert.match(captiveScript, /recover-captive-portal-navigation/);
    assert.match(captiveScript, /\$nativeHostTimeoutMs\s*=\s*90000/);
    assert.match(captiveScript, /WaitForExit\(\$nativeHostTimeoutMs\)/);
    assert.match(captiveScript, /captive-portal-active\.json/);
    assert.match(captiveScript, /dnsRecoveredFromAcrylicOnly/);
    assert.match(captiveScript, /nativeRecoveryVerified/);
    const nativeRecoveryVerifiedExpression =
      captiveScript.match(/\$nativeRecoveryVerified\s*=\s*\[bool\]\(([^)]*)\)/)?.[1] ?? '';
    assert.match(nativeRecoveryVerifiedExpression, /nativeResponse\.success/);
    assert.match(nativeRecoveryVerifiedExpression, /nativeResponse\.portalModeActive/);
    assert.match(nativeRecoveryVerifiedExpression, /nativeResponse\.recoveryHostsApplied/);
    assert.doesNotMatch(nativeRecoveryVerifiedExpression, /dnsRecoveredFromAcrylicOnly/);
    assert.doesNotMatch(captiveScript, /browserNavigationVerified = \$false/);
    const targetPlatformSymptomClearedExpression =
      captiveScript.match(/\$targetPlatformSymptomCleared\s*=\s*\[bool\]\(([^)]*)\)/)?.[1] ?? '';
    assert.match(targetPlatformSymptomClearedExpression, /browserNavigationVerified/);
    assert.match(targetPlatformSymptomClearedExpression, /postAuthProtectedModeRestored/);
    assert.match(captiveScript, /nativeStateIsPortal/);
    assert.match(captiveScript, /browserObservationLevel/);
    assert.match(captiveScript, /Invoke-FirefoxNavigationInspection/);
    assert.match(captiveScript, /webdriver-final-url/);
    assert.match(captiveScript, /finalUrl/);
    assert.match(captiveScript, /didNotLandOnBlockedPage/);
    assert.doesNotMatch(captiveScript, /headless-process-launch-only/);
    assert.doesNotMatch(captiveScript, /target-platform evidence must inspect the real browser/);
    assert.match(captiveScript, /expectedOneActivePortalMarker/);
    assert.match(captiveScript, /watchdogRecoveryConcurrencyHook/);
    assert.match(captiveScript, /portalExitRoute/);
    assert.match(captiveScript, /markerBeforeAuth/);
    assert.match(captiveScript, /markerAfterAuth/);
    assert.match(captiveScript, /captive-portal-dns-during\.json/);
    assert.match(captiveScript, /Set-LocalOnlyCaptivePortalRecoveryUpstreamMarker/);
    assert.match(captiveScript, /upstreamDnsSource = 'direct-runner-fixture'/);
    assert.match(
      captiveScript,
      /Invoke-FirefoxRetryObservation[\s\S]*Set-LocalOnlyCaptivePortalRecoveryFixtureState -State Authenticated/
    );
    assert.match(captiveScript, /localDnsLoopbackRestored/);
    assert.match(captiveScript, /acrylicNormalRestored/);
    assert.match(captiveScript, /blockedDomainStillBlocked/);
    assert.match(captiveScript, /allowedDomainFunctional/);
    assert.match(captiveScript, /firewallExpectedActive/);
    assert.match(captiveScript, /postAuthProtectedModeRestored/);
    assert.match(captiveScript, /operation = 'reconcile'/);
    assert.match(captiveScript, /noFailedTask/);
    assert.match(captiveScript, /Convert-ToScheduledTaskResultCode/);
    assert.match(captiveScript, /\[long\]\$Value/);
    assert.doesNotMatch(captiveScript, /\[int\]\$taskInfo\.LastTaskResult/);
    assert.match(captiveScript, /noPrematureExit/);
    assert.match(captiveScript, /blockedByOpenPath/);
    assert.match(captiveScript, /success = \$targetPlatformSymptomCleared/);
    assert.doesNotMatch(captiveScript, /success = \$postAuthProtectedModeRestored/);
  });

  test('captive-portal-wedu-lab mode is fail-closed and collects WEDU lab artifacts', () => {
    const result = runDirectDiagnostic(['--mode', 'captive-portal-wedu-lab']);
    const script = readText('scripts/run-windows-runner-direct.mjs');
    const weduCiScript = readText('scripts/run-wedu-captive-portal-lab-ci.sh');
    const weduScript = readText('tests/e2e/ci/run-windows-captive-portal-wedu-lab.ps1');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=runner-checkout/);
    assert.match(result.stdout, /mode=captive-portal-wedu-lab/);
    assert.match(result.stdout, /step=check-windows-runner-baseline/);
    assert.doesNotMatch(result.stdout, /step=reset-windows-runner/);
    assert.match(result.stdout, /step=run-windows-captive-portal-wedu-lab/);
    assert.equal(
      resolveWindowsDirectDiagnosticMode('captive-portal-wedu-lab').artifactRoot,
      'C:\\Windows\\Temp\\openpath-captive-portal-wedu-lab'
    );
    assert.match(script, /run-windows-captive-portal-wedu-lab\.ps1/);
    assert.match(script, /direct-captive-portal-wedu-lab-completion\.json/);
    for (const artifactName of [
      'wedu-lab-network-before.json',
      'wedu-lab-dns-before.json',
      'wedu-lab-dns-limited.json',
      'wedu-lab-browser-before.json',
      'wedu-lab-browser-limited.json',
      'wedu-lab-portal-limited-mode.png',
      'wedu-lab-native-recovery.json',
      'wedu-lab-native-reconcile.json',
      'wedu-lab-browser-post-auth.json',
      'wedu-lab-dns-post-auth.json',
      'wedu-lab-geckodriver-after-auth.out.log',
      'wedu-lab-geckodriver-after-auth.err.log',
      'wedu-lab-network-after.json',
      'wedu-lab-openpath-protection-after.json',
      'direct-captive-portal-wedu-lab-result.json',
      'direct-captive-portal-wedu-lab-completion.json',
    ]) {
      assert.match(script, new RegExp(artifactName.replace(/[.]/g, '\\.')));
      assert.match(weduScript, new RegExp(artifactName.replace(/[.]/g, '\\.')));
    }
    assert.match(weduScript, /wedu-lab-browser-post-auth\.json/);
    assert.match(weduScript, /wedu-lab-portal-limited-mode\.png/);
    assert.match(weduScript, /OPENPATH_WEDU_LAB_GATEWAY_TOKEN/);
    assert.match(weduScript, /OPENPATH_WEDU_LAB_GATEWAY_URL/);
    assert.match(weduScript, /OPENPATH_WEDU_LAB_EXPECTED_DNS/);
    assert.match(weduScript, /OPENPATH_WEDU_LAB_EXPECTED_SUBNET/);
    assert.match(weduScript, /OPENPATH_WEDU_LAB_NEGATIVE_CONTROLS/);
    assert.match(weduScript, /gateway-missing-token/);
    assert.match(weduScript, /pre-auth-external-blocked/);
    assert.match(weduScript, /OPENPATH_WEDU_LAB_POSTCONDITION_ASSERTIONS/);
    assert.match(weduScript, /portal-detected/);
    assert.match(weduScript, /post-auth-protection-restored/);
    assert.match(weduScript, /browserPortalDetected/);
    assert.match(weduScript, /browserLimited/);
    assert.match(weduScript, /portalReady/);
    assert.match(weduScript, /loginSubmitted/);
    assert.doesNotMatch(weduScript, /\$browserBefore = Invoke-WeduBrowserProbe/);
    assert.match(weduScript, /loginSubmitted = \$false/);
    assert.match(weduScript, /\$browserLimited = Invoke-WeduBrowserProbe -Config \$config/);
    assert.match(weduScript, /\$activeMarkerMode[\s\S]*'limited'/);
    assert.match(weduScript, /function ConvertTo-WeduNativeStringArray/);
    assert.match(
      weduScript,
      /\$allowedHosts = @\(ConvertTo-WeduNativeStringArray -Value \$nativeRecovery\.allowedHosts\)/
    );
    assert.match(
      weduScript,
      /\$nativeLimitedModeReady = \[bool\]\$nativeRecovery\.limitedModeReady/
    );
    assert.doesNotMatch(weduScript, /\$nativeRecovery\.observedRuntimeHosts \| Where-Object/);
    assert.match(weduScript, /limitedModeReady/);
    assert.match(weduScript, /bootstrapHosts/);
    assert.match(weduScript, /observedRuntimeHosts/);
    assert.match(weduScript, /pendingRuntimeHosts/);
    assert.match(weduScript, /discoveryTruncated/);
    assert.match(weduScript, /fallbackMode/);
    assert.match(weduScript, /nce\.wedu\.comunidad\.madrid/);
    assert.match(weduScript, /wlogin\.wedu-lab\.test/);
    assert.match(weduScript, /assets\.wedu-lab\.test/);
    assert.match(weduScript, /cdn\.wedu-lab\.test/);
    assert.match(weduScript, /auth\.wedu-lab\.test/);
    assert.match(weduCiScript, /install_gateway_portal_fixture/);
    assert.match(weduCiScript, /address=\/wlogin\.wedu-lab\.test\/10\.77\.0\.1/);
    assert.match(weduCiScript, /address=\/assets\.wedu-lab\.test\/10\.77\.0\.1/);
    assert.match(weduCiScript, /address=\/cdn\.wedu-lab\.test\/10\.77\.0\.1/);
    assert.match(weduCiScript, /address=\/auth\.wedu-lab\.test\/10\.77\.0\.1/);
    assert.match(weduCiScript, /systemctl restart dnsmasq/);
    assert.match(weduCiScript, /http:\/\/\{ASSET_HOST\}\/portal\.css/);
    assert.match(weduCiScript, /http:\/\/\{CDN_HOST\}\/portal\.js/);
    assert.match(weduCiScript, /http:\/\/\{AUTH_HOST\}\/session/);
    assert.match(weduScript, /window\.__openPathWeduPortalReady/);
    assert.match(weduScript, /Resolve-DnsName -Name \$limitedHost -Server 127\.0\.0\.1/);
    assert.doesNotMatch(weduScript, /foreach \(\$host in/i);
    assert.match(weduScript, /this-should-be-blocked-test-12345\.com/);
    assert.match(weduScript, /weduHostPortalDetected/);
    assert.match(weduScript, /detectPortalInterceptionObserved/);
    assert.match(
      weduScript,
      /portalDetected = \[bool\]\(\$browserPortalDetected -and \$weduHostPortalDetected\)/
    );
    assert.doesNotMatch(
      weduScript,
      /portalDetected = \[bool\]\(\$browserPortalDetected -and \$weduHostPortalDetected -and \$detectPortalInterceptionObserved\)/
    );
    assert.match(weduScript, /postAuthBrowserNavigationVerified/);
    assert.match(weduScript, /Invoke-WeduPostAuthBrowserProbeWithRetry/);
    const postAuthProbeBody =
      weduScript.match(
        /function Invoke-WeduPostAuthBrowserProbeWithRetry \{([\s\S]*?)\nfunction Assert-WeduPostconditions/
      )?.[1] ?? '';
    assert.match(postAuthProbeBody, /Find-FirefoxPath/);
    assert.match(postAuthProbeBody, /Find-GeckoDriverPath/);
    assert.match(weduScript, /function Invoke-WeduWebDriverPageProbe/);
    assert.match(weduScript, /Invoke-WebDriverJson/);
    assert.match(weduScript, /\/session\/\$(?:sessionId|SessionId)\/url/);
    assert.doesNotMatch(postAuthProbeBody, /Invoke-WeduBrowserNavigationProbe/);
    assert.doesNotMatch(postAuthProbeBody, /Invoke-HttpProbe -Url/);
    assert.match(weduScript, /postAuthFailureKind/);
    assert.match(weduScript, /portalMarkerAbsent = \$portalMarkerAbsent/);
    assert.match(
      weduScript,
      /\$verified = \[bool\]\(\$detectPortal\.externalNavigationFunctional -and \$msftConnectTest\.externalNavigationFunctional\)/
    );
    assert.doesNotMatch(
      weduScript,
      /\$verified = \[bool\]\(\$detectPortal\.externalNavigationFunctional -and \$msftConnectTest\.portalMarkerAbsent\)/
    );
    assert.match(weduScript, /externalNavigationFunctional = \$verified/);
    assert.match(weduScript, /failureKind = \$postAuthFailureKind/);
    assert.match(weduScript, /OPENPATH_WEDU_LAB_NATIVE_HOST_TIMEOUT_MS/);
    assert.match(weduScript, /schemaVersion = 2/);
    assert.match(weduScript, /location/);
    assert.match(weduScript, /WeduCaptiveHostPattern/);
    assert.doesNotMatch(weduScript, /\$statusCode -in @\(301, 302, 303, 307, 308\)/);
    assert.match(weduScript, /targetPlatformSymptomCleared = \[bool\]/);
    const successExpression =
      weduScript.match(/\$success\s*=\s*\[bool\]\(([\s\S]*?)\n\s*\)/)?.[1] ?? '';
    assert.match(successExpression, /labNetwork\.labNetworkVerified/);
    assert.match(successExpression, /nativeRecovery\.success/);
    assert.match(successExpression, /activeMarkerMode -eq 'limited'/);
    assert.match(successExpression, /limitedModeReady/);
    assert.match(successExpression, /limitedDns\.success/);
    assert.match(successExpression, /browserLimited\.portalReady/);
    assert.match(successExpression, /browserLimited\.finalLoginHost/);
    assert.match(successExpression, /browserLimited\.loginSubmitted/);
    assert.match(successExpression, /nativeReconcile\.state/);
    assert.doesNotMatch(successExpression, /nativeReconcile\.portalState/);
    assert.match(successExpression, /openPathProtectionAfter\.protectedModeRestored/);
    assert.match(weduScript, /success = \$success/);
    assert.match(weduScript, /success = \$false[\s\S]*targetPlatformSymptomCleared = \$false/);
    assert.match(weduScript, /Assert-WeduLabNetwork/);
    assert.doesNotMatch(weduScript, /Invoke-GatewayControl[\s\S]*gateway-authenticated/);
    assert.match(weduScript, /gateway-reset/);
    assert.match(weduScript, /recover-captive-portal-navigation/);
    assert.match(weduScript, /portalRecoveryHosts = \$script:WeduLimitedHosts/);
    assert.match(weduScript, /operation = 'reconcile'/);
    assert.match(weduScript, /windows-direct-runtime-staging\.ps1/);
    assert.match(weduScript, /Stage-OpenPathDirectRunnerRuntime/);
    assert.match(
      weduScript,
      /Stage-OpenPathDirectRunnerRuntime[\s\S]*\$nativeRecovery = Invoke-NativeHostAction/
    );
    assert.match(
      weduScript,
      /\$nativeRecovery = Invoke-NativeHostAction[\s\S]*\$limitedDns = Test-WeduLimitedModeDns[\s\S]*\$browserLimited = Invoke-WeduBrowserProbe/
    );
    assert.match(
      weduScript,
      /\$browserBefore = \[pscustomobject\]@{[\s\S]*loginSubmitted = \$false[\s\S]*Save-Json -Value \$browserBeforePayload[\s\S]*\$nativeRecovery = Invoke-NativeHostAction/
    );
    assert.doesNotMatch(weduScript, /\$browserBefore = \$browserLimited/);
  });

  test('captive portal lanes share the direct-runner runtime staging helper', () => {
    const helper = readText('tests/e2e/ci/windows-direct-runtime-staging.ps1');
    const captiveScript = readText('tests/e2e/ci/run-windows-captive-portal-navigation.ps1');
    const weduScript = readText('tests/e2e/ci/run-windows-captive-portal-wedu-lab.ps1');

    assert.match(helper, /function Stage-OpenPathDirectRunnerRuntime/);
    assert.match(helper, /function Copy-OpenPathDirectRunnerNativeArtifact/);
    assert.match(helper, /Register-OpenPathTask/);

    for (const scriptText of [captiveScript, weduScript]) {
      assert.match(scriptText, /windows-direct-runtime-staging\.ps1/);
      assert.doesNotMatch(scriptText, /function Copy-OpenPath(?:DirectRunner|Wedu)NativeArtifact/);
      assert.doesNotMatch(scriptText, /function Stage-OpenPathRuntimeFor(?:DirectRunner|WeduLab)/);
      assert.match(scriptText, /Stage-OpenPathDirectRunnerRuntime/);
    }
  });

  test('captive-portal-wedu-lab artifact collection is scoped to WEDU outputs', () => {
    const specs = getWindowsDirectArtifactSpecsForModes(['captive-portal-wedu-lab'], {
      runnerRoot: 'C:\\runner\\OpenPath',
      resultsPath: 'windows-test-results.xml',
    });
    const sourcePaths = specs.map((spec) => spec.sourcePath ?? spec.root);

    assert.ok(sourcePaths.length > 0);
    assert.ok(
      sourcePaths.every((sourcePath) =>
        sourcePath.startsWith('C:\\Windows\\Temp\\openpath-captive-portal-wedu-lab')
      ),
      sourcePaths.join('\n')
    );
    assert.ok(
      sourcePaths.some((sourcePath) =>
        sourcePath.endsWith('\\direct-captive-portal-wedu-lab-completion.json')
      )
    );
    assert.ok(
      sourcePaths.some((sourcePath) =>
        sourcePath.endsWith('\\direct-captive-portal-wedu-lab-result.json')
      )
    );
    assert.ok(
      sourcePaths.some((sourcePath) => sourcePath.endsWith('\\wedu-lab-browser-post-auth.json'))
    );
    assert.ok(
      sourcePaths.some((sourcePath) =>
        sourcePath.endsWith('\\wedu-lab-geckodriver-after-auth.out.log')
      )
    );
    assert.ok(
      sourcePaths.some((sourcePath) =>
        sourcePath.endsWith('\\wedu-lab-geckodriver-after-auth.err.log')
      )
    );
    assert.ok(
      specs.some(
        (spec) =>
          spec.kind === 'manifest' &&
          spec.root === 'C:\\Windows\\Temp\\openpath-captive-portal-wedu-lab'
      )
    );
    assert.doesNotMatch(sourcePaths.join('\n'), /windows-test-results\.xml/);
    assert.doesNotMatch(sourcePaths.join('\n'), /openpath-captive-portal-navigation/);
    assert.doesNotMatch(sourcePaths.join('\n'), /dns-evidence|dns-discovery|acrylic-purgecache/);
  });

  test('captive-portal-wedu-lab rejects local-overlay source by default', () => {
    const result = runDirectDiagnostic([
      '--mode',
      'captive-portal-wedu-lab',
      '--source-mode',
      'local-overlay',
    ]);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /captive-portal-wedu-lab requires --source-mode runner-checkout/);
  });

  test('all mode excludes the invasive WEDU captive portal lab', () => {
    const result = runDirectDiagnostic(['--mode', 'all']);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /mode=all/);
    assert.match(result.stdout, /step=reset-windows-runner/);
    assert.match(result.stdout, /step=run-windows-captive-portal-navigation/);
    assert.doesNotMatch(result.stdout, /step=run-windows-captive-portal-wedu-lab/);
  });

  test('acrylic-purgecache-spike mode runs only the runner diagnostic for host reload evidence', () => {
    const result = runDirectDiagnostic([
      '--mode',
      'acrylic-purgecache-spike',
      '--source-mode',
      'local-overlay',
    ]);
    const script = readText('scripts/run-windows-runner-direct.mjs');
    const spikeScript = readText('tests/e2e/ci/run-windows-acrylic-purgecache-spike.ps1');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /source_mode=local-overlay/);
    assert.match(result.stdout, /mode=acrylic-purgecache-spike/);
    assert.match(result.stdout, /step=run-windows-acrylic-purgecache-spike/);
    assert.equal(
      resolveWindowsDirectDiagnosticMode('acrylic-purgecache-spike').artifactRoot,
      'C:\\Windows\\Temp\\openpath-acrylic-purgecache-spike'
    );
    assert.match(script, /run-windows-acrylic-purgecache-spike\.ps1/);
    assert.match(script, /acrylic-purgecache-spike-result\.json/);
    assert.match(script, /direct-acrylic-purgecache-spike-completion\.json/);
    assert.match(spikeScript, /AcrylicController\.exe/);
    assert.match(spikeScript, /PurgeCache/);
    assert.match(spikeScript, /AcrylicHosts\.txt/);
    assert.match(spikeScript, /Resolve-DnsName -Name \$Hostname -Server 127\.0\.0\.1/);
    assert.match(spikeScript, /officialAcrylicHostsContract/);
    for (const decision of ['purgeCacheReloadsHosts', 'restartRequired', 'inconclusive']) {
      assert.match(spikeScript, new RegExp(decision));
    }
  });

  test(
    'workspace wrapper blocks GitHub integration lanes without explicit flag',
    { skip: !process.env.WHITELIST_WORKSPACE_ROOT },
    () => {
      const result = runWorkspaceWrapper(['openpath', 'windows-gh', '--dry-run']);

      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /require --integration/);
    }
  );

  test('workspace wrapper forwards artifact-dir after the npm script separator', () => {
    const result = runWorkspaceWrapper([
      'openpath',
      'windows-direct',
      '--artifact-dir',
      '.opencode/tmp/windows-direct-review',
      '--dry-run',
    ]);

    const tokens = assertWindowsDirectCommand(result, [
      { name: '--source-mode', value: 'runner-checkout' },
    ]);
    const artifactDirIndex = tokens.indexOf('--artifact-dir');
    assert.notEqual(artifactDirIndex, -1, `Expected --artifact-dir in ${tokens.join(' ')}`);
    assert.match(tokens[artifactDirIndex + 1], /\.opencode\/tmp\/windows-direct-review$/);
    assert.ok(tokens.indexOf('--') < tokens.indexOf('--artifact-dir'));
  });

  test('workspace wrapper defaults windows-direct to the runner checkout source', () => {
    const result = runWorkspaceWrapper(['openpath', 'windows-direct', '--dry-run']);

    assertWindowsDirectCommand(result, [{ name: '--source-mode', value: 'runner-checkout' }]);
  });

  test('workspace wrapper forwards local-overlay source mode after the npm script separator', () => {
    const result = runWorkspaceWrapper([
      'openpath',
      'windows-direct',
      '--source-mode',
      'local-overlay',
      '--dry-run',
    ]);

    assertWindowsDirectCommand(result, [{ name: '--source-mode', value: 'local-overlay' }]);
  });

  test('workspace wrapper rejects the removed google-game-blocking direct suite', () => {
    const result = runWorkspaceWrapper([
      'openpath',
      'windows-direct',
      '--suite',
      'google-game-blocking',
      '--artifact-dir',
      '.opencode/tmp/windows-browser-boundary-direct',
      '--dry-run',
    ]);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Unsupported suite/);
  });
});
