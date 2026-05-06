#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createAmoJwt } from './sign-firefox-release.mjs';

const __filename = fileURLToPath(import.meta.url);
const extensionRoot = path.dirname(__filename);
const defaultAmoBaseUrl = 'https://addons.mozilla.org/api/v5/';
const defaultAddonId = 'monitor-bloqueos@openpath';
const defaultPrivacyPath = path.join(extensionRoot, 'PRIVACY.md');

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

function buildAmoPolicyUrl(options) {
  const { amoBaseUrl = defaultAmoBaseUrl, addonId = defaultAddonId } = options;
  if (!String(addonId ?? '').trim()) {
    fail('AMO addon id is required');
  }

  return new URL(
    `addons/addon/${encodeURIComponent(String(addonId).trim())}/eula_policy/`,
    normalizeAmoBaseUrl(amoBaseUrl)
  );
}

function buildAuthHeaders(options) {
  const { apiKey, apiSecret } = options;
  return {
    Authorization: `JWT ${createAmoJwt({ apiKey, apiSecret })}`,
    Accept: 'application/json',
    'User-Agent': 'openpath-firefox-amo-policy/1',
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

async function fetchAmoPolicyJson(options) {
  const { url, apiKey, apiSecret, fetchImpl = fetch } = options;
  const response = await fetchImpl(url, {
    method: 'GET',
    headers: buildAuthHeaders({ apiKey, apiSecret }),
  });
  const body = await readJsonResponse(response);

  if (!response.ok) {
    fail(
      `AMO policy GET failed: ${response.status} ${response.statusText} ${JSON.stringify(body)}`
    );
  }

  return body;
}

export async function syncFirefoxAmoPolicy(options) {
  const {
    apiKey,
    apiSecret,
    addonId = defaultAddonId,
    privacyPath = defaultPrivacyPath,
    amoBaseUrl = defaultAmoBaseUrl,
    fetchImpl = fetch,
  } = options;

  if (!apiKey) {
    fail('WEB_EXT_API_KEY is required');
  }
  if (!apiSecret) {
    fail('WEB_EXT_API_SECRET is required');
  }
  if (!fs.existsSync(privacyPath)) {
    fail(`Privacy policy file not found: ${privacyPath}`);
  }

  const privacyPolicy = fs.readFileSync(privacyPath, 'utf8');
  const url = buildAmoPolicyUrl({ amoBaseUrl, addonId });
  const patchResponse = await fetchImpl(url, {
    method: 'PATCH',
    headers: {
      ...buildAuthHeaders({ apiKey, apiSecret }),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ privacy_policy: { 'en-US': privacyPolicy } }),
  });
  const patchBody = await readJsonResponse(patchResponse);

  if (!patchResponse.ok) {
    fail(
      `AMO policy PATCH failed: ${patchResponse.status} ${patchResponse.statusText} ${JSON.stringify(
        patchBody
      )}`
    );
  }

  const readback = await fetchAmoPolicyJson({ url, apiKey, apiSecret, fetchImpl });
  const actualPrivacyPolicy = readback.privacy_policy?.['en-US'] ?? '';
  const privacyPolicyPresent =
    typeof actualPrivacyPolicy === 'string' && actualPrivacyPolicy.trim().length > 0;

  if (!privacyPolicyPresent) {
    fail(`AMO privacy_policy readback is empty for addon ${addonId}`);
  }

  return {
    addonId,
    privacyPath,
    privacyPolicyPresent,
  };
}

function parseCliArgs(argv) {
  const parsed = {
    addonId: process.env.AMO_ADDON_ID || defaultAddonId,
    privacyPath: process.env.AMO_PRIVACY_PATH || defaultPrivacyPath,
    amoBaseUrl: process.env.AMO_BASE_URL || defaultAmoBaseUrl,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? '';
    const next = argv[index + 1] ?? '';

    switch (arg) {
      case '--addon-id':
        parsed.addonId = next;
        index += 1;
        break;
      case '--privacy':
        parsed.privacyPath = path.resolve(next);
        index += 1;
        break;
      case '--amo-base-url':
        parsed.amoBaseUrl = next;
        index += 1;
        break;
      case '--help':
      case '-h':
        console.log(`Usage:
  WEB_EXT_API_KEY=... WEB_EXT_API_SECRET=... node sync-firefox-amo-policy.mjs [--privacy PRIVACY.md]

Options:
  --addon-id      AMO add-on GUID or slug
  --privacy       Privacy policy markdown file to sync as en-US
  --amo-base-url  AMO API base URL
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
    const result = await syncFirefoxAmoPolicy({ ...options, apiKey, apiSecret });
    console.log(
      `[sync:firefox-amo-policy] addonId=${result.addonId} privacyPolicyPresent=${result.privacyPolicyPresent}`
    );
  } catch (error) {
    console.error(
      `[sync:firefox-amo-policy] ${error instanceof Error ? error.message : String(error)}`
    );
    process.exitCode = 1;
  }
}
