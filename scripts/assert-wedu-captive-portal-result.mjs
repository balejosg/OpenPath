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

function browserLimitedProbe(browserLimited) {
  return browserLimited.browserLimited ?? browserLimited;
}

function requireNonEmptyArray(value, field) {
  requireField(Array.isArray(value) && value.length > 0, field);
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

// Contract that forces the lab to reproduce the ACTUAL production failure mode.
//
// The bug shipped despite a green lab because the lab let the captive portal host
// be resolvable by whatever upstream the old discovery happened to find. In
// production the portal host (e.g. nce.wedu.comunidad.madrid) is resolvable ONLY
// by the network's DHCP-offered DNS (preserved in the registry DhcpNameServer),
// while OpenPath's configured Acrylic upstream is a stale/public server that
// returns NXDOMAIN. The lab must reproduce that topology and prove the agent
// discovered the network DNS by itself (Source 'dhcp-nameserver') and entered
// limited mode via autonomous detection -- not via an externally forced recovery.
function requireNetworkDnsDiscoveryEvidence(result, limitedDns) {
  // Negative control: the normal/public upstream must NOT resolve the portal host,
  // otherwise the lab is not reproducing the production condition at all.
  requireField(
    result.configuredUpstreamResolvesPortalHost === false,
    'configuredUpstreamResolvesPortalHost must be false (portal host must be unresolvable via the configured public/stale upstream, as in production)'
  );
  // The agent must have discovered the network DNS itself, via the registry
  // DhcpNameServer source -- the exact gap that caused the production failure.
  requireField(
    result.upstreamSource === 'dhcp-nameserver',
    "upstreamSource must be 'dhcp-nameserver' (agent recovered the network resolver from the registry, not a lucky adapter/gateway hit)"
  );
  requireField(
    limitedDns.upstreamSource === 'dhcp-nameserver',
    `${LIMITED_DNS_FILE} upstreamSource must be 'dhcp-nameserver'`
  );
  // Limited mode must have been reached by the watchdog's own detection. In
  // production the watchdog never entered limited mode (it looped on protected-mode
  // repair); a lab that only triggers recovery via the native host cannot catch that.
  requireField(
    result.limitedModeEnteredVia === 'autonomous-detection',
    "limitedModeEnteredVia must be 'autonomous-detection' (watchdog must enter limited mode on its own, not via forced native recovery)"
  );
  // The declared portal host must actually resolve to the internal portal address
  // through the agent's local resolver during limited mode.
  requireField(
    Array.isArray(limitedDns.hosts) &&
      limitedDns.hosts.some(
        (host) =>
          host?.resolvedThroughLocalDns === true &&
          Array.isArray(host.addresses) &&
          host.addresses.length > 0 &&
          host?.isConfiguredPortalDomain === true
      ),
    `${LIMITED_DNS_FILE} must prove a configured captive-portal domain resolved to an address through local DNS`
  );
}

// Contract for the post-auth side of the production escape.
//
// In production, once the user authenticated at the captive portal, the agent
// stayed in its relaxed posture (the watchdog never closed portal mode), leaving
// navigation fully unrestricted until logoff/reboot. The lab must therefore prove:
// the gateway really switched to authenticated mode, the network stayed
// production-faithful (open egress, portal host still resolvable only via the
// network DNS), and the watchdog closed portal mode ON ITS OWN -- not via the
// forced native reconcile, which runs afterwards as idempotent confirmation only.
function requireAutonomousExitEvidence(result) {
  requireField(
    valueAt(result, 'gatewayAuthenticated.success') === true,
    'gatewayAuthenticated.success (the browser login must have really opened the gateway)'
  );
  requireField(
    result.postAuthExternalNetworkOpen === true,
    'postAuthExternalNetworkOpen (post-auth the network must be open, as observed in production)'
  );
  requireField(
    result.postAuthPortalHostStillNetworkOnly === true,
    'postAuthPortalHostStillNetworkOnly (the portal host must remain resolvable only via the network DNS post-auth)'
  );
  requireField(
    valueAt(result, 'autonomousExit.exitedProtected') === true,
    'autonomousExit.exitedProtected (the watchdog must close portal mode on its own after authentication)'
  );
  requireField(
    result.protectedModeExitedVia === 'autonomous-watchdog-close',
    "protectedModeExitedVia must be 'autonomous-watchdog-close' (exit must not depend on a forced native reconcile)"
  );
  requireField(
    result.postAuthMarkerCleared === true,
    'postAuthMarkerCleared (no captive-portal marker may survive the authenticated exit)'
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
  requireField(result.fallbackMode !== 'passthrough', 'fallbackMode not passthrough');
  requireNonEmptyArray(result.bootstrapHosts, 'bootstrapHosts non-empty');
  requireResultField(result, 'limitedDns.success', true);
  requireResultField(result, 'nativeRecovery.limitedModeReady', true);

  const limitedDns = readJson(join(artifactDir, LIMITED_DNS_FILE));
  requireField(limitedDns.success === true, `${LIMITED_DNS_FILE} success`);
  requireField(limitedDns.server === '127.0.0.1', `${LIMITED_DNS_FILE} server`);
  requireField(
    Array.isArray(limitedDns.hosts) &&
      limitedDns.hosts.length > 0 &&
      limitedDns.hosts.every((host) => host?.resolvedThroughLocalDns === true),
    `${LIMITED_DNS_FILE} hosts resolved through local DNS`
  );

  // Force the lab to reproduce the real production failure mode (see function doc).
  requireNetworkDnsDiscoveryEvidence(result, limitedDns);

  // And the post-auth half of it: the autonomous exit back to enforcement.
  requireAutonomousExitEvidence(result);

  const browserLimited = readJson(join(artifactDir, LIMITED_BROWSER_FILE));
  const limitedProbe = browserLimitedProbe(browserLimited);
  requireField(limitedProbe.portalReady === true, `${LIMITED_BROWSER_FILE} portalReady`);
  requireField(limitedProbe.loginSubmitted === true, `${LIMITED_BROWSER_FILE} loginSubmitted`);
  requireField(
    browserLimited.limitedModeReady === true || result.limitedModeReady === true,
    `${LIMITED_BROWSER_FILE} limitedModeReady`
  );

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
