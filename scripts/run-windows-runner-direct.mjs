#!/usr/bin/env node

import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import process from 'node:process';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const DEFAULT_PROXMOX_HOST = 'whitelist-proxmox';
const DEFAULT_WINDOWS_RUNNER_VMID = '103';
const DEFAULT_TIMEOUT_SECONDS = '900';
const DEFAULT_RESULTS_RELATIVE_PATH = 'windows-test-results.xml';
const DEFAULT_RESULTS_ARTIFACT_NAME = 'windows-test-results.xml';
const DEFAULT_ARTIFACT_LOG_NAME = 'windows-runner-direct.log';
const DEFAULT_RUNNER_ROOT_GLOB = 'C:\\actions-runner*';
const SOURCE_MODES = new Set(['runner-checkout', 'local-overlay']);
const DEFAULT_SOURCE_MODE = 'runner-checkout';
const RUN_MODES = new Set(['pester', 'browser-boundary', 'dns-discovery-spike', 'all']);
const DEFAULT_RUN_MODE = 'pester';
const OVERLAY_ZIP_NAME = 'openpath-local-overlay.zip';
const BROWSER_ENFORCEMENT_ARTIFACTS = [
  'browser-boundary-summary.json',
  'student\\windows-browser-enforcement-report.json',
  'student\\windows-browser-enforcement-report.txt',
  'admin\\windows-browser-enforcement-report.json',
  'admin\\windows-browser-enforcement-report.txt',
];
const BROWSER_ENFORCEMENT_REPORT_ARTIFACTS = [
  'windows-browser-enforcement-report.json',
  'windows-browser-enforcement-report.txt',
];
const DNS_DISCOVERY_SPIKE_ARTIFACTS = [
  'dns-discovery-spike-result.json',
  'dns-discovery-spike-browser-artifact.json',
  'dns-discovery-spike-state.json',
  'dns-discovery-cold-origin-hitlog.log',
  'dns-discovery-warm-approved-origin-hitlog.log',
  'acrylic-dns-discovery-spike.log',
  'acrylic-dns-discovery-spike.sanitized.log',
  'acrylic-dns-discovery-spike.hashes.json',
  'direct-dns-discovery-spike-completion.json',
  'direct-dns-discovery-spike.out.log',
  'direct-dns-discovery-spike.err.log',
];
const DRY_RUN = process.env.OPENPATH_WINDOWS_DIRECT_DRY_RUN === '1';

const currentFilePath = fileURLToPath(import.meta.url);
const scriptDir = dirname(currentFilePath);
const projectRoot = resolve(scriptDir, '..');

function printUsage() {
  console.error(`Usage:
  npm run diagnostics:windows:direct -- [options]

Options:
  --proxmox-host <host>       Proxmox SSH host/alias (default: ${DEFAULT_PROXMOX_HOST})
  --vmid <id>                 Windows runner VMID (default: ${DEFAULT_WINDOWS_RUNNER_VMID})
  --timeout-seconds <secs>    Timeout passed to the isolated Pester helper (default: ${DEFAULT_TIMEOUT_SECONDS})
  --results-path <path>       Result file path on the Windows runner relative to the repo root (default: ${DEFAULT_RESULTS_RELATIVE_PATH})
  --runner-repo-root <path>   Explicit OpenPath checkout root on the Windows runner (default: auto-detect under ${DEFAULT_RUNNER_ROOT_GLOB})
  --source-mode <mode>        Source to execute on Windows: runner-checkout or local-overlay (default: ${DEFAULT_SOURCE_MODE})
  --mode <mode>               What to run: pester, browser-boundary, dns-discovery-spike, or all (default: ${DEFAULT_RUN_MODE})
  --overlay-host <ip>         Local host/IP the Windows VM can use to download the local overlay ZIP
  --browser-enforcement-report
                              Run tests/e2e/ci/windows-browser-enforcement.ps1 -Scope Report after Pester
  --artifact-dir <path>       Local artifact directory (default: .opencode/tmp/openpath-windows-direct/<timestamp>)
  --help                      Show this message
`);
}

function parseArgs(argv) {
  const options = {
    proxmoxHost:
      process.env.WINDOWS_RUNNER_PROXMOX_HOST ??
      process.env.PROXMOX_SSH_ALIAS ??
      DEFAULT_PROXMOX_HOST,
    vmid: process.env.WINDOWS_RUNNER_VMID ?? DEFAULT_WINDOWS_RUNNER_VMID,
    timeoutSeconds: process.env.OPENPATH_WINDOWS_DIRECT_TIMEOUT_SECONDS ?? DEFAULT_TIMEOUT_SECONDS,
    resultsPath: process.env.OPENPATH_WINDOWS_DIRECT_RESULTS_PATH ?? DEFAULT_RESULTS_RELATIVE_PATH,
    runnerRepoRoot: process.env.OPENPATH_WINDOWS_DIRECT_RUNNER_REPO_ROOT ?? '',
    sourceMode: process.env.OPENPATH_WINDOWS_DIRECT_SOURCE_MODE ?? DEFAULT_SOURCE_MODE,
    mode: process.env.OPENPATH_WINDOWS_DIRECT_MODE ?? DEFAULT_RUN_MODE,
    overlayHost: process.env.OPENPATH_WINDOWS_DIRECT_OVERLAY_HOST ?? '',
    browserEnforcementReport:
      process.env.OPENPATH_WINDOWS_DIRECT_BROWSER_ENFORCEMENT_REPORT === '1',
    artifactDir: '',
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) {
        throw new Error(`${arg} requires a value`);
      }
      index += 1;
      return value;
    };

    if (arg === '--proxmox-host') {
      options.proxmoxHost = next();
    } else if (arg === '--vmid') {
      options.vmid = next();
    } else if (arg === '--timeout-seconds') {
      options.timeoutSeconds = next();
    } else if (arg === '--results-path') {
      options.resultsPath = next();
    } else if (arg === '--runner-repo-root') {
      options.runnerRepoRoot = next();
    } else if (arg === '--source-mode') {
      options.sourceMode = next();
    } else if (arg === '--mode') {
      options.mode = next();
    } else if (arg === '--overlay-host') {
      options.overlayHost = next();
    } else if (arg === '--browser-enforcement-report') {
      options.browserEnforcementReport = true;
    } else if (arg === '--artifact-dir') {
      options.artifactDir = resolve(projectRoot, next());
    } else if (arg === '--help' || arg === '-h') {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown option: ${arg}`);
    }
  }

  if (!SOURCE_MODES.has(options.sourceMode)) {
    throw new Error(
      `Invalid --source-mode ${JSON.stringify(options.sourceMode)}. Expected one of: ${[
        ...SOURCE_MODES,
      ].join(', ')}`
    );
  }
  if (!RUN_MODES.has(options.mode)) {
    throw new Error(
      `Invalid --mode ${JSON.stringify(options.mode)}. Expected one of: ${[...RUN_MODES].join(', ')}`
    );
  }

  return options;
}

function shellQuote(value) {
  const text = String(value);
  return /^[A-Za-z0-9_./:@=+-]+$/.test(text) ? text : `'${text.replace(/'/g, `'\\''`)}'`;
}

function renderCommand(args) {
  return args.map((arg) => shellQuote(arg)).join(' ');
}

function encodePowerShell(script) {
  return Buffer.from(script, 'utf16le').toString('base64');
}

function runCommand(args, { cwd = projectRoot, input, capture = false } = {}) {
  const result = spawnSync(args[0], args.slice(1), {
    cwd,
    encoding: 'utf8',
    input,
    stdio: capture ? ['pipe', 'pipe', 'pipe'] : ['pipe', 'inherit', 'inherit'],
  });

  if (result.status !== 0) {
    const stderr = result.stderr ? `\n${result.stderr.trim()}` : '';
    throw new Error(
      `${renderCommand(args)} failed with exit code ${result.status ?? 'unknown'}${stderr}`
    );
  }

  return capture ? result.stdout.trim() : '';
}

function runProxmoxCommand(options, proxmoxArgs, { capture = true } = {}) {
  const args = ['ssh', options.proxmoxHost, renderCommand(proxmoxArgs)];
  if (DRY_RUN) {
    console.log(renderCommand(args));
    return '';
  }

  return runCommand(args, { capture });
}

function runGuestCommand(options, guestArgs, { capture = true } = {}) {
  const remoteCommand = renderCommand(['qm', 'guest', 'exec', options.vmid, ...guestArgs]);
  const args = ['ssh', options.proxmoxHost, remoteCommand];

  if (DRY_RUN) {
    const encodedCommandIndex = guestArgs.indexOf('-EncodedCommand');
    const previewGuestArgs =
      encodedCommandIndex === -1
        ? guestArgs
        : [...guestArgs.slice(0, encodedCommandIndex + 1), '<encoded>'];
    console.log(
      renderCommand([
        'ssh',
        options.proxmoxHost,
        renderCommand(['qm', 'guest', 'exec', options.vmid, ...previewGuestArgs]),
      ])
    );
    return '';
  }

  const output = runCommand(args, { capture });
  if (!capture) {
    return '';
  }

  const payload = JSON.parse(output);
  if (payload.exitcode !== 0 || payload.exited !== 1) {
    throw new Error(
      `Guest command failed with exit code ${payload.exitcode ?? 'unknown'}: ${payload['err-data'] ?? payload['out-data'] ?? ''}`
    );
  }

  return payload['out-data'] ?? '';
}

function sleepSync(milliseconds) {
  const signal = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(signal, 0, 0, milliseconds);
}

function runGuestCommandAsync(options, guestArgs, { timeoutSeconds = 600, pollSeconds = 5 } = {}) {
  const remoteCommand = renderCommand([
    'qm',
    'guest',
    'exec',
    options.vmid,
    '--synchronous',
    '0',
    ...guestArgs,
  ]);
  const args = ['ssh', options.proxmoxHost, remoteCommand];

  if (DRY_RUN) {
    console.log(renderCommand(args));
    console.log(
      renderCommand([
        'ssh',
        options.proxmoxHost,
        renderCommand(['qm', 'guest', 'exec-status', options.vmid, '<pid>']),
      ])
    );
    return '';
  }

  const started = JSON.parse(runCommand(args, { capture: true }));
  if (!started.pid) {
    throw new Error(`Guest async command did not return a pid: ${JSON.stringify(started)}`);
  }

  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    const statusOutput = runProxmoxCommand(options, [
      'qm',
      'guest',
      'exec-status',
      options.vmid,
      String(started.pid),
    ]);
    const status = JSON.parse(statusOutput);
    if (status.exited === 1) {
      if (status.exitcode !== 0) {
        throw new Error(
          `Guest command failed with exit code ${status.exitcode ?? 'unknown'}: ${
            status['err-data'] ?? status['out-data'] ?? ''
          }`
        );
      }
      return status['out-data'] ?? '';
    }
    sleepSync(pollSeconds * 1000);
  }

  throw new Error(`Guest async command timed out after ${timeoutSeconds} seconds`);
}

function runGuestPowerShell(options, script, { timeoutSeconds = 600, label = 'PowerShell' } = {}) {
  try {
    return runGuestCommand(options, [
      '--timeout',
      String(timeoutSeconds),
      '--',
      'powershell.exe',
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      encodePowerShell(script),
    ]);
  } catch (error) {
    throw new Error(`${label} failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function runGuestPowerShellAsync(
  options,
  script,
  { timeoutSeconds = 600, label = 'PowerShell' } = {}
) {
  try {
    return runGuestCommandAsync(
      options,
      [
        '--',
        'powershell.exe',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodePowerShell(script),
      ],
      { timeoutSeconds }
    );
  } catch (error) {
    throw new Error(`${label} failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function runGuestPowerShellDetached(options, script, { label = 'PowerShell' } = {}) {
  try {
    const remoteCommand = renderCommand([
      'qm',
      'guest',
      'exec',
      options.vmid,
      '--synchronous',
      '0',
      '--',
      'powershell.exe',
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      encodePowerShell(script),
    ]);
    const args = ['ssh', options.proxmoxHost, remoteCommand];

    if (DRY_RUN) {
      console.log(renderCommand(args));
      return 0;
    }

    const started = JSON.parse(runCommand(args, { capture: true }));
    if (!started.pid) {
      throw new Error(`Guest detached command did not return a pid: ${JSON.stringify(started)}`);
    }
    return started.pid;
  } catch (error) {
    throw new Error(`${label} failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function waitForGuestCompletionFile(options, completionPath, { timeoutSeconds = 600 } = {}) {
  if (DRY_RUN) {
    console.log(`# wait for Windows completion marker ${completionPath}`);
    return { exitCode: 0 };
  }

  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    const content = readGuestFile(options, completionPath, 120000).trim();
    if (content) {
      return JSON.parse(content);
    }
    sleepSync(5000);
  }

  throw new Error(`Timed out waiting for Windows completion marker: ${completionPath}`);
}

function parseGuestNetworkInterfaces(output) {
  const trimmed = output.trim();
  if (!trimmed) {
    return [];
  }

  const parsed = JSON.parse(trimmed);
  const interfaces = Array.isArray(parsed) ? parsed : (parsed.result ?? parsed.data ?? []);
  if (!Array.isArray(interfaces)) {
    return [];
  }

  return interfaces;
}

function extractUsableGuestIPv4(output) {
  const interfaces = parseGuestNetworkInterfaces(output);
  const addresses = interfaces.flatMap((networkInterface) => {
    const ipAddresses =
      networkInterface['ip-addresses'] ??
      networkInterface.ipAddresses ??
      networkInterface.ip_addresses ??
      [];
    return Array.isArray(ipAddresses) ? ipAddresses : [];
  });

  const usableAddress = addresses.find((address) => {
    const ipAddress = address['ip-address'] ?? address.ipAddress ?? address.ip;
    const ipType = String(
      address['ip-address-type'] ?? address.ipAddressType ?? address.type ?? ''
    );
    return (
      typeof ipAddress === 'string' &&
      /^\d{1,3}(?:\.\d{1,3}){3}$/.test(ipAddress) &&
      ipAddress !== '127.0.0.1' &&
      !ipAddress.startsWith('169.254.') &&
      (!ipType || ipType.toLowerCase() === 'ipv4')
    );
  });

  return usableAddress
    ? (usableAddress['ip-address'] ?? usableAddress.ipAddress ?? usableAddress.ip)
    : '';
}

function getWindowsGuestIPv4(options) {
  const output = runProxmoxCommand(options, [
    'qm',
    'guest',
    'cmd',
    options.vmid,
    'network-get-interfaces',
  ]);
  const guestIp = extractUsableGuestIPv4(output);
  if (!guestIp) {
    throw new Error('Unable to detect a usable IPv4 address for the Windows runner VM.');
  }

  return guestIp;
}

function detectOverlayHostForGuest(guestIp) {
  const output = runCommand(['ip', 'route', 'get', guestIp], { capture: true });
  const match = output.match(/\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})\b/);
  if (!match) {
    throw new Error(`Unable to detect local source IP for Windows runner guest ${guestIp}.`);
  }

  return match[1];
}

function assertCleanWorktreeForOverlay() {
  const status = runCommand(['git', 'status', '--porcelain'], { capture: true });
  if (status.trim()) {
    throw new Error(
      'local-overlay validates committed HEAD only; commit or clean local OpenPath changes before running it.'
    );
  }
}

function createLocalOverlayArchive(artifactDir) {
  assertCleanWorktreeForOverlay();
  const overlayZipPath = resolve(artifactDir, OVERLAY_ZIP_NAME);
  runCommand(['git', 'archive', '--format=zip', '--output', overlayZipPath, 'HEAD']);
  return overlayZipPath;
}

function startOverlayServer(overlayZipPath, overlayHost) {
  const serverScript = String.raw`
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const overlayZipPath = process.env.OPENPATH_OVERLAY_ZIP_PATH;
const overlayHost = process.env.OPENPATH_OVERLAY_HOST;
const zipName = path.basename(overlayZipPath);
const zipSize = fs.statSync(overlayZipPath).size;

const server = http.createServer((request, response) => {
  if (request.url !== '/' + zipName) {
    response.writeHead(404, { Connection: 'close' });
    response.end('not found');
    return;
  }

  response.writeHead(200, {
    'Content-Type': 'application/zip',
    'Content-Length': String(zipSize),
    'Content-Disposition': 'attachment; filename="' + zipName + '"',
    Connection: 'close',
  });

  if (request.method === 'HEAD') {
    response.end();
    return;
  }

  fs.createReadStream(overlayZipPath)
    .on('error', (error) => {
      response.destroy(error);
    })
    .pipe(response);
});

server.listen(0, overlayHost, () => {
  const address = server.address();
  process.stdout.write(JSON.stringify({
    url: 'http://' + overlayHost + ':' + address.port + '/' + zipName
  }) + '\n');
});

process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});
`;

  const serverProcess = spawn(process.execPath, ['-e', serverScript], {
    cwd: projectRoot,
    env: {
      ...process.env,
      OPENPATH_OVERLAY_ZIP_PATH: overlayZipPath,
      OPENPATH_OVERLAY_HOST: overlayHost,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  return new Promise((resolveServer, rejectServer) => {
    let stdout = '';
    let stderr = '';
    let settled = false;

    const rejectOnce = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      serverProcess.kill('SIGTERM');
      rejectServer(error);
    };

    serverProcess.stdout.on('data', (chunk) => {
      stdout += chunk.toString('utf8');
      const firstLine = stdout.split(/\r?\n/, 1)[0]?.trim();
      if (!firstLine) {
        return;
      }

      try {
        const payload = JSON.parse(firstLine);
        settled = true;
        resolveServer({
          process: serverProcess,
          url: payload.url,
        });
      } catch {
        rejectOnce(new Error(`Unable to parse overlay server startup output: ${firstLine}`));
      }
    });

    serverProcess.stderr.on('data', (chunk) => {
      stderr += chunk.toString('utf8');
    });

    serverProcess.once('error', (error) => {
      rejectOnce(error);
    });

    serverProcess.once('exit', (code, signal) => {
      if (settled) {
        return;
      }
      rejectOnce(
        new Error(
          `Overlay server exited before startup: code=${code ?? 'null'} signal=${
            signal ?? 'null'
          } stderr=${stderr.trim()}`
        )
      );
    });
  });
}

function stopOverlayServer(serverProcess) {
  if (!serverProcess) {
    return Promise.resolve();
  }

  return new Promise((resolveStop) => {
    if (serverProcess.exitCode !== null || serverProcess.killed) {
      resolveStop();
      return;
    }

    const forceKillTimeout = setTimeout(() => {
      serverProcess.kill('SIGKILL');
    }, 2000);

    serverProcess.once('exit', () => {
      clearTimeout(forceKillTimeout);
      resolveStop();
    });
    serverProcess.kill('SIGTERM');
  });
}

function prepareLocalOverlayOnWindows(options, overlayUrl) {
  const script = `
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$overlayRoot = Join-Path $env:TEMP ('openpath-direct-overlay-' + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $env:TEMP ('openpath-local-overlay-' + [guid]::NewGuid().ToString('N') + '.zip')
New-Item -ItemType Directory -Path $overlayRoot -Force | Out-Null
Invoke-WebRequest -Uri ${JSON.stringify(overlayUrl)} -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
Expand-Archive -LiteralPath $zipPath -DestinationPath $overlayRoot -Force
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath (Join-Path $overlayRoot 'tests\\e2e\\ci\\run-windows-pester-isolated.ps1'))) {
  throw 'Expanded local overlay is missing run-windows-pester-isolated.ps1.'
}
$overlayRoot
`;
  return runGuestPowerShell(options, script, {
    timeoutSeconds: 600,
    label: 'Prepare local overlay on Windows',
  }).trim();
}

function cleanupWindowsOverlay(options, overlayRoot) {
  if (!overlayRoot || DRY_RUN) {
    return;
  }

  const script = `
$ErrorActionPreference = 'Continue'
$overlayRoot = ${JSON.stringify(overlayRoot)}
if ($overlayRoot -and (Test-Path -LiteralPath $overlayRoot)) {
  Remove-Item -LiteralPath $overlayRoot -Recurse -Force -ErrorAction SilentlyContinue
}
`;
  runGuestPowerShell(options, script, {
    timeoutSeconds: 120,
    label: 'Clean local overlay on Windows',
  });
}

function buildRunnerRepoRootScript() {
  return String.raw`
$candidateRoots = @()
if (${JSON.stringify(DEFAULT_RUNNER_ROOT_GLOB)}) {
  $candidateRoots += Get-ChildItem -Path ${JSON.stringify(DEFAULT_RUNNER_ROOT_GLOB)} -Directory -Force -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName '_work' }
}

$candidateRoots += 'C:\\actions-runner\\_work'

$repoRoots = $candidateRoots |
  Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
  ForEach-Object {
    Get-ChildItem -Path $_ -Directory -Force -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName $_.Name }
  }

$repoRoots = @(
  $repoRoots |
  Where-Object {
    Test-Path -LiteralPath (Join-Path $_ 'tests\\e2e\\ci\\run-windows-pester-isolated.ps1')
  } |
  Sort-Object -Unique
)

ConvertTo-Json -InputObject $repoRoots -Compress
`;
}

function parseRunnerRepoRootCandidates(output) {
  const trimmed = output.trim();
  if (!trimmed) {
    return [];
  }

  const parsed = JSON.parse(trimmed);
  return Array.isArray(parsed) ? parsed : [parsed];
}

function getRunnerRepoRootPriority(repoRoot) {
  if (/^C:\\actions-runner-openpath\\/i.test(repoRoot)) {
    return 0;
  }

  if (/^C:\\actions-runner\\/i.test(repoRoot)) {
    return 1;
  }

  return 2;
}

function selectPreferredRunnerRepoRoot(candidateRepoRoots) {
  const repoRoots = [
    ...new Set(candidateRepoRoots.map((value) => String(value).trim()).filter(Boolean)),
  ];

  if (repoRoots.length === 0) {
    throw new Error('Unable to auto-detect the OpenPath checkout root on the Windows runner.');
  }

  repoRoots.sort((left, right) => {
    const priorityDifference = getRunnerRepoRootPriority(left) - getRunnerRepoRootPriority(right);
    return priorityDifference !== 0 ? priorityDifference : left.localeCompare(right);
  });

  return repoRoots[0];
}

function resolveWindowsRunnerRepoRoot(options) {
  if (options.runnerRepoRoot) {
    return options.runnerRepoRoot;
  }

  const candidateRepoRoots = parseRunnerRepoRootCandidates(
    runGuestPowerShell(options, buildRunnerRepoRootScript(), {
      timeoutSeconds: 120,
    })
  );

  return selectPreferredRunnerRepoRoot(candidateRepoRoots);
}

function ensureWindowsRunnerBaseline(options, runnerRepoRoot) {
  const script = `
$ErrorActionPreference = 'Stop'
hostname
whoami
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh) {
  throw 'pwsh is required on the Windows runner.'
}
if (-not (Test-Path ${JSON.stringify(runnerRepoRoot)})) {
  throw 'Expected OpenPath checkout root is missing on the Windows runner.'
}
`;
  runGuestPowerShell(options, script, {
    timeoutSeconds: 120,
    label: 'Check Windows runner baseline',
  });
}

function resetWindowsRunner(options, runnerRepoRoot) {
  const resetScriptPath = `${runnerRepoRoot}\\tests\\e2e\\ci\\reset-self-hosted-windows-runner.ps1`;
  const script = `
$ErrorActionPreference = 'Stop'
if (-not (Test-Path ${JSON.stringify(resetScriptPath)})) {
  throw 'reset-self-hosted-windows-runner.ps1 is missing on the Windows runner checkout.'
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${JSON.stringify(resetScriptPath)}
if ($LASTEXITCODE -ne 0) {
  throw "reset-self-hosted-windows-runner.ps1 exited with code $LASTEXITCODE"
}
`;
  runGuestPowerShell(options, script, {
    timeoutSeconds: 300,
    label: 'Reset self-hosted Windows runner',
  });
}

function runDirectPester(options, runnerRepoRoot) {
  const isolatedRunnerPath = `${runnerRepoRoot}\\tests\\e2e\\ci\\run-windows-pester-isolated.ps1`;
  const repoRoot = runnerRepoRoot;
  const resultsPath = options.resultsPath.replace(/\//g, '\\\\');
  const script = `
$ErrorActionPreference = 'Stop'
$repoRoot = ${JSON.stringify(repoRoot)}
$runnerPath = ${JSON.stringify(isolatedRunnerPath)}
$resultsPath = ${JSON.stringify(resultsPath)}

if (-not (Test-Path $runnerPath)) {
  throw 'run-windows-pester-isolated.ps1 is missing on the Windows runner checkout.'
}

Set-Location $repoRoot
& pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runnerPath -RepoRoot $repoRoot -ResultsPath $resultsPath -TimeoutSeconds ${Number.parseInt(options.timeoutSeconds, 10)}
if ($LASTEXITCODE -ne 0) {
  throw "run-windows-pester-isolated.ps1 exited with code $LASTEXITCODE"
}
`;
  runGuestPowerShell(options, script, {
    timeoutSeconds: Number.parseInt(options.timeoutSeconds, 10) + 120,
    label: 'Run isolated Windows Pester',
  });
}

function runBrowserEnforcementReport(options, runnerRepoRoot) {
  const reportScriptPath = `${runnerRepoRoot}\\tests\\e2e\\ci\\windows-browser-enforcement.ps1`;
  const artifactsRoot = `${runnerRepoRoot}\\tests\\e2e\\artifacts\\windows-browser-enforcement`;
  const script = `
$ErrorActionPreference = 'Stop'
$repoRoot = ${JSON.stringify(runnerRepoRoot)}
$reportScriptPath = ${JSON.stringify(reportScriptPath)}
$artifactsRoot = ${JSON.stringify(artifactsRoot)}

if (-not (Test-Path -LiteralPath $reportScriptPath)) {
  throw 'windows-browser-enforcement.ps1 is missing on the Windows runner checkout.'
}

New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
$env:OPENPATH_STUDENT_ARTIFACTS_DIR = $artifactsRoot
Set-Location $repoRoot
& pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $reportScriptPath -Scope Report -ArtifactsRoot $artifactsRoot
if ($LASTEXITCODE -ne 0) {
  throw "windows-browser-enforcement.ps1 exited with code $LASTEXITCODE"
}
`;
  runGuestPowerShell(options, script, {
    timeoutSeconds: 300,
    label: 'Run Windows browser enforcement report',
  });
}

function runWindowsStudentPolicyFlowForBoundary(options, runnerRepoRoot) {
  const flowScriptPath = `${runnerRepoRoot}\\tests\\e2e\\ci\\run-windows-student-flow.ps1`;
  const boundaryScriptPath = `${runnerRepoRoot}\\tests\\e2e\\ci\\run-windows-browser-boundary-ci.ps1`;
  const resetScriptPath = `${runnerRepoRoot}\\tests\\e2e\\ci\\reset-self-hosted-windows-runner.ps1`;
  const artifactsRoot = `${runnerRepoRoot}\\tests\\e2e\\artifacts\\windows-student-policy`;
  const boundaryArtifactsRoot = `${artifactsRoot}\\browser-boundary`;
  const completionPath = `${artifactsRoot}\\direct-browser-boundary-completion.json`;
  const script = `
$ErrorActionPreference = 'Stop'
$repoRoot = ${JSON.stringify(runnerRepoRoot)}
$flowScriptPath = ${JSON.stringify(flowScriptPath)}
$boundaryScriptPath = ${JSON.stringify(boundaryScriptPath)}
$resetScriptPath = ${JSON.stringify(resetScriptPath)}
$artifactsRoot = ${JSON.stringify(artifactsRoot)}
$boundaryArtifactsRoot = ${JSON.stringify(boundaryArtifactsRoot)}
$completionPath = ${JSON.stringify(completionPath)}

if (-not (Test-Path -LiteralPath $flowScriptPath)) {
  throw 'run-windows-student-flow.ps1 is missing on the Windows runner checkout.'
}
if (-not (Test-Path -LiteralPath $boundaryScriptPath)) {
  throw 'run-windows-browser-boundary-ci.ps1 is missing on the Windows runner checkout.'
}
if (-not (Test-Path -LiteralPath $resetScriptPath)) {
  throw 'reset-self-hosted-windows-runner.ps1 is missing on the Windows runner checkout.'
}

function Ensure-OpenPathDirectNode {
  if (Get-Command npm.cmd -ErrorAction SilentlyContinue) {
    return
  }

  $nodeRoot = Join-Path $env:TEMP 'openpath-direct-node-v24'
  $npmPath = Join-Path $nodeRoot 'npm.cmd'
  if (-not (Test-Path -LiteralPath $npmPath)) {
    $ProgressPreference = 'SilentlyContinue'
    $global:ProgressPreference = 'SilentlyContinue'
    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing -TimeoutSec 60
    $release = @($index | Where-Object { $_.version -like 'v24.*' -and $_.files -contains 'win-x64-zip' } | Select-Object -First 1)[0]
    if (-not $release -or -not $release.version) {
      throw 'Unable to resolve a Node.js v24 win-x64 zip release for direct runner execution.'
    }

    $version = [string]$release.version
    $zipPath = Join-Path $env:TEMP "openpath-direct-node-$version.zip"
    $extractRoot = Join-Path $env:TEMP "openpath-direct-node-$version"
    $url = "https://nodejs.org/dist/$version/node-$version-win-x64.zip"
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 180
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    $expanded = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
    if (-not $expanded -or -not (Test-Path -LiteralPath (Join-Path $expanded.FullName 'npm.cmd'))) {
      throw 'Downloaded Node.js archive did not contain npm.cmd.'
    }
    Remove-Item -LiteralPath $nodeRoot -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $expanded.FullName -Destination $nodeRoot -Force
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  $env:PATH = "$nodeRoot;$env:PATH"
  if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    throw 'npm.cmd is still unavailable after preparing temporary Node.js.'
  }
}

function Ensure-OpenPathDirectDependencies {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot
  )

  $tscPath = Join-Path $RepoRoot 'node_modules\\.bin\\tsc.cmd'
  $tsxPath = Join-Path $RepoRoot 'node_modules\\tsx\\dist\\cli.mjs'
  if ((Test-Path -LiteralPath $tscPath) -and (Test-Path -LiteralPath $tsxPath)) {
    return
  }

  Set-Location $RepoRoot
  & npm.cmd ci --prefer-offline --no-audit --fund=false | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "npm ci failed with exit code $LASTEXITCODE"
  }
}

function Invoke-OpenPathDirectChildPowerShell {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$ExtraArguments = @(),
    [Parameter(Mandatory = $true)][string]$LogName,
    [int]$TimeoutSeconds = 1800
  )

  $outPath = Join-Path $artifactsRoot "$LogName.out.log"
  $errPath = Join-Path $artifactsRoot "$LogName.err.log"
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ExtraArguments
  $startInfo = @{
    FilePath = 'powershell.exe'
    ArgumentList = $arguments
    WorkingDirectory = $repoRoot
    RedirectStandardOutput = $outPath
    RedirectStandardError = $errPath
    PassThru = $true
  }
  $process = Start-Process @startInfo

  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "$LogName timed out after $TimeoutSeconds seconds"
  }

  $process.Refresh()
  $exitCode = $process.ExitCode
  if ($null -eq $exitCode) {
    $exitCode = 0
  }
  if ($exitCode -ne 0) {
    $maxFailureLogChars = 12000
    $stdout = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw } else { '' }
    if ($stdout.Length -gt $maxFailureLogChars) {
      $stdout = $stdout.Substring($stdout.Length - $maxFailureLogChars)
    }
    if ($stderr.Length -gt $maxFailureLogChars) {
      $stderr = $stderr.Substring($stderr.Length - $maxFailureLogChars)
    }
    throw ($LogName + ' exited with code ' + $exitCode + [Environment]::NewLine + 'STDOUT:' + [Environment]::NewLine + $stdout + [Environment]::NewLine + 'STDERR:' + [Environment]::NewLine + $stderr)
  }
}

$primaryFailure = $null
$exitCode = 0
$errorText = ''
try {
  New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
  Remove-Item -LiteralPath $completionPath -Force -ErrorAction SilentlyContinue
  $env:OPENPATH_STUDENT_ARTIFACTS_DIR = $artifactsRoot
  $env:OPENPATH_WINDOWS_STUDENT_SSE_GROUP = 'path-blocking'
  $env:OPENPATH_KEEP_CLIENT_FOR_BROWSER_BOUNDARY = '1'
  Ensure-OpenPathDirectNode
  Ensure-OpenPathDirectDependencies -RepoRoot $repoRoot
  Set-Location $repoRoot
  Invoke-OpenPathDirectChildPowerShell -ScriptPath $flowScriptPath -LogName 'direct-student-flow' -TimeoutSeconds 2400

  New-Item -ItemType Directory -Path $boundaryArtifactsRoot -Force | Out-Null
  Invoke-OpenPathDirectChildPowerShell -ScriptPath $boundaryScriptPath -ExtraArguments @('-ArtifactsRoot', $boundaryArtifactsRoot) -LogName 'direct-browser-boundary' -TimeoutSeconds 600
}
catch {
  $primaryFailure = $_
  $exitCode = 1
  $errorText = [string]$_
}
finally {
  try {
    Invoke-OpenPathDirectChildPowerShell -ScriptPath $resetScriptPath -LogName 'direct-final-reset' -TimeoutSeconds 300
  }
  catch {
    if ($null -eq $primaryFailure) {
      throw
    }
    Write-Warning "reset-self-hosted-windows-runner.ps1 failed after primary failure: $_"
  }
  [pscustomobject]@{
    exitCode = $exitCode
    error = $errorText
    artifactsRoot = $artifactsRoot
    boundaryArtifactsRoot = $boundaryArtifactsRoot
    timestamp = (Get-Date).ToString('o')
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $completionPath -Encoding UTF8
}

if ($exitCode -ne 0) {
  exit $exitCode
}
`;
  runGuestPowerShellDetached(options, script, {
    label: 'Run Windows student-policy flow and browser boundary CI',
  });
  const completion = waitForGuestCompletionFile(options, completionPath, {
    timeoutSeconds: 3000,
  });
  if (completion.exitCode !== 0) {
    throw new Error(
      `Run Windows student-policy flow and browser boundary CI failed: ${
        completion.error ?? 'unknown error'
      }`
    );
  }
}

function runWindowsDnsDiscoverySpike(options, runnerRepoRoot) {
  const spikeScriptPath = `${runnerRepoRoot}\\tests\\e2e\\ci\\run-windows-dns-discovery-spike.ps1`;
  const artifactsRoot = `${runnerRepoRoot}\\tests\\e2e\\artifacts\\windows-dns-discovery-spike`;
  const completionPath = `${artifactsRoot}\\direct-dns-discovery-spike-completion.json`;
  const timeoutSeconds = Number.parseInt(options.timeoutSeconds, 10);
  const script = `
$ErrorActionPreference = 'Stop'
$repoRoot = ${JSON.stringify(runnerRepoRoot)}
$spikeScriptPath = ${JSON.stringify(spikeScriptPath)}
$artifactsRoot = ${JSON.stringify(artifactsRoot)}
$completionPath = ${JSON.stringify(completionPath)}

if (-not (Test-Path -LiteralPath $spikeScriptPath)) {
  throw 'run-windows-dns-discovery-spike.ps1 is missing on the Windows runner checkout.'
}

function Ensure-OpenPathDirectNode {
  if (Get-Command npm.cmd -ErrorAction SilentlyContinue) {
    return
  }

  $nodeRoot = Join-Path $env:TEMP 'openpath-direct-node-v24'
  $npmPath = Join-Path $nodeRoot 'npm.cmd'
  if (-not (Test-Path -LiteralPath $npmPath)) {
    $ProgressPreference = 'SilentlyContinue'
    $global:ProgressPreference = 'SilentlyContinue'
    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing -TimeoutSec 60
    $release = @($index | Where-Object { $_.version -like 'v24.*' -and $_.files -contains 'win-x64-zip' } | Select-Object -First 1)[0]
    if (-not $release -or -not $release.version) {
      throw 'Unable to resolve a Node.js v24 win-x64 zip release for direct runner execution.'
    }

    $version = [string]$release.version
    $zipPath = Join-Path $env:TEMP "openpath-direct-node-$version.zip"
    $extractRoot = Join-Path $env:TEMP "openpath-direct-node-$version"
    $url = "https://nodejs.org/dist/$version/node-$version-win-x64.zip"
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 180
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    $expanded = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
    if (-not $expanded -or -not (Test-Path -LiteralPath (Join-Path $expanded.FullName 'npm.cmd'))) {
      throw 'Downloaded Node.js archive did not contain npm.cmd.'
    }
    Remove-Item -LiteralPath $nodeRoot -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $expanded.FullName -Destination $nodeRoot -Force
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  $env:PATH = "$nodeRoot;$env:PATH"
  if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    throw 'npm.cmd is still unavailable after preparing temporary Node.js.'
  }
}

function Ensure-OpenPathDirectDependencies {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot
  )

  $tscPath = Join-Path $RepoRoot 'node_modules\\.bin\\tsc.cmd'
  $tsxPath = Join-Path $RepoRoot 'node_modules\\tsx\\dist\\cli.mjs'
  if ((Test-Path -LiteralPath $tscPath) -and (Test-Path -LiteralPath $tsxPath)) {
    return
  }

  Set-Location $RepoRoot
  & npm.cmd ci --prefer-offline --no-audit --fund=false | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "npm ci failed with exit code $LASTEXITCODE"
  }
}

function Invoke-OpenPathDirectChildPowerShell {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$ExtraArguments = @(),
    [Parameter(Mandatory = $true)][string]$LogName,
    [int]$TimeoutSeconds = 1800
  )

  $outPath = Join-Path $artifactsRoot "$LogName.out.log"
  $errPath = Join-Path $artifactsRoot "$LogName.err.log"
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ExtraArguments
  $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $repoRoot -RedirectStandardOutput $outPath -RedirectStandardError $errPath -PassThru

  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "$LogName timed out after $TimeoutSeconds seconds"
  }

  $process.Refresh()
  $exitCode = $process.ExitCode
  if ($null -eq $exitCode) {
    $exitCode = 0
  }
  if ($exitCode -ne 0) {
    $maxFailureLogChars = 12000
    $stdout = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw } else { '' }
    if ($stdout.Length -gt $maxFailureLogChars) {
      $stdout = $stdout.Substring($stdout.Length - $maxFailureLogChars)
    }
    if ($stderr.Length -gt $maxFailureLogChars) {
      $stderr = $stderr.Substring($stderr.Length - $maxFailureLogChars)
    }
    throw ($LogName + ' exited with code ' + $exitCode + [Environment]::NewLine + 'STDOUT:' + [Environment]::NewLine + $stdout + [Environment]::NewLine + 'STDERR:' + [Environment]::NewLine + $stderr)
  }
}

$primaryFailure = $null
$exitCode = 0
$errorText = ''
try {
  New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
  Remove-Item -LiteralPath $completionPath -Force -ErrorAction SilentlyContinue
  Ensure-OpenPathDirectNode
  Ensure-OpenPathDirectDependencies -RepoRoot $repoRoot
  Set-Location $repoRoot
  Invoke-OpenPathDirectChildPowerShell -ScriptPath $spikeScriptPath -ExtraArguments @('-Mode', 'Run', '-ArtifactsRoot', $artifactsRoot) -LogName 'direct-dns-discovery-spike' -TimeoutSeconds ${timeoutSeconds}
  $resultPath = Join-Path $artifactsRoot 'dns-discovery-spike-result.json'
  if (-not (Test-Path -LiteralPath $resultPath)) {
    throw "DNS discovery spike result was not written: $resultPath"
  }
}
catch {
  $primaryFailure = $_
  $exitCode = 1
  $errorText = [string]$_
}
finally {
  [pscustomobject]@{
    exitCode = $exitCode
    error = $errorText
    artifactsRoot = $artifactsRoot
    resultPath = (Join-Path $artifactsRoot 'dns-discovery-spike-result.json')
    timestamp = (Get-Date).ToString('o')
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $completionPath -Encoding UTF8
}

if ($exitCode -ne 0) {
  exit $exitCode
}
`;
  runGuestPowerShellDetached(options, script, {
    label: 'Run Windows DNS discovery spike',
  });
  const completion = waitForGuestCompletionFile(options, completionPath, {
    timeoutSeconds: timeoutSeconds + 900,
  });
  if (completion.exitCode !== 0) {
    throw new Error(
      `Run Windows DNS discovery spike failed: ${completion.error ?? 'unknown error'}`
    );
  }
}

function runBrowserBoundaryCi(options, runnerRepoRoot) {
  const boundaryScriptPath = `${runnerRepoRoot}\\tests\\e2e\\ci\\run-windows-browser-boundary-ci.ps1`;
  const artifactsRoot = `${runnerRepoRoot}\\tests\\e2e\\artifacts\\windows-student-policy\\browser-boundary`;
  const script = `
$ErrorActionPreference = 'Stop'
$repoRoot = ${JSON.stringify(runnerRepoRoot)}
$boundaryScriptPath = ${JSON.stringify(boundaryScriptPath)}
$artifactsRoot = ${JSON.stringify(artifactsRoot)}

if (-not (Test-Path -LiteralPath $boundaryScriptPath)) {
  throw 'run-windows-browser-boundary-ci.ps1 is missing on the Windows runner checkout.'
}

New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
Set-Location $repoRoot
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $boundaryScriptPath -ArtifactsRoot $artifactsRoot
if ($LASTEXITCODE -ne 0) {
  throw "run-windows-browser-boundary-ci.ps1 exited with code $LASTEXITCODE"
}
`;
  runGuestPowerShell(options, script, {
    timeoutSeconds: 600,
    label: 'Run Windows browser boundary CI',
  });
}

function readGuestFile(options, sourcePath, maxChars = 500000) {
  const script = `
$ErrorActionPreference = 'Stop'
$path = ${JSON.stringify(sourcePath)}
if (-not (Test-Path -LiteralPath $path)) { exit 0 }
$content = Get-Content -LiteralPath $path -Raw
if ($content.Length -gt ${maxChars}) {
  $content.Substring($content.Length - ${maxChars})
} else {
  $content
}
`;
  return runGuestPowerShell(options, script, {
    timeoutSeconds: 120,
    label: `Read Windows artifact ${sourcePath}`,
  });
}

function collectArtifacts(options, artifactDir, runnerRoot) {
  const resultsContent = readGuestFile(
    options,
    `${runnerRoot}\\${options.resultsPath.replace(/\//g, '\\')}`
  );
  if (resultsContent.trim()) {
    writeFileSync(resolve(artifactDir, DEFAULT_RESULTS_ARTIFACT_NAME), resultsContent, 'utf8');
  }

  const runnerLog = readGuestFile(
    options,
    `${runnerRoot}\\tests\\e2e\\artifacts\\windows-student-policy\\windows-student-policy-trace.log`,
    120000
  );
  if (runnerLog.trim()) {
    writeFileSync(resolve(artifactDir, DEFAULT_ARTIFACT_LOG_NAME), runnerLog, 'utf8');
  }

  for (const artifactName of BROWSER_ENFORCEMENT_ARTIFACTS) {
    const localArtifactName = artifactName.replace(/\\/g, '-');
    const content = readGuestFile(
      options,
      `${runnerRoot}\\tests\\e2e\\artifacts\\windows-student-policy\\browser-boundary\\${artifactName}`,
      500000
    );
    if (content.trim()) {
      writeFileSync(resolve(artifactDir, localArtifactName), content, 'utf8');
    }
  }

  for (const artifactName of BROWSER_ENFORCEMENT_REPORT_ARTIFACTS) {
    const content = readGuestFile(
      options,
      `${runnerRoot}\\tests\\e2e\\artifacts\\windows-browser-enforcement\\${artifactName}`,
      500000
    );
    if (content.trim()) {
      writeFileSync(resolve(artifactDir, artifactName), content, 'utf8');
    }
  }

  for (const artifactName of DNS_DISCOVERY_SPIKE_ARTIFACTS) {
    const content = readGuestFile(
      options,
      `${runnerRoot}\\tests\\e2e\\artifacts\\windows-dns-discovery-spike\\${artifactName}`,
      500000
    );
    if (content.trim()) {
      writeFileSync(resolve(artifactDir, artifactName), content, 'utf8');
    }
  }
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    printUsage();
    process.exit(1);
  }

  const artifactDir =
    options.artifactDir ||
    resolve(
      projectRoot,
      '.opencode/tmp/openpath-windows-direct',
      new Date().toISOString().replace(/[:.]/g, '-')
    );

  console.log(`artifact_dir=${artifactDir}`);
  console.log(
    `proxmox_guest_agent=ssh ${options.proxmoxHost} qm guest exec ${options.vmid} -- powershell.exe`
  );
  console.log(`source_mode=${options.sourceMode}`);
  console.log(`mode=${options.mode}`);
  console.log(`runner_repo_root=${options.runnerRepoRoot || '<auto-detect-on-runner>'}`);
  console.log(
    `browser_enforcement_report=${options.browserEnforcementReport ? 'enabled' : 'disabled'}`
  );
  if (options.sourceMode === 'local-overlay') {
    console.log(`overlay_host=${options.overlayHost || '<auto-detect-from-guest-route>'}`);
  }

  if (!DRY_RUN) {
    mkdirSync(artifactDir, { recursive: true });
  }

  let overlayServer;
  let windowsOverlayRoot = '';
  let runnerRepoRoot = DRY_RUN ? options.runnerRepoRoot || '' : '';

  try {
    if (options.sourceMode === 'local-overlay') {
      if (DRY_RUN) {
        console.log(
          `git archive --format=zip --output ${resolve(artifactDir, OVERLAY_ZIP_NAME)} HEAD`
        );
        console.log(
          'Invoke-WebRequest -Uri http://<overlay-host>:<port>/openpath-local-overlay.zip -OutFile <temp-zip>'
        );
        console.log(
          'Expand-Archive -LiteralPath <temp-zip> -DestinationPath %TEMP%\\openpath-direct-overlay-<guid> -Force'
        );
        runnerRepoRoot = options.runnerRepoRoot || '%TEMP%\\openpath-direct-overlay-<guid>';
      } else {
        console.log('step=create-local-overlay-archive');
        const overlayZipPath = createLocalOverlayArchive(artifactDir);
        console.log('step=detect-windows-guest-ip');
        const guestIp = getWindowsGuestIPv4(options);
        console.log('step=start-local-overlay-server');
        const overlayHost = options.overlayHost || detectOverlayHostForGuest(guestIp);
        const startedServer = await startOverlayServer(overlayZipPath, overlayHost);
        overlayServer = startedServer.process;
        console.log(`overlay_url=${startedServer.url}`);
        console.log('step=prepare-local-overlay-on-windows');
        windowsOverlayRoot = prepareLocalOverlayOnWindows(options, startedServer.url);
        runnerRepoRoot = windowsOverlayRoot;
      }
    } else {
      runnerRepoRoot = DRY_RUN
        ? options.runnerRepoRoot || ''
        : resolveWindowsRunnerRepoRoot(options);
    }

    console.log('step=check-windows-runner-baseline');
    ensureWindowsRunnerBaseline(options, runnerRepoRoot || options.runnerRepoRoot);
    console.log('step=reset-windows-runner');
    resetWindowsRunner(options, runnerRepoRoot || options.runnerRepoRoot);
    if (options.mode === 'pester' || options.mode === 'all') {
      console.log('step=run-direct-pester');
      runDirectPester(options, runnerRepoRoot || options.runnerRepoRoot);
    }
    if (options.mode === 'browser-boundary' || options.mode === 'all') {
      console.log('step=run-windows-student-policy-flow-for-browser-boundary');
      runWindowsStudentPolicyFlowForBoundary(options, runnerRepoRoot || options.runnerRepoRoot);
    }
    if (options.mode === 'dns-discovery-spike' || options.mode === 'all') {
      console.log('step=run-windows-dns-discovery-spike');
      runWindowsDnsDiscoverySpike(options, runnerRepoRoot || options.runnerRepoRoot);
    }
    if (options.browserEnforcementReport) {
      console.log('step=run-browser-enforcement-report');
      runBrowserEnforcementReport(options, runnerRepoRoot || options.runnerRepoRoot);
    }
  } finally {
    if (!DRY_RUN && runnerRepoRoot) {
      try {
        collectArtifacts(options, artifactDir, runnerRepoRoot);
      } catch (error) {
        console.warn(
          `warning: failed to collect Windows direct artifacts: ${
            error instanceof Error ? error.message : String(error)
          }`
        );
      }
    }
    try {
      cleanupWindowsOverlay(options, windowsOverlayRoot);
    } catch (error) {
      console.warn(
        `warning: failed to clean Windows overlay: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }
    await stopOverlayServer(overlayServer);
    if (!DRY_RUN && options.sourceMode === 'local-overlay') {
      rmSync(resolve(artifactDir, OVERLAY_ZIP_NAME), { force: true });
    }
  }

  console.log(`direct OpenPath Windows runner diagnostic complete: ${artifactDir}`);
}

const isDirectExecution = process.argv[1] ? resolve(process.argv[1]) === currentFilePath : false;

if (isDirectExecution) {
  try {
    await main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}

export { extractUsableGuestIPv4, parseRunnerRepoRootCandidates, selectPreferredRunnerRepoRoot };
