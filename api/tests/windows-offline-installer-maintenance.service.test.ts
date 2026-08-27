import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createWindowsOfflineInstallerMaintenance } from '../src/services/windows-offline-installer-maintenance.service.js';

function maintenanceEnv(): Record<string, string> {
  return {
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR: '/srv/openpath/templates',
    OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR: '/srv/openpath/artifacts',
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: '4.1.0',
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: 'a'.repeat(40),
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: 'b'.repeat(64),
    OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: 'scripts-v4.1.0-aaaaaaa',
    OPENPATH_WINDOWS_OFFLINE_ARTIFACT_RETENTION_HOURS: '12',
  };
}

void test('runs startup and periodic cleanup even when no installer is generated', async () => {
  const cleanupCalls: { artifactsDir: string; artifactRetentionHours: number }[] = [];
  let intervalCallback: (() => void) | undefined;
  let clearIntervalCalls = 0;

  const maintenance = createWindowsOfflineInstallerMaintenance({
    env: maintenanceEnv(),
    cleanupExpired: (artifactsDir, options) => {
      cleanupCalls.push({
        artifactsDir,
        artifactRetentionHours: options?.artifactRetentionHours ?? 0,
      });
      return Promise.resolve(0);
    },
    setIntervalImpl: (callback: () => void) => {
      intervalCallback = callback;
      return 1 as unknown as ReturnType<typeof setInterval>;
    },
    clearIntervalImpl: () => {
      clearIntervalCalls += 1;
    },
  });

  await maintenance.runStartupCleanup();
  maintenance.start();
  intervalCallback?.();
  await new Promise((resolve) => setImmediate(resolve));
  maintenance.stop();
  intervalCallback?.();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(cleanupCalls.length, 2);
  assert.deepEqual(cleanupCalls[0], {
    artifactsDir: '/srv/openpath/artifacts',
    artifactRetentionHours: 12,
  });
  assert.equal(clearIntervalCalls, 1);
});

void test('contains cleanup failures and stops its ticker cleanly', async () => {
  const warnings: string[] = [];
  let intervalCallback: (() => void) | undefined;

  const maintenance = createWindowsOfflineInstallerMaintenance({
    env: maintenanceEnv(),
    cleanupExpired: () => Promise.reject(new Error('database secret should not be logged')),
    setIntervalImpl: (callback: () => void) => {
      intervalCallback = callback;
      return 1 as unknown as ReturnType<typeof setInterval>;
    },
    clearIntervalImpl: () => undefined,
    loggerInstance: {
      warn: (_message, metadata) => {
        warnings.push(JSON.stringify(metadata));
      },
    },
  });

  await maintenance.runStartupCleanup();
  maintenance.start();
  intervalCallback?.();
  await new Promise((resolve) => setImmediate(resolve));
  maintenance.stop();

  assert.equal(warnings.length, 2);
  assert.equal(warnings.join('\n').includes('database secret'), false);
});
