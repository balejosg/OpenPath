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

  test(
    'workspace wrapper blocks GitHub integration lanes without explicit flag',
    { skip: !process.env.WHITELIST_WORKSPACE_ROOT },
    () => {
      const result = runWorkspaceWrapper(['openpath', 'windows-gh', '--dry-run']);

      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /require --integration/);
    }
  );

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
