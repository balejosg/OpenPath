#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const RESULT_FILE = 'direct-captive-portal-wedu-lab-result.json';
const BROWSER_BEFORE_FILE = 'wedu-lab-browser-before.json';
const LIMITED_DNS_FILE = 'wedu-lab-dns-limited.json';
const LIMITED_BROWSER_FILE = 'wedu-lab-browser-limited.json';
const TARGET_AFTER_FILE = 'wedu-lab-browser-post-auth.json';
const POST_AUTH_DNS_FILE = 'wedu-lab-dns-post-auth.json';
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

function browserLimitedProbe(browserLimited) {
  return browserLimited.browserLimited ?? browserLimited;
}

function requireNonEmptyArray(value, field) {
  requireField(Array.isArray(value) && value.length > 0, field);
}

function requireEmptyArray(value, field) {
  requireField(Array.isArray(value) && value.length === 0, field);
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
    ['nativeRecovery.success', true],
    ['nativeRecovery.portalModeActive', true],
    ['nativeRecovery.recoveryHostsApplied', true],
    ['nativeReconcile.success', true],
    ['nativeReconcile.protectedModeRestored', true],
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
  requireResultField(result, 'activeMarkerMode', 'limited');
  requireResultField(result, 'limitedModeReady', true);
  requireResultField(result, 'discoveryTruncated', false);
  requireField(result.fallbackMode !== 'passthrough', 'fallbackMode not passthrough');
  requireEmptyArray(result.pendingRuntimeHosts, 'pendingRuntimeHosts empty');
  requireNonEmptyArray(result.bootstrapHosts, 'bootstrapHosts non-empty');
  requireNonEmptyArray(
    result.nativeRecovery.portalRecoveryHosts,
    'nativeRecovery.portalRecoveryHosts'
  );
  requireResultField(result, 'limitedDns.success', true);
  requireResultField(result, 'nativeRecovery.limitedModeReady', true);
  requireResultField(result, 'nativeRecovery.discoveryTruncated', false);

  const limitedDns = readJson(join(artifactDir, LIMITED_DNS_FILE));
  requireField(limitedDns.success === true, `${LIMITED_DNS_FILE} success`);
  requireField(limitedDns.server === '127.0.0.1', `${LIMITED_DNS_FILE} server`);
  requireField(
    Array.isArray(limitedDns.hosts) &&
      limitedDns.hosts.length > 0 &&
      limitedDns.hosts.every((host) => host?.resolvedThroughLocalDns === true),
    `${LIMITED_DNS_FILE} hosts resolved through local DNS`
  );

  const browserLimited = readJson(join(artifactDir, LIMITED_BROWSER_FILE));
  const limitedProbe = browserLimitedProbe(browserLimited);
  requireField(limitedProbe.portalReady === true, `${LIMITED_BROWSER_FILE} portalReady`);
  requireField(limitedProbe.loginSubmitted === true, `${LIMITED_BROWSER_FILE} loginSubmitted`);
  requireField(
    browserLimited.limitedModeReady === true || result.limitedModeReady === true,
    `${LIMITED_BROWSER_FILE} limitedModeReady`
  );

  const browserAfter = readJson(join(artifactDir, TARGET_AFTER_FILE));
  readJson(join(artifactDir, POST_AUTH_DNS_FILE));
  requireField(browserAfter.portalMarkerAbsent === true, 'portalMarkerAbsent');
  requireField(browserAfterNavigationFunctional(browserAfter), 'externalNavigationFunctional');
  requireField(browserAfterFailureKind(browserAfter) === 'none', 'failureKind none');

  return { result, browserBefore, browserAfter };
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
