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
    hosts: [
      {
        host: 'nce.wedu.comunidad.madrid',
        resolvedThroughLocalDns: true,
        answers: ['10.77.0.1'],
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
    queries: [],
    ...overrides,
  };
}

function targetPlatformFiles(overrides = {}) {
  return {
    'wedu-lab-dns-limited.json': limitedDns(overrides.limitedDns),
    'wedu-lab-browser-limited.json': browserLimited(overrides.browserLimited),
    'wedu-lab-browser-post-auth.json': browserAfter(overrides.browserAfter),
    'wedu-lab-dns-post-auth.json': postAuthDns(overrides.postAuthDns),
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

  test('rejects target-platform evidence that preinjects WEDU portal hosts', () => {
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

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /nativeRecovery\.portalRecoveryHosts must not preinject/
    );
  });

  test('rejects target-platform evidence missing dynamically discovered WEDU hosts', () => {
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

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /nativeRecovery\.effectiveExactHosts must include assets\.wedu-lab\.test/
    );
  });

  test('rejects target-platform evidence that mixes discovered hosts into bootstrapHosts', () => {
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

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /bootstrapHosts must not include redirect\/resource hosts/
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
