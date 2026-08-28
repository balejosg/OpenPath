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
  await maintenance.stop();
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
  await maintenance.stop();

  assert.equal(warnings.length, 2);
  assert.equal(warnings.join('\n').includes('database secret'), false);
});

void test('serializes slow periodic cleanup and waits for the active run on shutdown', async () => {
  let intervalCallback: (() => void) | undefined;
  let releasePeriodicCleanup!: () => void;
  let cleanupCalls = 0;
  let activeCleanups = 0;
  let maximumConcurrentCleanups = 0;

  const maintenance = createWindowsOfflineInstallerMaintenance({
    env: maintenanceEnv(),
    cleanupExpired: () => {
      cleanupCalls += 1;
      activeCleanups += 1;
      maximumConcurrentCleanups = Math.max(maximumConcurrentCleanups, activeCleanups);
      if (cleanupCalls === 1) {
        activeCleanups -= 1;
        return Promise.resolve(0);
      }
      return new Promise<number>((resolve) => {
        releasePeriodicCleanup = (): void => {
          activeCleanups -= 1;
          resolve(0);
        };
      });
    },
    setIntervalImpl: (callback: () => void) => {
      intervalCallback = callback;
      return 1 as unknown as ReturnType<typeof setInterval>;
    },
    clearIntervalImpl: () => undefined,
  });

  await maintenance.runStartupCleanup();
  maintenance.start();
  intervalCallback?.();
  intervalCallback?.();
  await new Promise((resolve) => setImmediate(resolve));

  let stopped = false;
  const stopPromise = maintenance.stop().then(() => {
    stopped = true;
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(stopped, false);
  assert.equal(cleanupCalls, 2);
  assert.equal(maximumConcurrentCleanups, 1);

  releasePeriodicCleanup();
  await stopPromise;
  assert.equal(stopped, true);
  assert.equal(activeCleanups, 0);
});

void test('bounds shutdown when cleanup never settles and reports only a safe code', async () => {
  const warnings: string[] = [];
  let intervalCallback: (() => void) | undefined;
  let releaseShutdownTimeout: (() => void) | undefined;
  let shutdownTimeoutUnrefCalls = 0;
  const shutdownTimeoutHandle = {
    unref: (): void => {
      shutdownTimeoutUnrefCalls += 1;
    },
  } as unknown as ReturnType<typeof setTimeout>;
  const maintenance = createWindowsOfflineInstallerMaintenance({
    env: maintenanceEnv(),
    cleanupExpired: () => {
      if (intervalCallback === undefined) return Promise.resolve(0);
      return new Promise<number>(() => undefined);
    },
    shutdownTimeoutMs: 20,
    setIntervalImpl: (callback: () => void) => {
      intervalCallback = callback;
      return 1 as unknown as ReturnType<typeof setInterval>;
    },
    clearIntervalImpl: () => undefined,
    setTimeoutImpl: (callback: () => void) => {
      releaseShutdownTimeout = callback;
      return shutdownTimeoutHandle;
    },
    clearTimeoutImpl: () => undefined,
    loggerInstance: {
      warn: (_message, metadata) => {
        warnings.push(JSON.stringify(metadata));
      },
    },
  });

  await maintenance.runStartupCleanup();
  maintenance.start();
  intervalCallback?.();
  const startedAt = Date.now();
  const stopPromise = maintenance.stop();
  await new Promise((resolve) => setImmediate(resolve));
  releaseShutdownTimeout?.();
  await stopPromise;

  assert.equal(Date.now() - startedAt < 500, true);
  assert.equal(warnings.includes(JSON.stringify({ code: 'SHUTDOWN_TIMEOUT' })), true);
  assert.equal(shutdownTimeoutUnrefCalls, 0);
});
