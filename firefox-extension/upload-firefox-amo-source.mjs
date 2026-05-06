#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createAmoJwt } from './sign-firefox-release.mjs';
import { verifyFirefoxAmoVersion } from './verify-firefox-amo-version.mjs';

const __filename = fileURLToPath(import.meta.url);
const extensionRoot = path.dirname(__filename);
const defaultAmoBaseUrl = 'https://addons.mozilla.org/api/v5/';
const defaultAddonId = 'monitor-bloqueos@openpath';
const defaultSourceArchive = path.join(
  extensionRoot,
  'build',
  'firefox-source-submission',
  'openpath-firefox-source.zip'
);
const defaultMetadataPath = path.join(extensionRoot, 'amo-review-metadata.json');

function fail(message) {
  throw new Error(message);
}

function normalizeAmoBaseUrl(amoBaseUrl = defaultAmoBaseUrl) {
  const baseUrl = new URL(amoBaseUrl);
  if (!baseUrl.pathname.endsWith('/')) {
    baseUrl.pathname += '/';
  }
  return baseUrl;
}

function buildAmoVersionUrl(options) {
  const { amoBaseUrl = defaultAmoBaseUrl, addonId, versionId = '', version = '' } = options;
  const versionLookup = normalizeVersionLookup({ versionId, version });
  return new URL(
    `addons/addon/${encodeURIComponent(addonId)}/versions/${encodeURIComponent(versionLookup)}/`,
    normalizeAmoBaseUrl(amoBaseUrl)
  );
}

function normalizeVersionLookup(options) {
  const { versionId = '', version = '' } = options;
  const trimmedVersionId = String(versionId ?? '').trim();
  const trimmedVersion = String(version ?? '').trim();

  if (trimmedVersionId) {
    return trimmedVersionId;
  }
  if (trimmedVersion) {
    return trimmedVersion.startsWith('v') ? trimmedVersion : `v${trimmedVersion}`;
  }

  fail('AMO version id or version is required');
}

function buildAuthHeaders(options) {
  const { apiKey, apiSecret } = options;
  return {
    Authorization: `JWT ${createAmoJwt({ apiKey, apiSecret })}`,
    Accept: 'application/json',
    'User-Agent': 'openpath-firefox-amo-source/1',
  };
}

function readApprovalNotes(metadataPath) {
  if (!metadataPath || !fs.existsSync(metadataPath)) {
    return '';
  }

  const metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
  return typeof metadata.version?.approval_notes === 'string'
    ? metadata.version.approval_notes.trim()
    : '';
}

async function readResponseBody(response) {
  const text = await response.text();
  if (!text) {
    return {};
  }

  try {
    return JSON.parse(text);
  } catch {
    return { text };
  }
}

export function parseAmoThrottleDelaySeconds(body) {
  const text =
    typeof body === 'string'
      ? body
      : typeof body?.detail === 'string'
        ? body.detail
        : typeof body?.text === 'string'
          ? body.text
          : JSON.stringify(body ?? {});
  const match = /Expected available in\s+(\d+)\s+seconds?/i.exec(text);
  return match ? Number.parseInt(match[1], 10) : null;
}

function formatRetryTarget(options) {
  const { versionId = '', version = '' } = options;
  return versionId ? `--version-id ${versionId}` : `--version ${version}`;
}

function buildMetadataOnlyRetryCommand(options) {
  const { versionId = '', version = '' } = options;
  return [
    'npm run upload:firefox-amo-source --workspace=@openpath/firefox-extension --',
    formatRetryTarget({ versionId, version }),
    '--metadata-only',
    '--verify',
    '--wait-for-throttle',
    '--max-throttle-wait-seconds 10800',
    '--max-retries 3',
  ].join(' ');
}

function buildThrottleErrorMessage(options) {
  const { action, status, statusText, body, throttleDelaySeconds, versionId, version } = options;
  const minutes =
    throttleDelaySeconds === null ? 'unknown' : (throttleDelaySeconds / 60).toFixed(1);
  const retryCommand = buildMetadataOnlyRetryCommand({ versionId, version });
  return [
    `AMO ${action} PATCH failed: ${status} ${statusText} ${JSON.stringify(body)}`,
    throttleDelaySeconds === null
      ? 'AMO throttle delay was not present in the response.'
      : `AMO throttle delay ${throttleDelaySeconds} seconds (${minutes} minutes).`,
    `Retry without re-uploading source: ${retryCommand}`,
  ].join('\n');
}

async function sleep(milliseconds) {
  if (milliseconds <= 0) {
    return;
  }
  await new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

async function patchAmoVersionJson(options) {
  const {
    url,
    apiKey,
    apiSecret,
    payload,
    fetchImpl = fetch,
    waitForThrottle = false,
    maxThrottleWaitSeconds = 0,
    retryBufferSeconds = 10,
    maxRetries,
    sleepImpl = sleep,
    stdout = process.stdout,
    versionId = '',
    version = '',
  } = options;

  for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
    const response = await fetchImpl(url, {
      method: 'PATCH',
      headers: {
        ...buildAuthHeaders({ apiKey, apiSecret }),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });
    const body = await readResponseBody(response);

    if (response.ok) {
      return body;
    }

    const throttleDelaySeconds =
      response.status === 429 ? parseAmoThrottleDelaySeconds(body) : null;
    const canRetry =
      waitForThrottle &&
      throttleDelaySeconds !== null &&
      throttleDelaySeconds <= maxThrottleWaitSeconds &&
      attempt < maxRetries;

    if (!canRetry) {
      if (response.status === 429) {
        fail(
          buildThrottleErrorMessage({
            action: 'metadata',
            status: response.status,
            statusText: response.statusText,
            body,
            throttleDelaySeconds,
            versionId,
            version,
          })
        );
      }

      fail(
        `AMO metadata PATCH failed: ${response.status} ${response.statusText} ${JSON.stringify(
          body
        )}`
      );
    }

    const waitSeconds = throttleDelaySeconds + retryBufferSeconds;
    stdout.write(
      `[upload:firefox-amo-source] AMO metadata PATCH throttled; retrying in ${waitSeconds} seconds\n`
    );
    await sleepImpl(waitSeconds * 1000);
  }

  fail('AMO metadata PATCH retries exhausted');
}

export async function uploadFirefoxAmoSource(options) {
  const {
    apiKey,
    apiSecret,
    addonId = defaultAddonId,
    versionId = '',
    version = '',
    sourceArchive = defaultSourceArchive,
    metadataPath = defaultMetadataPath,
    amoBaseUrl = defaultAmoBaseUrl,
    fetchImpl = fetch,
    sourceOnly = false,
    metadataOnly = false,
    verify = true,
    waitForThrottle = false,
    maxThrottleWaitSeconds = 0,
    retryBufferSeconds = 10,
    maxRetries,
    sleepImpl = sleep,
    stdout = process.stdout,
  } = options;

  if (!apiKey) {
    fail('WEB_EXT_API_KEY is required');
  }
  if (!apiSecret) {
    fail('WEB_EXT_API_SECRET is required');
  }
  if (sourceOnly && metadataOnly) {
    fail('--source-only and --metadata-only cannot be used together');
  }
  normalizeVersionLookup({ versionId, version });
  if (!metadataOnly && !fs.existsSync(sourceArchive)) {
    fail(`AMO source archive not found: ${sourceArchive}`);
  }

  const effectiveMetadataMaxRetries = maxRetries ?? (waitForThrottle ? 3 : 0);
  const url = buildAmoVersionUrl({ amoBaseUrl, addonId, versionId, version });
  let sourceBody = null;

  if (!metadataOnly) {
    const sourceBytes = fs.readFileSync(sourceArchive);
    const formData = new FormData();
    formData.set(
      'source',
      new Blob([sourceBytes], { type: 'application/zip' }),
      path.basename(sourceArchive)
    );

    const sourceResponse = await fetchImpl(url, {
      method: 'PATCH',
      headers: buildAuthHeaders({ apiKey, apiSecret }),
      body: formData,
    });
    sourceBody = await readResponseBody(sourceResponse);

    if (!sourceResponse.ok) {
      fail(
        `AMO source PATCH failed: ${sourceResponse.status} ${sourceResponse.statusText} ${JSON.stringify(
          sourceBody
        )}`
      );
    }
  }

  const approvalNotes = readApprovalNotes(metadataPath);
  const metadataBody =
    approvalNotes && !sourceOnly
      ? await patchAmoVersionJson({
          url,
          apiKey,
          apiSecret,
          payload: { approval_notes: approvalNotes },
          fetchImpl,
          waitForThrottle,
          maxThrottleWaitSeconds,
          retryBufferSeconds,
          maxRetries: effectiveMetadataMaxRetries,
          sleepImpl,
          stdout,
          versionId,
          version,
        })
      : null;
  const verification = verify
    ? await verifyFirefoxAmoVersion({
        apiKey,
        apiSecret,
        addonId,
        versionId,
        version,
        amoBaseUrl,
        requireSource: !metadataOnly,
        requireApprovalNotes: !sourceOnly,
        fetchImpl,
      })
    : null;

  return {
    addonId,
    versionId,
    version,
    sourceArchive,
    source: sourceBody,
    metadata: metadataBody,
    verification,
  };
}

function parseCliArgs(argv) {
  const parsed = {
    addonId: process.env.AMO_ADDON_ID || defaultAddonId,
    versionId: process.env.AMO_VERSION_ID || '',
    version: process.env.AMO_VERSION || '',
    sourceArchive:
      process.env.WEB_EXT_SIGN_SOURCE_CODE_ARCHIVE ||
      process.env.WEB_EXT_SIGN_SOURCE_CODE ||
      defaultSourceArchive,
    metadataPath: process.env.WEB_EXT_AMO_METADATA || defaultMetadataPath,
    amoBaseUrl: process.env.AMO_BASE_URL || defaultAmoBaseUrl,
    sourceOnly: false,
    metadataOnly: false,
    verify: true,
    waitForThrottle: false,
    maxThrottleWaitSeconds: 0,
    retryBufferSeconds: 10,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? '';
    const next = argv[index + 1] ?? '';

    switch (arg) {
      case '--addon-id':
        parsed.addonId = next;
        index += 1;
        break;
      case '--version-id':
        parsed.versionId = next;
        index += 1;
        break;
      case '--version':
        parsed.version = next;
        index += 1;
        break;
      case '--source':
        parsed.sourceArchive = path.resolve(next);
        index += 1;
        break;
      case '--metadata':
        parsed.metadataPath = path.resolve(next);
        index += 1;
        break;
      case '--amo-base-url':
        parsed.amoBaseUrl = next;
        index += 1;
        break;
      case '--source-only':
        parsed.sourceOnly = true;
        break;
      case '--metadata-only':
        parsed.metadataOnly = true;
        break;
      case '--verify':
        parsed.verify = true;
        break;
      case '--no-verify':
        parsed.verify = false;
        break;
      case '--wait-for-throttle':
        parsed.waitForThrottle = true;
        break;
      case '--max-throttle-wait-seconds':
        parsed.maxThrottleWaitSeconds = Number.parseInt(next, 10);
        index += 1;
        break;
      case '--retry-buffer-seconds':
        parsed.retryBufferSeconds = Number.parseInt(next, 10);
        index += 1;
        break;
      case '--max-retries':
        parsed.maxRetries = Number.parseInt(next, 10);
        index += 1;
        break;
      case '--help':
      case '-h':
        console.log(`Usage:
  WEB_EXT_API_KEY=... WEB_EXT_API_SECRET=... node upload-firefox-amo-source.mjs (--version-id 6249209 | --version 2.0.1)

Options:
  --addon-id      AMO add-on GUID or slug (default: monitor-bloqueos@openpath)
  --version-id    AMO numeric version id
  --version       AMO version string; the API lookup uses v<version>
  --source        Source archive to upload
  --metadata      Optional metadata JSON; version.approval_notes is PATCHed when present
  --amo-base-url  AMO API base URL
  --source-only   Upload source without PATCHing approval_notes
  --metadata-only PATCH approval_notes without re-uploading source
  --verify        Verify source/approval_notes remotely after PATCH (default)
  --no-verify     Skip remote AMO verification
  --wait-for-throttle
                 Wait and retry AMO 429 metadata throttles within the configured budget.
                 If omitted, --max-retries defaults to 3 when this flag is set.
  --max-throttle-wait-seconds
                 Largest AMO throttle delay to wait for when --wait-for-throttle is set
  --retry-buffer-seconds
                 Extra seconds to wait beyond AMO's throttle delay
  --max-retries   Maximum metadata PATCH retries; use --max-retries 0 to disable retrying

Safe metadata retry:
  npm run upload:firefox-amo-source --workspace=@openpath/firefox-extension -- --version-id 6249209 --metadata-only --verify --wait-for-throttle --max-throttle-wait-seconds 10800 --max-retries 3
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

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  try {
    const options = parseCliArgs(process.argv.slice(2));
    const apiKey = process.env.WEB_EXT_API_KEY?.trim();
    const apiSecret = process.env.WEB_EXT_API_SECRET?.trim();
    const result = await uploadFirefoxAmoSource({ ...options, apiKey, apiSecret });
    console.log(
      `[upload:firefox-amo-source] Updated AMO version for ${result.addonId} ${
        result.versionId ? `versionId=${result.versionId}` : `version=${result.version}`
      }`
    );
  } catch (error) {
    console.error(
      `[upload:firefox-amo-source] ${error instanceof Error ? error.message : String(error)}`
    );
    process.exitCode = 1;
  }
}
