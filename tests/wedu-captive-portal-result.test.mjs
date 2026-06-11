import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, test } from 'node:test';

import { assertWeduCaptivePortalResult } from '../scripts/assert-wedu-captive-portal-result.mjs';

function writeJsonFile(artifactDir, name, payload, { bom = false } = {}) {
  const content = JSON.stringify(payload, null, 2);
  writeFileSync(join(artifactDir, name), `${bom ? '\uFEFF' : ''}${content}`);
}

function makeArtifactDir(files = {}) {
  const artifactDir = mkdtempSync(join(tmpdir(), 'wedu-result-'));
  for (const [name, payload] of Object.entries(files)) {
    writeJsonFile(artifactDir, name, payload);
  }
  return artifactDir;
}

function baseResult(overrides = {}) {
  return {
    success: true,
    profile: 'captive-portal-wedu-lab',
    evidenceLevel: 'wedu-lab-direct-runner',
    schemaVersion: 2,
    labNetwork: {
      labNetworkVerified: true,
    },
    targetPlatformSymptomCleared: true,
    configuredUpstreamResolvesPortalHost: false,
    upstreamSource: 'dhcp-nameserver',
    limitedModeEnteredVia: 'autonomous-detection',
    browserBeforePath: 'wedu-lab-browser-before.json',
    browserAfterAuthPath: 'wedu-lab-browser-post-auth.json',
    activeMarkerMode: 'limited',
    limitedModeReady: true,
    bootstrapHosts: ['nce.wedu.comunidad.madrid', 'wlogin.wedu-lab.test'],
    observedRuntimeHosts: ['assets.wedu-lab.test'],
    pendingRuntimeHosts: [],
    discoveryTruncated: false,
    fallbackMode: 'none',
    limitedDns: {
      success: true,
    },
    nativeRecovery: {
      success: true,
      portalModeActive: true,
      recoveryHostsApplied: true,
      portalRecoveryHosts: ['nce.wedu.comunidad.madrid', 'wlogin.wedu-lab.test'],
      limitedModeReady: true,
      discoveryTruncated: false,
    },
    gatewayAuthenticated: {
      success: true,
    },
    nativeReconcile: {
      success: true,
      protectedModeRestored: true,
    },
    openPathProtectionAfter: {
      protectedModeRestored: true,
    },
    ...overrides,
  };
}

function discoveredHostResult(overrides = {}) {
  const bootstrapHosts = ['nce.wedu.comunidad.madrid'];
  const redirectHosts = ['wlogin.wedu-lab.test'];
  const resourceHosts = ['assets.wedu-lab.test', 'cdn.wedu-lab.test', 'auth.wedu-lab.test'];
  const weduHosts = [...bootstrapHosts, ...redirectHosts, ...resourceHosts];

  return baseResult({
    bootstrapHosts,
    redirectHosts,
    resourceHosts,
    observedRuntimeHosts: ['assets.wedu-lab.test', 'cdn.wedu-lab.test', 'auth.wedu-lab.test'],
    nativeRecovery: {
      ...baseResult().nativeRecovery,
      triggerHost: 'nce.wedu.comunidad.madrid',
      portalRecoveryHosts: [],
      bootstrapHosts,
      redirectHosts,
      resourceHosts,
      effectiveExactHosts: weduHosts,
      allowedHosts: weduHosts,
    },
    ...overrides,
  });
}

function browserBefore(overrides = {}) {
  return {
    portalDetected: true,
    ...overrides,
  };
}

function browserAfter(overrides = {}) {
  return {
    portalMarkerAbsent: true,
    externalNavigationFunctional: true,
    failureKind: 'none',
    ...overrides,
  };
}

function limitedDns(overrides = {}) {
  return {
    success: true,
    server: '127.0.0.1',
    upstreamSource: 'dhcp-nameserver',
    hosts: [
      {
        host: 'nce.wedu.comunidad.madrid',
        resolvedThroughLocalDns: true,
        answers: ['10.77.0.1'],
        addresses: ['10.77.0.1'],
        isConfiguredPortalDomain: true,
        error: '',
      },
    ],
    negativeControl: {
      host: 'this-should-be-blocked-test-12345.com',
      blocked: true,
      error: '',
    },
    ...overrides,
  };
}

function browserLimited(overrides = {}) {
  return {
    browserLimited: {
      portalReady: true,
      loginSubmitted: true,
      finalLoginHost: 'wlogin.wedu-lab.test',
    },
    limitedModeReady: true,
    bootstrapHosts: ['nce.wedu.comunidad.madrid', 'wlogin.wedu-lab.test'],
    pendingRuntimeHosts: [],
    discoveryTruncated: false,
    fallbackMode: 'none',
    limitedDns: limitedDns(),
    ...overrides,
  };
}

function postAuthDns(overrides = {}) {
  return {
    capturedAt: '2026-05-28T00:00:00.000Z',
    resolverServer: '127.0.0.1',
    queries: [
      {
        domain: 'www.msftconnecttest.com',
        success: true,
        addresses: ['13.107.4.52'],
        error: '',
      },
    ],
    adapters: [
      {
        interfaceAlias: 'Ethernet',
        dnsServers: ['127.0.0.1'],
      },
    ],
    ...overrides,
  };
}

function networkAfter(overrides = {}) {
  return {
    capturedAt: '2026-05-28T00:00:05.000Z',
    adapters: [
      {
        interfaceAlias: 'Ethernet',
        interfaceIndex: 8,
        ipv4Addresses: ['10.77.0.50'],
        ipv4DefaultGateway: ['10.77.0.1'],
        dnsServers: ['127.0.0.1'],
      },
    ],
    acrylic: {
      configPath: 'C:\\Acrylic DNS Proxy\\AcrylicConfiguration.ini',
      configRead: true,
      primaryServerAddress: '10.77.0.1',
      secondaryServerAddress: '1.1.1.1',
      serverAddresses: ['10.77.0.1', '1.1.1.1'],
      error: '',
    },
    ...overrides,
  };
}

function openPathProtectionAfter(overrides = {}) {
  return {
    blockedDomain: 'this-should-be-blocked-test-12345.com',
    blockedByOpenPath: true,
    blockedError: '',
    allowedDomain: 'www.msftconnecttest.com',
    allowedDomainFunctional: true,
    allowedError: '',
    protectedModeRestored: true,
    server: '127.0.0.1',
    adapterLocalDnsRestored: true,
    adaptersUsingLocalDns: ['Ethernet'],
    acrylicPrimaryServerAddress: '10.77.0.1',
    acrylicSecondaryServerAddress: '1.1.1.1',
    acrylicNxWildcardPresent: true,
    acrylicCaptivePortalSectionPresent: false,
    ...overrides,
  };
}

function targetPlatformFiles(overrides = {}) {
  return {
    'wedu-lab-dns-limited.json': limitedDns(overrides.limitedDns),
    'wedu-lab-browser-limited.json': browserLimited(overrides.browserLimited),
    'wedu-lab-browser-post-auth.json': browserAfter(overrides.browserAfter),
    'wedu-lab-dns-post-auth.json': postAuthDns(overrides.postAuthDns),
    'wedu-lab-network-after.json': networkAfter(overrides.networkAfter),
    'wedu-lab-openpath-protection-after.json': openPathProtectionAfter(
      overrides.openPathProtectionAfter
    ),
  };
}

describe('WEDU captive portal result validator', () => {
  test('defaults to lab-direct and accepts evidence without schemaVersion or target platform clearance', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': baseResult({
        schemaVersion: undefined,
        targetPlatformSymptomCleared: false,
      }),
      'wedu-lab-browser-before.json': browserBefore(),
    });

    assert.doesNotThrow(() => assertWeduCaptivePortalResult({ artifactDir }));
  });

  test('rejects lab-direct evidence when required result fields are missing', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': baseResult({
        nativeRecovery: {
          success: true,
          portalModeActive: true,
          recoveryHostsApplied: false,
        },
      }),
      'wedu-lab-browser-before.json': browserBefore(),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'lab-direct' }),
      /nativeRecovery\.recoveryHostsApplied/
    );
  });

  test('rejects lab-direct evidence when the portal was not detected', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': baseResult({
        targetPlatformSymptomCleared: false,
      }),
      'wedu-lab-browser-before.json': browserBefore({ portalDetected: false }),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'lab-direct' }),
      /portalDetected/
    );
  });

  test('rejects lab-direct artifacts in target-platform mode', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': baseResult({
        targetPlatformSymptomCleared: false,
      }),
      'wedu-lab-browser-before.json': browserBefore(),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /targetPlatformSymptomCleared/
    );
  });

  test('accepts target-platform evidence with post-auth browser proof', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles(),
    });

    assert.doesNotThrow(() =>
      assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' })
    );
  });

  test('accepts target-platform evidence without dynamic discovery diagnostics', () => {
    const declaredHostResult = baseResult({
      bootstrapHosts: ['nce.wedu.comunidad.madrid'],
      redirectHosts: [],
      resourceHosts: [],
      observedRuntimeHosts: [],
      pendingRuntimeHosts: ['assets.wedu-lab.test'],
      discoveryTruncated: true,
      nativeRecovery: {
        ...baseResult().nativeRecovery,
        triggerHost: 'nce.wedu.comunidad.madrid',
        portalRecoveryHosts: ['nce.wedu.comunidad.madrid'],
        bootstrapHosts: ['nce.wedu.comunidad.madrid'],
        redirectHosts: [],
        resourceHosts: [],
        observedRuntimeHosts: [],
        pendingRuntimeHosts: ['assets.wedu-lab.test'],
        discoveryTruncated: true,
        effectiveExactHosts: ['nce.wedu.comunidad.madrid'],
        allowedHosts: ['nce.wedu.comunidad.madrid'],
      },
    });

    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': declaredHostResult,
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles({
        browserLimited: {
          bootstrapHosts: ['nce.wedu.comunidad.madrid'],
          redirectHosts: [],
          resourceHosts: [],
          observedRuntimeHosts: [],
          pendingRuntimeHosts: ['assets.wedu-lab.test'],
          discoveryTruncated: true,
        },
      }),
    });

    assert.doesNotThrow(() =>
      assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' })
    );
  });

  test('accepts target-platform evidence with declared WEDU portal hosts', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult({
        nativeRecovery: {
          ...discoveredHostResult().nativeRecovery,
          portalRecoveryHosts: [
            'wlogin.wedu-lab.test',
            'assets.wedu-lab.test',
            'cdn.wedu-lab.test',
            'auth.wedu-lab.test',
          ],
        },
      }),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles(),
    });

    assert.doesNotThrow(() =>
      assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' })
    );
  });

  test('accepts target-platform evidence missing dynamically discovered WEDU hosts', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult({
        nativeRecovery: {
          ...discoveredHostResult().nativeRecovery,
          effectiveExactHosts: ['nce.wedu.comunidad.madrid', 'wlogin.wedu-lab.test'],
          allowedHosts: ['nce.wedu.comunidad.madrid', 'wlogin.wedu-lab.test'],
        },
      }),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles(),
    });

    assert.doesNotThrow(() =>
      assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' })
    );
  });

  test('accepts target-platform evidence with dynamic hosts retained as diagnostics', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult({
        bootstrapHosts: [
          'nce.wedu.comunidad.madrid',
          'wlogin.wedu-lab.test',
          'assets.wedu-lab.test',
        ],
      }),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles(),
    });

    assert.doesNotThrow(() =>
      assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' })
    );
  });

  test('accepts Windows JSON artifacts with a UTF-8 BOM', () => {
    const artifactDir = makeArtifactDir();
    writeJsonFile(
      artifactDir,
      'direct-captive-portal-wedu-lab-result.json',
      discoveredHostResult(),
      {
        bom: true,
      }
    );
    writeJsonFile(artifactDir, 'wedu-lab-browser-before.json', browserBefore(), { bom: true });
    writeJsonFile(artifactDir, 'wedu-lab-dns-limited.json', limitedDns(), { bom: true });
    writeJsonFile(artifactDir, 'wedu-lab-browser-limited.json', browserLimited(), { bom: true });
    writeJsonFile(artifactDir, 'wedu-lab-browser-post-auth.json', browserAfter(), { bom: true });
    writeJsonFile(artifactDir, 'wedu-lab-dns-post-auth.json', postAuthDns(), { bom: true });
    writeJsonFile(artifactDir, 'wedu-lab-network-after.json', networkAfter(), { bom: true });
    writeJsonFile(
      artifactDir,
      'wedu-lab-openpath-protection-after.json',
      openPathProtectionAfter(),
      { bom: true }
    );

    assert.doesNotThrow(() =>
      assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' })
    );
  });

  test('accepts target-platform evidence with harness post-auth field names', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles({
        browserAfter: {
          portalMarkerAbsent: true,
          postAuthBrowserNavigationVerified: true,
          postAuthFailureKind: 'none',
        },
      }),
    });

    assert.doesNotThrow(() =>
      assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' })
    );
  });

  test('rejects target-platform evidence when post-auth navigation failed', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles({
        browserAfter: {
          externalNavigationFunctional: false,
          failureKind: 'navigation-failed',
        },
      }),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /externalNavigationFunctional/
    );
  });

  test('rejects target-platform evidence without standalone protection-after artifact', () => {
    const files = targetPlatformFiles();
    delete files['wedu-lab-openpath-protection-after.json'];
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...files,
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /wedu-lab-openpath-protection-after\.json/
    );
  });

  test('rejects target-platform evidence when post-auth protection is not restored', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles({
        openPathProtectionAfter: {
          blockedByOpenPath: false,
          protectedModeRestored: false,
        },
      }),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /wedu-lab-openpath-protection-after\.json blockedByOpenPath/
    );
  });

  test('rejects target-platform evidence when the post-auth protection artifact does not prove local loopback DNS', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles({
        openPathProtectionAfter: {
          server: '10.77.0.1',
          adapterLocalDnsRestored: false,
          adaptersUsingLocalDns: [],
        },
      }),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /wedu-lab-openpath-protection-after\.json server/
    );
  });

  test('rejects target-platform evidence when the post-auth protection artifact omits local adapter proof', () => {
    const protection = openPathProtectionAfter();
    delete protection.adapterLocalDnsRestored;
    const files = targetPlatformFiles();
    files['wedu-lab-openpath-protection-after.json'] = protection;
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...files,
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /wedu-lab-openpath-protection-after\.json adapterLocalDnsRestored/
    );
  });

  test('rejects target-platform evidence when the post-auth Acrylic proof is incomplete', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles({
        openPathProtectionAfter: {
          acrylicNxWildcardPresent: true,
          acrylicCaptivePortalSectionPresent: true,
        },
      }),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /wedu-lab-openpath-protection-after\.json acrylicCaptivePortalSectionPresent/
    );
  });

  test('rejects target-platform evidence without useful post-auth DNS queries', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles({
        postAuthDns: {
          queries: [],
        },
      }),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /wedu-lab-dns-post-auth\.json queries/
    );
  });

  test('rejects target-platform evidence without post-auth local resolver adapter content', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles({
        postAuthDns: {
          adapters: [{ interfaceAlias: 'Ethernet', dnsServers: ['10.77.0.1'] }],
        },
      }),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /wedu-lab-dns-post-auth\.json adapters must include local DNS server 127\.0\.0\.1/
    );
  });

  test('rejects target-platform evidence without a post-auth network snapshot using local DNS', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': discoveredHostResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles({
        networkAfter: {
          adapters: [{ interfaceAlias: 'Ethernet', dnsServers: ['10.77.0.1'] }],
        },
      }),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /wedu-lab-network-after\.json adapters must include local DNS server 127\.0\.0\.1/
    );
  });

  test('rejects target-platform evidence without limited-mode readiness proof', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': baseResult({
        limitedModeReady: false,
        nativeRecovery: discoveredHostResult().nativeRecovery,
        bootstrapHosts: discoveredHostResult().bootstrapHosts,
        observedRuntimeHosts: discoveredHostResult().observedRuntimeHosts,
      }),
      'wedu-lab-browser-before.json': browserBefore(),
      ...targetPlatformFiles(),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /limitedModeReady/
    );
  });
});
