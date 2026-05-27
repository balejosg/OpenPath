import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, test } from 'node:test';

import { assertWeduCaptivePortalResult } from '../scripts/assert-wedu-captive-portal-result.mjs';

function makeArtifactDir(files = {}) {
  const artifactDir = mkdtempSync(join(tmpdir(), 'wedu-result-'));
  for (const [name, payload] of Object.entries(files)) {
    writeFileSync(join(artifactDir, name), JSON.stringify(payload, null, 2));
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
    browserAfterAuthPath: 'wedu-lab-browser-after-auth.json',
    nativeRecovery: {
      success: true,
      portalModeActive: true,
      recoveryHostsApplied: true,
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
      'direct-captive-portal-wedu-lab-result.json': baseResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      'wedu-lab-browser-after-auth.json': browserAfter(),
    });

    assert.doesNotThrow(() =>
      assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' })
    );
  });

  test('accepts target-platform evidence with harness post-auth field names', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': baseResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      'wedu-lab-browser-after-auth.json': {
        portalMarkerAbsent: true,
        postAuthBrowserNavigationVerified: true,
        postAuthFailureKind: 'none',
      },
    });

    assert.doesNotThrow(() =>
      assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' })
    );
  });

  test('rejects target-platform evidence when post-auth navigation failed', () => {
    const artifactDir = makeArtifactDir({
      'direct-captive-portal-wedu-lab-result.json': baseResult(),
      'wedu-lab-browser-before.json': browserBefore(),
      'wedu-lab-browser-after-auth.json': browserAfter({
        externalNavigationFunctional: false,
        failureKind: 'navigation-failed',
      }),
    });

    assert.throws(
      () => assertWeduCaptivePortalResult({ artifactDir, evidenceMode: 'target-platform' }),
      /externalNavigationFunctional/
    );
  });
});
