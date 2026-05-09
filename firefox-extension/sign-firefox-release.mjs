#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash, createHmac, randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { prepareFirefoxReleaseArtifacts } from './build-firefox-release.mjs';
import { assertFirefoxAmoSignedXpi } from './xpi-signature-evidence.mjs';

const __filename = fileURLToPath(import.meta.url);
const extensionRoot = path.dirname(__filename);
const defaultArtifactsDir = path.join(extensionRoot, 'build', 'firefox-release-signing');
const firefoxReleaseSourceEntries = ['manifest.json', 'dist', 'popup', 'blocked', 'icons'];
const defaultWebExtSignMaxRetries = 2;
const defaultWebExtSignRetryBufferSeconds = 10;
const defaultWebExtSignMaxThrottleWaitSeconds = 900;
const defaultWebExtSignApprovalTimeoutSeconds = 7200;
const defaultWebExtSignRequestTimeoutSeconds = 120;
const defaultWebExtSignProcessTimeoutBufferSeconds = 120;
const defaultWebExtSignRecoveryTimeoutSeconds = 7200;
const defaultWebExtSignRecoveryPollSeconds = 60;
const defaultAmoBaseUrl = 'https://addons.mozilla.org/api/v5/';
const amoVersionComponentModulo = 1_000_000_000n;
const amoSigningStateArtifactName = 'amo-signing-state.json';

function fail(message) {
  throw new Error(message);
}

export function buildWebExtSignArgs(options) {
  const {
    apiKey,
    apiSecret,
    artifactsDir,
    sourceDir = extensionRoot,
    approvalTimeoutMs,
    requestTimeoutMs,
    uploadSourceCode,
    amoMetadata,
  } = options;

  if (!apiKey) {
    fail('WEB_EXT_API_KEY is required');
  }
  if (!apiSecret) {
    fail('WEB_EXT_API_SECRET is required');
  }

  const args = [
    '--yes',
    '--no-install',
    'web-ext',
    'sign',
    '--channel=unlisted',
    `--source-dir=${sourceDir}`,
    `--artifacts-dir=${artifactsDir}`,
    `--api-key=${apiKey}`,
    `--api-secret=${apiSecret}`,
  ];

  if (Number.isFinite(approvalTimeoutMs) && approvalTimeoutMs >= 0) {
    args.push(`--approval-timeout=${approvalTimeoutMs}`);
  }
  if (Number.isFinite(requestTimeoutMs) && requestTimeoutMs > 0) {
    args.push(`--timeout=${requestTimeoutMs}`);
  }
  if (uploadSourceCode) {
    args.push(`--upload-source-code=${uploadSourceCode}`);
  }
  if (amoMetadata) {
    args.push(`--amo-metadata=${amoMetadata}`);
  }

  return args;
}

function parseNonNegativeInteger(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function formatTimeoutMs(timeoutMs) {
  return timeoutMs === undefined ? 'disabled' : String(timeoutMs);
}

export function writeAmoSigningStateArtifact(options) {
  const {
    artifactsDir,
    state,
    addonId = '',
    version = '',
    versionId = '',
    fileStatus = '',
    lastPollAt = new Date().toISOString(),
    message = '',
  } = options;
  fs.mkdirSync(artifactsDir, { recursive: true });
  const artifactPath = path.join(artifactsDir, amoSigningStateArtifactName);
  const artifact = {
    state,
    addonId,
    version,
    versionId,
    fileStatus,
    lastPollAt,
  };

  if (message) {
    artifact.message = message;
  }

  fs.writeFileSync(artifactPath, `${JSON.stringify(artifact, null, 2)}\n`);
  return { artifactPath, artifact };
}

export function resolveWebExtSignTiming(options = {}) {
  const { env = process.env, nowMs = Date.now() } = options;
  const totalTimeoutSeconds = parseNonNegativeInteger(env.WEB_EXT_SIGN_TOTAL_TIMEOUT_SECONDS, 0);
  const totalTimeoutMs = totalTimeoutSeconds > 0 ? totalTimeoutSeconds * 1000 : undefined;
  const approvalTimeoutMs =
    parseNonNegativeInteger(
      env.WEB_EXT_SIGN_APPROVAL_TIMEOUT_SECONDS,
      defaultWebExtSignApprovalTimeoutSeconds
    ) * 1000;
  const requestTimeoutMs =
    parseNonNegativeInteger(
      env.WEB_EXT_SIGN_REQUEST_TIMEOUT_SECONDS,
      defaultWebExtSignRequestTimeoutSeconds
    ) * 1000;
  const processTimeoutBufferMs =
    parseNonNegativeInteger(
      env.WEB_EXT_SIGN_PROCESS_TIMEOUT_BUFFER_SECONDS,
      defaultWebExtSignProcessTimeoutBufferSeconds
    ) * 1000;
  const processTimeoutMs =
    approvalTimeoutMs > 0 ? approvalTimeoutMs + processTimeoutBufferMs : totalTimeoutMs;
  const deadlineMs = totalTimeoutMs === undefined ? undefined : nowMs + totalTimeoutMs;

  return {
    totalTimeoutMs,
    approvalTimeoutMs,
    requestTimeoutMs,
    processTimeoutBufferMs,
    processTimeoutMs,
    deadlineMs,
  };
}

export function resolveAmoRecoveryTiming(options = {}) {
  const { env = process.env, deadlineMs, nowMs = Date.now() } = options;
  const configuredTimeoutMs =
    parseNonNegativeInteger(
      env.WEB_EXT_SIGN_RECOVERY_TIMEOUT_SECONDS,
      defaultWebExtSignRecoveryTimeoutSeconds
    ) * 1000;
  const pollIntervalMs =
    parseNonNegativeInteger(
      env.WEB_EXT_SIGN_RECOVERY_POLL_SECONDS,
      defaultWebExtSignRecoveryPollSeconds
    ) * 1000;

  if (configuredTimeoutMs === 0) {
    fail('AMO signed XPI recovery is disabled by WEB_EXT_SIGN_RECOVERY_TIMEOUT_SECONDS=0');
  }

  if (deadlineMs === undefined) {
    return {
      timeoutMs: configuredTimeoutMs,
      pollIntervalMs,
      remainingTotalMs: undefined,
    };
  }

  const remainingTotalMs = deadlineMs - nowMs;
  if (remainingTotalMs <= 0) {
    fail(
      `AMO signing exhausted total timeout before signed XPI recovery could start deadlineMs=${deadlineMs} nowMs=${nowMs}`
    );
  }

  return {
    timeoutMs: Math.min(configuredTimeoutMs, remainingTotalMs),
    pollIntervalMs,
    remainingTotalMs,
  };
}

export function parseWebExtThrottleDelaySeconds(output) {
  const match = /Expected available in\s+(\d+)\s+seconds?/i.exec(output);
  return match ? Number.parseInt(match[1], 10) : null;
}

export function parseAmoVersionEditUrl(output) {
  const match =
    /https:\/\/addons\.mozilla\.org\/[^\s"'<>]+\/developers\/addon\/([^/\s"'<>]+)\/versions\/(\d+)/i.exec(
      output
    );

  if (!match) {
    return null;
  }

  const editUrl = (match[0] ?? '').replace(/[),.;]+$/, '');
  return {
    addonId: decodeURIComponent(match[1] ?? ''),
    versionId: match[2] ?? '',
    editUrl,
  };
}

export function isAmoApprovalTimeout(output) {
  return /Approval:\s*timeout exceeded/i.test(output);
}

export function isAmoVersionAlreadyExists(output) {
  return /Version(?:\s+[\dA-Za-z._-]+)?\s+already exists/i.test(output);
}

export function resolveAmoSigningFailureState(status) {
  return status === 124 ? 'timeout' : 'hard-failure';
}

function normalizeAmoBaseUrl(amoBaseUrl = defaultAmoBaseUrl) {
  const baseUrl = new URL(amoBaseUrl);
  if (!baseUrl.pathname.endsWith('/')) {
    baseUrl.pathname += '/';
  }
  return baseUrl;
}

export function buildAmoVersionDetailUrl(options) {
  const { amoBaseUrl = defaultAmoBaseUrl, addonId, versionId = '', version = '' } = options;
  const versionLookup = versionId.trim() || `v${version.trim()}`;

  if (!addonId?.trim()) {
    fail('AMO addon id is required for signed XPI recovery');
  }
  if (!versionLookup || versionLookup === 'v') {
    fail('AMO version id or version is required for signed XPI recovery');
  }

  return new URL(
    `addons/addon/${encodeURIComponent(addonId.trim())}/versions/${encodeURIComponent(
      versionLookup
    )}/`,
    normalizeAmoBaseUrl(amoBaseUrl)
  );
}

function base64UrlJson(value) {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
}

export function createAmoJwt(options) {
  const { apiKey, apiSecret, nowMs = Date.now(), jti = randomUUID() } = options;
  const issuedAtSeconds = Math.floor(nowMs / 1000);
  const header = base64UrlJson({ alg: 'HS256', typ: 'JWT' });
  const payload = base64UrlJson({
    iss: apiKey,
    jti,
    iat: issuedAtSeconds,
    exp: issuedAtSeconds + 300,
  });
  const signature = createHmac('sha256', apiSecret)
    .update(`${header}.${payload}`)
    .digest('base64url');

  return `${header}.${payload}.${signature}`;
}

function buildAmoAuthHeaders(options) {
  const { apiKey, apiSecret } = options;
  return {
    Authorization: `JWT ${createAmoJwt({ apiKey, apiSecret })}`,
    Accept: 'application/json',
    'User-Agent': `openpath-firefox-release/${readDeclaredWebExtVersion()}`,
  };
}

async function fetchAmoJson(options) {
  const { url, apiKey, apiSecret, fetchImpl = fetch } = options;
  const response = await fetchImpl(url, {
    method: 'GET',
    headers: buildAmoAuthHeaders({ apiKey, apiSecret }),
  });
  const text = await response.text();
  const data = text ? JSON.parse(text) : {};

  if (!response.ok) {
    fail(`AMO request failed: ${response.status} ${response.statusText} ${text}`.trim());
  }

  return data;
}

async function downloadAmoSignedXpi(options) {
  const { fileUrl, apiKey, apiSecret, artifactsDir, fetchImpl = fetch } = options;
  fs.mkdirSync(artifactsDir, { recursive: true });

  const url = new URL(fileUrl);
  const filename = path.basename(url.pathname) || 'openpath-firefox-extension.xpi';
  const outputPath = path.join(
    artifactsDir,
    filename.endsWith('.xpi') ? filename : `${filename}.xpi`
  );
  const response = await fetchImpl(url, {
    method: 'GET',
    headers: buildAmoAuthHeaders({ apiKey, apiSecret }),
  });

  if (!response.ok) {
    fail(`AMO signed XPI download failed: ${response.status} ${response.statusText}`.trim());
  }

  fs.writeFileSync(outputPath, Buffer.from(await response.arrayBuffer()));
  assertFirefoxAmoSignedXpi(outputPath);
  return outputPath;
}

async function sleep(milliseconds) {
  if (milliseconds <= 0) {
    return;
  }
  await new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

export async function waitForAmoSignedXpi(options) {
  const {
    apiKey,
    apiSecret,
    addonId,
    versionId = '',
    version = '',
    artifactsDir,
    amoBaseUrl = defaultAmoBaseUrl,
    timeoutMs,
    pollIntervalMs,
    fetchImpl = fetch,
    sleepImpl = sleep,
    nowImpl = Date.now,
    stdout = process.stdout,
  } = options;
  const versionUrl = buildAmoVersionDetailUrl({ amoBaseUrl, addonId, versionId, version });
  const deadline = nowImpl() + timeoutMs;
  let attempt = 0;
  let lastFileStatus = 'missing';
  let lastPollAt = '';
  let resolvedVersion = version;
  let resolvedVersionId = versionId;

  while (true) {
    attempt += 1;
    const detail = await fetchAmoJson({
      url: versionUrl,
      apiKey,
      apiSecret,
      fetchImpl,
    });
    const fileStatus = detail?.file?.status ?? 'missing';
    const fileUrl = detail?.file?.url ?? '';
    lastFileStatus = fileStatus;
    lastPollAt = new Date(nowImpl()).toISOString();
    resolvedVersion = String(detail?.version ?? resolvedVersion ?? '');
    resolvedVersionId = String(detail?.id ?? resolvedVersionId ?? '');

    stdout.write(
      [
        '[sign:firefox-release] AMO version status',
        `addonId=${addonId}`,
        versionId ? `versionId=${versionId}` : `version=${version}`,
        `fileStatus=${fileStatus}`,
        `attempt=${attempt}`,
      ].join(' ') + '\n'
    );

    if (fileUrl && (fileStatus === 'public' || fileStatus === 'unreviewed')) {
      const signedXpiPath = await downloadAmoSignedXpi({
        fileUrl,
        apiKey,
        apiSecret,
        artifactsDir,
        fetchImpl,
      });
      stdout.write(`[sign:firefox-release] Downloaded AMO signed XPI ${signedXpiPath}\n`);
      return signedXpiPath;
    }

    if (fileStatus === 'disabled') {
      fail(`AMO version ${versionId || version} is disabled and cannot be recovered`);
    }

    const remainingMs = deadline - nowImpl();
    if (remainingMs <= 0) {
      if (lastFileStatus === 'unreviewed') {
        const message = `manual-review-required: AMO accepted version but fileStatus=unreviewed until recovery timeout addonId=${addonId} version=${
          resolvedVersionId || resolvedVersion || versionId || version
        }`;
        const { artifactPath } = writeAmoSigningStateArtifact({
          artifactsDir,
          state: 'manual-review-required',
          addonId,
          version: resolvedVersion,
          versionId: resolvedVersionId,
          fileStatus: lastFileStatus,
          lastPollAt,
          message,
        });
        stdout.write(
          `[sign:firefox-release] ${message} artifact=${path.relative(
            extensionRoot,
            artifactPath
          )}\n`
        );
        fail(message);
      }

      fail(
        `Timed out waiting for AMO signed XPI addonId=${addonId} version=${
          versionId || version
        } lastStatus=${lastFileStatus}`
      );
    }

    await sleepImpl(Math.min(pollIntervalMs, remainingMs));
  }
}

function readFirefoxExtensionId(sourceDir) {
  const manifest = readManifest(path.join(sourceDir, 'manifest.json'));
  const extensionId =
    manifest.browser_specific_settings?.gecko?.id ?? manifest.applications?.gecko?.id ?? '';

  if (!extensionId) {
    fail(`manifest.json at ${sourceDir} must define browser_specific_settings.gecko.id`);
  }

  return String(extensionId);
}

function sleepSync(milliseconds) {
  if (milliseconds <= 0) {
    return;
  }

  const waitBuffer = new SharedArrayBuffer(4);
  const waitArray = new Int32Array(waitBuffer);
  Atomics.wait(waitArray, 0, 0, milliseconds);
}

function readVersionFromSignArgs(args) {
  const sourceDirArg = args.find((arg) => arg.startsWith('--source-dir='));
  const sourceDir = sourceDirArg ? sourceDirArg.slice('--source-dir='.length) : '';
  if (!sourceDir) {
    return 'unknown';
  }

  try {
    const manifest = readManifest(path.join(sourceDir, 'manifest.json'));
    return typeof manifest.version === 'string' && manifest.version.trim()
      ? manifest.version.trim()
      : 'unknown';
  } catch {
    return 'unknown';
  }
}

export function runWebExtSignWithRetry(options) {
  const {
    args,
    cwd,
    env = process.env,
    spawnSyncImpl = spawnSync,
    sleepSyncImpl = sleepSync,
    nowImpl = Date.now,
    stdout = process.stdout,
    stderr = process.stderr,
    processTimeoutMs,
    deadlineMs,
  } = options;
  const maxRetries = parseNonNegativeInteger(
    env.WEB_EXT_SIGN_MAX_RETRIES,
    defaultWebExtSignMaxRetries
  );
  const retryBufferSeconds = parseNonNegativeInteger(
    env.WEB_EXT_SIGN_RETRY_BUFFER_SECONDS,
    defaultWebExtSignRetryBufferSeconds
  );
  const maxThrottleWaitSeconds = parseNonNegativeInteger(
    env.WEB_EXT_SIGN_MAX_THROTTLE_WAIT_SECONDS,
    defaultWebExtSignMaxThrottleWaitSeconds
  );

  for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
    const remainingTotalMs = deadlineMs === undefined ? undefined : deadlineMs - nowImpl();
    if (remainingTotalMs !== undefined && remainingTotalMs <= 0) {
      stderr.write(
        `[sign:firefox-release] AMO signing exhausted the total timeout before web-ext sign could finish deadlineMs=${deadlineMs}\n`
      );
      return {
        status: 124,
      };
    }
    const attemptTimeoutMs =
      remainingTotalMs === undefined || processTimeoutMs === undefined
        ? processTimeoutMs
        : Math.min(processTimeoutMs, remainingTotalMs);
    const result = spawnSyncImpl('npx', args, {
      cwd,
      encoding: 'utf8',
      timeout: attemptTimeoutMs,
    });
    const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;

    if (result.stdout) {
      stdout.write(result.stdout);
    }
    if (result.stderr) {
      stderr.write(result.stderr);
    }

    if (result.status === 0) {
      return result;
    }

    if (result.error && result.error.code === 'ETIMEDOUT') {
      stderr.write(
        `[sign:firefox-release] web-ext sign exceeded the parent process timeout of ${processTimeoutMs}ms\n`
      );
      return {
        ...result,
        status: 124,
      };
    }

    const throttleDelaySeconds = parseWebExtThrottleDelaySeconds(output);
    const retriesRemaining = attempt < maxRetries;
    const canWait = throttleDelaySeconds !== null && throttleDelaySeconds <= maxThrottleWaitSeconds;

    if (!retriesRemaining || !canWait) {
      if (throttleDelaySeconds !== null) {
        stderr.write(
          [
            '[sign:firefox-release] AMO signing request was throttled',
            `for ${throttleDelaySeconds} seconds`,
            `(${(throttleDelaySeconds / 60).toFixed(1)} minutes)`,
            `version=${readVersionFromSignArgs(args)}`,
            `maxThrottleWaitSeconds=${maxThrottleWaitSeconds}`,
            `retriesRemaining=${retriesRemaining}`,
          ].join(' ') + '\n'
        );
      }
      return result;
    }

    const waitSeconds = throttleDelaySeconds + retryBufferSeconds;
    const waitMs = waitSeconds * 1000;
    const postAttemptRemainingMs = deadlineMs === undefined ? undefined : deadlineMs - nowImpl();
    if (postAttemptRemainingMs !== undefined && waitMs >= postAttemptRemainingMs) {
      stderr.write(
        `[sign:firefox-release] AMO signing exhausted total timeout before retry wait could complete waitMs=${waitMs} remainingMs=${postAttemptRemainingMs}\n`
      );
      return {
        status: 124,
      };
    }
    console.warn(
      `[sign:firefox-release] AMO signing request was throttled; retrying in ${waitSeconds} seconds`
    );
    sleepSyncImpl(waitMs);
  }

  return { status: 1 };
}

export function findSignedXpiArtifact(artifactsDir) {
  const resolvedDir = path.resolve(artifactsDir);
  if (!fs.existsSync(resolvedDir)) {
    fail(`web-ext artifacts directory not found: ${resolvedDir}`);
  }

  const xpiFiles = fs
    .readdirSync(resolvedDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.xpi'))
    .map((entry) => path.join(resolvedDir, entry.name))
    .sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs);

  if (xpiFiles.length === 0) {
    fail(`web-ext did not produce a signed XPI in ${resolvedDir}`);
  }

  return xpiFiles[0];
}

function readManifest(manifestPath) {
  if (!fs.existsSync(manifestPath)) {
    fail(`manifest.json not found at ${manifestPath}`);
  }

  return JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
}

function readDeclaredWebExtVersion() {
  try {
    const packageJson = JSON.parse(
      fs.readFileSync(path.join(extensionRoot, 'package.json'), 'utf8')
    );
    return packageJson.devDependencies?.['web-ext'] ?? 'unknown';
  } catch {
    return 'unknown';
  }
}

function walkFiles(rootDir, relativeRoot = '') {
  const absoluteRoot = path.join(rootDir, relativeRoot);
  const entries = fs
    .readdirSync(absoluteRoot, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name));
  const files = [];

  for (const entry of entries) {
    const relativePath = path.posix.join(
      relativeRoot.split(path.sep).join(path.posix.sep),
      entry.name
    );
    const absolutePath = path.join(rootDir, relativePath);

    if (entry.isDirectory()) {
      files.push(...walkFiles(rootDir, relativePath));
      continue;
    }

    if (entry.isFile()) {
      files.push(relativePath);
    }
  }

  return files;
}

function listFirefoxReleasePayloadFiles(sourceDir) {
  const resolvedSourceDir = path.resolve(sourceDir);
  const files = [];

  for (const entry of firefoxReleaseSourceEntries) {
    const absolutePath = path.join(resolvedSourceDir, entry);

    if (!fs.existsSync(absolutePath)) {
      fail(`Firefox release payload entry missing: ${entry}`);
    }

    const stat = fs.statSync(absolutePath);
    if (stat.isDirectory()) {
      files.push(...walkFiles(resolvedSourceDir, entry));
    } else if (stat.isFile()) {
      files.push(entry);
    } else {
      fail(`Firefox release payload entry is not a file or directory: ${entry}`);
    }
  }

  return files.sort();
}

export function computeFirefoxReleasePayloadHash(options = {}) {
  const { sourceDir = extensionRoot } = options;
  const resolvedSourceDir = path.resolve(sourceDir);
  const hash = createHash('sha256');

  for (const relativePath of listFirefoxReleasePayloadFiles(resolvedSourceDir)) {
    const normalizedPath = relativePath.split(path.sep).join(path.posix.sep);
    hash.update('file\0');
    hash.update(normalizedPath);
    hash.update('\0');
    hash.update(fs.readFileSync(path.join(resolvedSourceDir, relativePath)));
    hash.update('\0');
  }

  return hash.digest('hex');
}

export function deriveAmoVersionFromPayloadHash(payloadHash) {
  const normalizedHash = String(payloadHash ?? '')
    .trim()
    .toLowerCase();

  if (!/^[a-f0-9]{64}$/.test(normalizedHash)) {
    fail('Firefox Release payload hash must be a 64-character SHA-256 hex string');
  }

  const majorComponent = Number(
    BigInt(`0x${normalizedHash.slice(0, 8)}`) % amoVersionComponentModulo
  );
  const patchComponent = Number(
    BigInt(`0x${normalizedHash.slice(8, 16)}`) % amoVersionComponentModulo
  );

  return `2.0.${majorComponent}.${patchComponent}`;
}

function prepareFirefoxReleaseSourceDir(sourceDir) {
  const resolvedSourceDir = path.resolve(sourceDir);
  const tempSourceDir = fs.mkdtempSync(path.join(tmpdir(), 'openpath-firefox-sign-'));

  try {
    for (const entry of firefoxReleaseSourceEntries) {
      const sourcePath = path.join(resolvedSourceDir, entry);
      if (!fs.existsSync(sourcePath)) {
        fail(`Firefox release payload entry missing: ${entry}`);
      }

      fs.cpSync(sourcePath, path.join(tempSourceDir, entry), { recursive: true });
    }
  } catch (error) {
    fs.rmSync(tempSourceDir, { recursive: true, force: true });
    throw error;
  }

  return tempSourceDir;
}

export function prepareSigningSourceDir(options) {
  const { sourceDir = extensionRoot, version = '' } = options;
  const resolvedSourceDir = path.resolve(sourceDir);
  const manifestPath = path.join(resolvedSourceDir, 'manifest.json');
  const manifest = readManifest(manifestPath);
  const baseVersion =
    typeof manifest.version === 'string' && manifest.version.trim().length > 0
      ? manifest.version.trim()
      : '';

  if (!baseVersion) {
    fail(`manifest.json at ${manifestPath} must define a non-empty version`);
  }

  const effectiveVersion = version.trim() || baseVersion;
  const tempSourceDir = prepareFirefoxReleaseSourceDir(resolvedSourceDir);

  manifest.version = effectiveVersion;
  fs.writeFileSync(
    path.join(tempSourceDir, 'manifest.json'),
    `${JSON.stringify(manifest, null, 2)}\n`
  );

  return {
    sourceDir: tempSourceDir,
    effectiveVersion,
    cleanup() {
      fs.rmSync(tempSourceDir, { recursive: true, force: true });
    },
  };
}

function parseCliArgs(argv) {
  const parsed = {
    installUrl: '',
    artifactsDir: defaultArtifactsDir,
    version: '',
    uploadSourceCode:
      process.env.WEB_EXT_SIGN_SOURCE_CODE_ARCHIVE?.trim() ||
      process.env.WEB_EXT_SIGN_SOURCE_CODE?.trim() ||
      '',
    amoMetadata: process.env.WEB_EXT_AMO_METADATA?.trim() || '',
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? '';
    const next = argv[index + 1] ?? '';

    switch (arg) {
      case '--install-url':
        parsed.installUrl = next;
        index += 1;
        break;
      case '--artifacts-dir':
        parsed.artifactsDir = next;
        index += 1;
        break;
      case '--version':
        parsed.version = next;
        index += 1;
        break;
      case '--upload-source-code':
        parsed.uploadSourceCode = next;
        index += 1;
        break;
      case '--amo-metadata':
        parsed.amoMetadata = next;
        index += 1;
        break;
      case '--help':
      case '-h':
        console.log(`Usage:
  WEB_EXT_API_KEY=... WEB_EXT_API_SECRET=... node sign-firefox-release.mjs [--install-url https://...] [--version 2.0.0.123] [--upload-source-code openpath-firefox-source.zip] [--amo-metadata amo-review-metadata.json]

Options:
  --install-url         Optional managed install URL to store in metadata.json
  --artifacts-dir       Override the temporary web-ext artifacts directory
  --version             Override manifest version for the signed release bundle
  --upload-source-code  Source archive to attach to the AMO submission
  --amo-metadata        AMO metadata JSON, including version.approval_notes

Environment:
  WEB_EXT_SIGN_SOURCE_CODE_ARCHIVE  Default source archive for --upload-source-code
  WEB_EXT_AMO_METADATA              Default metadata path for --amo-metadata
`);
        process.exit(0);
        break;
      default:
        if (arg.startsWith('-')) {
          fail(`Unknown argument: ${arg}`);
        }
    }
  }

  return parsed;
}

function createCaptureStream(target, chunks) {
  return {
    write(chunk) {
      const text = String(chunk);
      chunks.push(text);
      return target.write(text);
    },
  };
}

async function recoverSignedXpiFromAmo(options) {
  const {
    output,
    apiKey,
    apiSecret,
    signingSourceDir,
    effectiveVersion,
    artifactsDir,
    env,
    deadlineMs,
    nowImpl = Date.now,
    stdout = process.stdout,
  } = options;
  const editUrl = parseAmoVersionEditUrl(output);
  const versionAlreadyExists = isAmoVersionAlreadyExists(output);

  if (!editUrl && !versionAlreadyExists) {
    return null;
  }

  const {
    timeoutMs: recoveryTimeoutMs,
    pollIntervalMs: recoveryPollMs,
    remainingTotalMs,
  } = resolveAmoRecoveryTiming({ env, deadlineMs, nowMs: nowImpl() });
  stdout.write(
    [
      '[sign:firefox-release] AMO signed XPI recovery budget',
      `timeoutMs=${recoveryTimeoutMs}`,
      `remainingTotalMs=${formatTimeoutMs(remainingTotalMs)}`,
      `pollIntervalMs=${recoveryPollMs}`,
    ].join(' ') + '\n'
  );

  if (editUrl) {
    stdout.write(`[sign:firefox-release] Resuming AMO approval from ${editUrl.editUrl}\n`);
    return {
      signedXpiPath: await waitForAmoSignedXpi({
        apiKey,
        apiSecret,
        addonId: editUrl.addonId,
        versionId: editUrl.versionId,
        artifactsDir,
        timeoutMs: recoveryTimeoutMs,
        pollIntervalMs: recoveryPollMs,
      }),
      state: 'signed',
      addonId: editUrl.addonId,
      versionId: editUrl.versionId,
    };
  }

  const addonId = readFirefoxExtensionId(signingSourceDir);
  stdout.write(
    `[sign:firefox-release] AMO version already exists; polling addonId=${addonId} version=${effectiveVersion}\n`
  );

  return {
    signedXpiPath: await waitForAmoSignedXpi({
      apiKey,
      apiSecret,
      addonId,
      version: effectiveVersion,
      artifactsDir,
      timeoutMs: recoveryTimeoutMs,
      pollIntervalMs: recoveryPollMs,
    }),
    state: 'recovered-existing-version',
    addonId,
    version: effectiveVersion,
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  try {
    const { installUrl, artifactsDir, version, uploadSourceCode, amoMetadata } = parseCliArgs(
      process.argv.slice(2)
    );
    const signingSource = prepareSigningSourceDir({
      sourceDir: extensionRoot,
      version,
    });
    const payloadHash = computeFirefoxReleasePayloadHash({ sourceDir: extensionRoot });

    try {
      const {
        totalTimeoutMs,
        approvalTimeoutMs,
        requestTimeoutMs,
        processTimeoutBufferMs,
        processTimeoutMs,
        deadlineMs,
      } = resolveWebExtSignTiming({ env: process.env });

      console.log(
        [
          '[sign:firefox-release] Starting AMO signing',
          `version=${signingSource.effectiveVersion}`,
          `sourceDir=${signingSource.sourceDir}`,
          `artifactsDir=${artifactsDir}`,
          `webExt=${readDeclaredWebExtVersion()}`,
          `totalTimeoutMs=${formatTimeoutMs(totalTimeoutMs)}`,
          `approvalTimeoutMs=${approvalTimeoutMs}`,
          `requestTimeoutMs=${requestTimeoutMs}`,
          `processTimeoutBufferMs=${processTimeoutBufferMs}`,
          `processTimeoutMs=${processTimeoutMs ?? 'disabled'}`,
          `uploadSourceCode=${uploadSourceCode ? path.resolve(uploadSourceCode) : 'disabled'}`,
          `amoMetadata=${amoMetadata ? path.resolve(amoMetadata) : 'disabled'}`,
        ].join(' ')
      );

      const apiKey = process.env.WEB_EXT_API_KEY?.trim();
      const apiSecret = process.env.WEB_EXT_API_SECRET?.trim();
      const args = buildWebExtSignArgs({
        apiKey,
        apiSecret,
        artifactsDir,
        sourceDir: signingSource.sourceDir,
        approvalTimeoutMs,
        requestTimeoutMs,
        uploadSourceCode,
        amoMetadata,
      });
      const webExtOutput = [];

      const result = runWebExtSignWithRetry({
        args,
        cwd: extensionRoot,
        processTimeoutMs,
        deadlineMs,
        stdout: createCaptureStream(process.stdout, webExtOutput),
        stderr: createCaptureStream(process.stderr, webExtOutput),
      });

      let signedXpiPath = '';
      let signingState = 'signed';
      let signingStateAddonId = readFirefoxExtensionId(signingSource.sourceDir);
      if (result.status === 0) {
        try {
          signedXpiPath = findSignedXpiArtifact(artifactsDir);
        } catch (error) {
          const recovery = await recoverSignedXpiFromAmo({
            output: webExtOutput.join(''),
            apiKey,
            apiSecret,
            signingSourceDir: signingSource.sourceDir,
            effectiveVersion: signingSource.effectiveVersion,
            artifactsDir,
            env: process.env,
            deadlineMs,
          });
          signedXpiPath = recovery?.signedXpiPath || '';
          signingState = recovery?.state || signingState;
          signingStateAddonId = recovery?.addonId || signingStateAddonId;

          if (!signedXpiPath) {
            throw error;
          }
        }
      } else {
        const recovery = await recoverSignedXpiFromAmo({
          output: webExtOutput.join(''),
          apiKey,
          apiSecret,
          signingSourceDir: signingSource.sourceDir,
          effectiveVersion: signingSource.effectiveVersion,
          artifactsDir,
          env: process.env,
          deadlineMs,
        });
        signedXpiPath = recovery?.signedXpiPath || '';
        signingState = recovery?.state || signingState;
        signingStateAddonId = recovery?.addonId || signingStateAddonId;

        if (!signedXpiPath) {
          const failureState = resolveAmoSigningFailureState(result.status);
          writeAmoSigningStateArtifact({
            artifactsDir,
            state: failureState,
            addonId: signingStateAddonId,
            version: signingSource.effectiveVersion,
            fileStatus: 'unknown',
            message: `web-ext sign ${failureState} with status ${String(
              result.status ?? 'unknown'
            )}`,
          });
          fail(`web-ext sign failed with status ${String(result.status ?? 'unknown')}`);
        }
      }

      const { artifactPath } = writeAmoSigningStateArtifact({
        artifactsDir,
        state: signingState,
        addonId: signingStateAddonId,
        version: signingSource.effectiveVersion,
        fileStatus: 'signed',
      });
      console.log(
        `[sign:firefox-release] AMO signing state state=${signingState} artifact=${path.relative(
          extensionRoot,
          artifactPath
        )}`
      );

      const prepared = prepareFirefoxReleaseArtifacts({
        extensionRoot,
        signedXpiPath,
        installUrl,
        version: signingSource.effectiveVersion,
        payloadHash,
      });

      console.log(
        `[sign:firefox-release] Signed Firefox Release bundle ready in ${path.relative(
          extensionRoot,
          prepared.outputDir
        )}`
      );
    } finally {
      signingSource.cleanup();
    }
  } catch (error) {
    console.error(
      `[sign:firefox-release] ${error instanceof Error ? error.message : String(error)}`
    );
    process.exitCode = 1;
  }
}
