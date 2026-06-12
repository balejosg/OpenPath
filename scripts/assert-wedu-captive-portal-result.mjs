#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const RESULT_FILE = 'direct-captive-portal-wedu-lab-result.json';
const BROWSER_BEFORE_FILE = 'wedu-lab-browser-before.json';
const TARGET_AFTER_FILE = 'wedu-lab-browser-post-auth.json';
const POST_AUTH_DNS_FILE = 'wedu-lab-dns-post-auth.json';
const NETWORK_AFTER_FILE = 'wedu-lab-network-after.json';
const OPENPATH_PROTECTION_AFTER_FILE = 'wedu-lab-openpath-protection-after.json';
const VALID_MODES = new Set(['lab-direct', 'target-platform']);

function readJson(path) {
  try {
    const content = readFileSync(path, 'utf8').replace(/^\uFEFF/, '');
    return JSON.parse(content);
  } catch (error) {
    throw new Error(`Unable to read JSON artifact ${path}: ${error.message}`);
  }
}

function fail(message) {
  throw new Error(`WEDU captive portal result validation failed: ${message}`);
}

function requireField(condition, field) {
  if (!condition) {
    fail(field);
  }
}

function valueAt(payload, path) {
  return path.split('.').reduce((value, key) => value?.[key], payload);
}

function requireResultField(result, path, expected = true) {
  requireField(valueAt(result, path) === expected, path);
}

function browserAfterNavigationFunctional(browserAfter) {
  return (
    browserAfter.externalNavigationFunctional === true ||
    browserAfter.postAuthBrowserNavigationVerified === true
  );
}

function browserAfterFailureKind(browserAfter) {
  return browserAfter.failureKind ?? browserAfter.postAuthFailureKind;
}

function arrayValue(value) {
  return Array.isArray(value) ? value : [];
}

function dnsServersForAdapters(adapters) {
  return arrayValue(adapters).flatMap((adapter) => arrayValue(adapter?.dnsServers));
}

function requirePostAuthProtectionAfter(protectionAfter) {
  requireField(
    (protectionAfter.server ?? protectionAfter.resolverServer) === '127.0.0.1',
    `${OPENPATH_PROTECTION_AFTER_FILE} server`
  );
  requireField(
    protectionAfter.blockedDomain === 'this-should-be-blocked-test-12345.com',
    `${OPENPATH_PROTECTION_AFTER_FILE} blockedDomain`
  );
  requireField(
    protectionAfter.blockedByOpenPath === true,
    `${OPENPATH_PROTECTION_AFTER_FILE} blockedByOpenPath`
  );
  requireField(
    protectionAfter.allowedDomain === 'www.msftconnecttest.com',
    `${OPENPATH_PROTECTION_AFTER_FILE} allowedDomain`
  );
  requireField(
    protectionAfter.allowedDomainFunctional === true,
    `${OPENPATH_PROTECTION_AFTER_FILE} allowedDomainFunctional`
  );
  requireField(
    protectionAfter.protectedModeRestored === true,
    `${OPENPATH_PROTECTION_AFTER_FILE} protectedModeRestored`
  );
  requireField(
    protectionAfter.adapterLocalDnsRestored === true,
    `${OPENPATH_PROTECTION_AFTER_FILE} adapterLocalDnsRestored`
  );
  requireField(
    arrayValue(protectionAfter.adaptersUsingLocalDns).length > 0,
    `${OPENPATH_PROTECTION_AFTER_FILE} adaptersUsingLocalDns`
  );
  requireField(
    protectionAfter.acrylicNxWildcardPresent === true,
    `${OPENPATH_PROTECTION_AFTER_FILE} acrylicNxWildcardPresent`
  );
  requireField(
    protectionAfter.acrylicCaptivePortalSectionPresent === false,
    `${OPENPATH_PROTECTION_AFTER_FILE} acrylicCaptivePortalSectionPresent`
  );
}

function requirePostAuthDnsEvidence(postAuthDns) {
  requireField(
    Array.isArray(postAuthDns.queries) &&
      postAuthDns.queries.length > 0 &&
      postAuthDns.queries.some(
        (query) =>
          query?.success === true && Array.isArray(query.addresses) && query.addresses.length > 0
      ),
    `${POST_AUTH_DNS_FILE} queries`
  );
  requireField(postAuthDns.resolverServer === '127.0.0.1', `${POST_AUTH_DNS_FILE} resolverServer`);
  requireField(
    dnsServersForAdapters(postAuthDns.adapters).includes('127.0.0.1'),
    `${POST_AUTH_DNS_FILE} adapters must include local DNS server 127.0.0.1`
  );
}

// Permanent split DNS (Stage C2): the declared portal host must already resolve
// through the local resolver in NORMAL protected mode with the watchdog ENABLED
// and the captive-portal marker NEVER appearing across N watchdog cycles, while
// the whitelist default-block still holds.
function requireSplitDnsProtectedEvidence(result) {
  requireField(
    valueAt(result, 'splitDnsProtected.portalResolvesInProtectedMode') === true,
    'splitDnsProtected.portalResolvesInProtectedMode (declared portal host must resolve in protected mode via split DNS)'
  );
  requireField(
    valueAt(result, 'splitDnsProtected.markerNeverPresent') === true,
    'splitDnsProtected.markerNeverPresent (split-DNS suppression must prevent the marker from appearing across all watchdog cycles)'
  );
  requireField(
    valueAt(result, 'splitDnsProtected.blockedDomainStillBlocked') === true,
    'splitDnsProtected.blockedDomainStillBlocked (split DNS must not relax the default block)'
  );
  requireField(
    valueAt(result, 'splitDnsProtected.splitTopologyActive') === true,
    'splitDnsProtected.splitTopologyActive (network DNS on the third upstream, public resolver still primary -- proves split DNS, not limited mode)'
  );
  requireField(
    result.postAuthMarkerNeverPresent === true,
    'postAuthMarkerNeverPresent (no captive-portal marker may appear at any point during the captive->authenticate->post cycle)'
  );
}

function requirePostAuthNetworkEvidence(networkAfter) {
  requireField(
    Array.isArray(networkAfter.adapters) && networkAfter.adapters.length > 0,
    `${NETWORK_AFTER_FILE} adapters`
  );
  requireField(
    dnsServersForAdapters(networkAfter.adapters).includes('127.0.0.1'),
    `${NETWORK_AFTER_FILE} adapters must include local DNS server 127.0.0.1`
  );
}

export function assertWeduCaptivePortalResult({ artifactDir, evidenceMode = 'lab-direct' }) {
  if (!artifactDir) {
    fail('artifactDir is required');
  }
  if (!VALID_MODES.has(evidenceMode)) {
    fail(`evidenceMode must be one of ${[...VALID_MODES].join(', ')}`);
  }

  const result = readJson(join(artifactDir, RESULT_FILE));
  const browserBefore = readJson(join(artifactDir, BROWSER_BEFORE_FILE));

  requireField(
    result.profile === 'captive-portal-wedu-lab',
    'profile must be captive-portal-wedu-lab'
  );
  requireField(
    browserBefore.portalDetected === true,
    'wedu-lab-browser-before.json portalDetected'
  );

  for (const [path, expected] of [
    ['success', true],
    ['evidenceLevel', 'wedu-lab-direct-runner'],
    ['labNetwork.labNetworkVerified', true],
    ['openPathProtectionAfter.protectedModeRestored', true],
  ]) {
    requireResultField(result, path, expected);
  }

  if (evidenceMode === 'lab-direct') {
    return { result, browserBefore };
  }

  requireField(Number(result.schemaVersion) >= 2, 'schemaVersion >= 2');
  requireField(result.targetPlatformSymptomCleared === true, 'targetPlatformSymptomCleared');
  requireField(
    result.browserAfterAuthPath === TARGET_AFTER_FILE,
    `browserAfterAuthPath == ${TARGET_AFTER_FILE}`
  );
  requireField(result.fallbackMode !== 'passthrough', 'fallbackMode not passthrough');

  // Stage C2: split DNS suppresses autonomous portal-mode entry.
  requireSplitDnsProtectedEvidence(result);

  const browserAfter = readJson(join(artifactDir, TARGET_AFTER_FILE));
  const postAuthDns = readJson(join(artifactDir, POST_AUTH_DNS_FILE));
  const networkAfter = readJson(join(artifactDir, NETWORK_AFTER_FILE));
  const openPathProtectionAfter = readJson(join(artifactDir, OPENPATH_PROTECTION_AFTER_FILE));
  requireField(browserAfter.portalMarkerAbsent === true, 'portalMarkerAbsent');
  requireField(browserAfterNavigationFunctional(browserAfter), 'externalNavigationFunctional');
  requireField(browserAfterFailureKind(browserAfter) === 'none', 'failureKind none');
  requirePostAuthDnsEvidence(postAuthDns);
  requirePostAuthNetworkEvidence(networkAfter);
  requirePostAuthProtectionAfter(openPathProtectionAfter);

  return {
    result,
    browserBefore,
    browserAfter,
    postAuthDns,
    networkAfter,
    openPathProtectionAfter,
  };
}

function parseCli(argv) {
  const args = [...argv];
  const artifactDir = args.shift();
  let evidenceMode = 'lab-direct';

  while (args.length > 0) {
    const arg = args.shift();
    if (arg === '--evidence-mode') {
      evidenceMode = args.shift();
      continue;
    }
    if (arg?.startsWith('--evidence-mode=')) {
      evidenceMode = arg.slice('--evidence-mode='.length);
      continue;
    }
    fail(`unknown argument ${arg}`);
  }

  return { artifactDir, evidenceMode };
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const result = assertWeduCaptivePortalResult(parseCli(process.argv.slice(2)));
    console.log(
      JSON.stringify(
        {
          ok: true,
          evidenceMode: process.argv.includes('--evidence-mode')
            ? process.argv[process.argv.indexOf('--evidence-mode') + 1]
            : 'lab-direct',
          profile: result.result.profile,
        },
        null,
        2
      )
    );
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}
