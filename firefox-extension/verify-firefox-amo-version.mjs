#!/usr/bin/env node

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createAmoJwt } from './sign-firefox-release.mjs';

const __filename = fileURLToPath(import.meta.url);
const defaultAmoBaseUrl = 'https://addons.mozilla.org/api/v5/';
const defaultAddonId = 'monitor-bloqueos@openpath';

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

export function buildFirefoxAmoVersionUrl(options) {
  const { amoBaseUrl = defaultAmoBaseUrl, addonId = defaultAddonId } = options;
  const versionLookup = normalizeVersionLookup(options);

  if (!String(addonId ?? '').trim()) {
    fail('AMO addon id is required');
  }

  return new URL(
    `addons/addon/${encodeURIComponent(String(addonId).trim())}/versions/${encodeURIComponent(
      versionLookup
    )}/`,
    normalizeAmoBaseUrl(amoBaseUrl)
  );
}

function buildAuthHeaders(options) {
  const { apiKey, apiSecret } = options;
  return {
    Authorization: `JWT ${createAmoJwt({ apiKey, apiSecret })}`,
    Accept: 'application/json',
    'User-Agent': 'openpath-firefox-amo-version/1',
  };
}

async function readJsonResponse(response) {
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

function hasValue(value) {
  if (typeof value === 'string') {
    return value.trim().length > 0;
  }
  return value !== null && value !== undefined;
}

function hasLocalizedValue(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }

  return Object.values(value).some((entry) => typeof entry === 'string' && entry.trim().length > 0);
}

function summarizeVersion(detail) {
  return {
    versionId: detail.id ?? '',
    version: typeof detail.version === 'string' ? detail.version : '',
    channel: typeof detail.channel === 'string' ? detail.channel : '',
    fileStatus: typeof detail.file?.status === 'string' ? detail.file.status : '',
    sourcePresent: hasValue(detail.source),
    approvalNotesPresent: hasValue(detail.approval_notes),
    releaseNotesPresent: hasLocalizedValue(detail.release_notes),
  };
}

export async function verifyFirefoxAmoVersion(options) {
  const {
    apiKey,
    apiSecret,
    addonId = defaultAddonId,
    versionId = '',
    version = '',
    amoBaseUrl = defaultAmoBaseUrl,
    requireSource = false,
    requireApprovalNotes = false,
    requireReleaseNotes = false,
    fetchImpl = fetch,
  } = options;

  if (!apiKey) {
    fail('WEB_EXT_API_KEY is required');
  }
  if (!apiSecret) {
    fail('WEB_EXT_API_SECRET is required');
  }

  const url = buildFirefoxAmoVersionUrl({ amoBaseUrl, addonId, versionId, version });
  const response = await fetchImpl(url, {
    method: 'GET',
    headers: buildAuthHeaders({ apiKey, apiSecret }),
  });
  const detail = await readJsonResponse(response);

  if (!response.ok) {
    fail(
      `AMO version GET failed: ${response.status} ${response.statusText} ${JSON.stringify(detail)}`
    );
  }

  const summary = summarizeVersion(detail);
  const target = String(versionId || version || summary.versionId || summary.version);

  if (requireSource && !summary.sourcePresent) {
    fail(`AMO version ${target} is missing source`);
  }
  if (requireApprovalNotes && !summary.approvalNotesPresent) {
    fail(`AMO version ${target} is missing approval_notes`);
  }
  if (requireReleaseNotes && !summary.releaseNotesPresent) {
    fail(`AMO version ${target} is missing release_notes`);
  }

  return summary;
}

function parseCliArgs(argv) {
  const parsed = {
    addonId: process.env.AMO_ADDON_ID || defaultAddonId,
    versionId: process.env.AMO_VERSION_ID || '',
    version: process.env.AMO_VERSION || '',
    amoBaseUrl: process.env.AMO_BASE_URL || defaultAmoBaseUrl,
    requireSource: false,
    requireApprovalNotes: false,
    requireReleaseNotes: false,
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
      case '--amo-base-url':
        parsed.amoBaseUrl = next;
        index += 1;
        break;
      case '--require-source':
        parsed.requireSource = true;
        break;
      case '--require-approval-notes':
        parsed.requireApprovalNotes = true;
        break;
      case '--require-release-notes':
        parsed.requireReleaseNotes = true;
        break;
      case '--help':
      case '-h':
        console.log(`Usage:
  WEB_EXT_API_KEY=... WEB_EXT_API_SECRET=... node verify-firefox-amo-version.mjs (--version-id 6249209 | --version 2.0.1)

Options:
  --addon-id                 AMO add-on GUID or slug
  --version-id               AMO numeric version id
  --version                  AMO version string; the API lookup uses v<version>
  --amo-base-url             AMO API base URL
  --require-source           Fail unless AMO reports source is present
  --require-approval-notes   Fail unless AMO reports approval_notes is present
  --require-release-notes    Fail unless AMO reports localized release_notes is present
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
    const result = await verifyFirefoxAmoVersion({ ...options, apiKey, apiSecret });
    console.log(
      [
        '[verify:firefox-amo-version]',
        `versionId=${result.versionId}`,
        `version=${result.version}`,
        `channel=${result.channel}`,
        `fileStatus=${result.fileStatus}`,
        `sourcePresent=${result.sourcePresent}`,
        `approvalNotesPresent=${result.approvalNotesPresent}`,
        `releaseNotesPresent=${result.releaseNotesPresent}`,
      ].join(' ')
    );
  } catch (error) {
    console.error(
      `[verify:firefox-amo-version] ${error instanceof Error ? error.message : String(error)}`
    );
    process.exitCode = 1;
  }
}
