import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import process from 'node:process';
import { describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  extractUsableGuestIPv4,
  parseRunnerRepoRootCandidates,
  selectPreferredRunnerRepoRoot,
} from '../scripts/run-windows-runner-direct.mjs';
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
  const wrapperPath = resolve(projectRoot, '..', 'scripts', 'validate-hypothesis.sh');
  return spawnSync('bash', [wrapperPath, ...args], {
    cwd: resolve(projectRoot, '..'),
    encoding: 'utf8',
  });
}

describe('direct OpenPath Windows runner diagnostic', () => {
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
    assert.match(script, /run-windows-dns-evidence-matrix\.ps1/);
    assert.match(script, /openpath-dns-evidence-matrix/);
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
    assert.match(script, /run-windows-dns-evidence-matrix-v2\.ps1/);
    assert.match(script, /openpath-dns-evidence-matrix-v2/);
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
    assert.match(script, /run-windows-dns-observability-controls\.ps1/);
    assert.match(script, /openpath-dns-observability-controls/);
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
    assert.match(script, /run-windows-browser-dependency-observability-spike\.ps1/);
    assert.match(script, /openpath-browser-dependency-observability-spike/);
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

    assert.equal(result.status, 0, result.stderr);
    assert.match(
      result.stdout,
      /npm run diagnostics:windows:direct -- --artifact-dir .*\.opencode\/tmp\/windows-direct-review/
    );
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
