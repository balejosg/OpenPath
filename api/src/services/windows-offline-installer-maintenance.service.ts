import {
  isWindowsOfflineInstallerConfigured,
  loadWindowsOfflineInstallerConfig,
} from '../lib/windows-offline-installer-config.js';
import { logger } from '../lib/logger.js';
import {
  createWindowsOfflineDownloadRefsService,
  type CleanupExpiredOptions,
  type WindowsOfflineDownloadRefsService,
} from './windows-offline-installer-download-refs.service.js';

const DEFAULT_CLEANUP_INTERVAL_MS = 5 * 60 * 1000;
const DEFAULT_SHUTDOWN_TIMEOUT_MS = 5_000;

interface MaintenanceLogger {
  warn: (message: string, metadata?: Record<string, unknown>) => void;
}

type ShutdownTimeoutHandle = ReturnType<typeof setTimeout>;
type SetTimeoutImpl = (callback: () => void, delay: number) => ShutdownTimeoutHandle;
type ClearTimeoutImpl = (timeout: ShutdownTimeoutHandle) => void;
type MaintenanceIntervalHandle = ReturnType<typeof setInterval>;
type SetIntervalImpl = (callback: () => void, delay: number) => MaintenanceIntervalHandle;
type ClearIntervalImpl = (interval: MaintenanceIntervalHandle) => void;

export interface WindowsOfflineInstallerMaintenance {
  runStartupCleanup: () => Promise<void>;
  start: () => void;
  stop: () => Promise<void>;
}

export interface WindowsOfflineInstallerMaintenanceDeps {
  cleanupExpired?: (artifactsDir: string, options?: CleanupExpiredOptions) => Promise<number>;
  clearIntervalImpl?: ClearIntervalImpl;
  env?: Readonly<Record<string, string | undefined>>;
  intervalMs?: number;
  loggerInstance?: MaintenanceLogger;
  refs?: Pick<WindowsOfflineDownloadRefsService, 'cleanupExpired'>;
  setTimeoutImpl?: SetTimeoutImpl;
  setIntervalImpl?: SetIntervalImpl;
  clearTimeoutImpl?: ClearTimeoutImpl;
  shutdownTimeoutMs?: number;
}

export function createWindowsOfflineInstallerMaintenance(
  deps: WindowsOfflineInstallerMaintenanceDeps = {}
): WindowsOfflineInstallerMaintenance {
  const env = deps.env ?? process.env;
  const configuredRefs = deps.refs;
  const defaultRefs = createWindowsOfflineDownloadRefsService();
  const defaultCleanupExpired = (
    artifactsDir: string,
    options?: CleanupExpiredOptions
  ): Promise<number> => defaultRefs.cleanupExpired(artifactsDir, options);
  const cleanupExpired =
    deps.cleanupExpired ??
    (configuredRefs
      ? (artifactsDir: string, options?: CleanupExpiredOptions): Promise<number> =>
          configuredRefs.cleanupExpired(artifactsDir, options)
      : defaultCleanupExpired);
  const loggerInstance = deps.loggerInstance ?? logger;
  const setIntervalImpl = deps.setIntervalImpl ?? setInterval;
  const clearIntervalImpl = deps.clearIntervalImpl ?? clearInterval;
  const setTimeoutImpl = deps.setTimeoutImpl ?? setTimeout;
  const clearTimeoutImpl = deps.clearTimeoutImpl ?? clearTimeout;
  const intervalMs = deps.intervalMs ?? DEFAULT_CLEANUP_INTERVAL_MS;
  const shutdownTimeoutMs =
    deps.shutdownTimeoutMs !== undefined &&
    Number.isFinite(deps.shutdownTimeoutMs) &&
    deps.shutdownTimeoutMs >= 0
      ? deps.shutdownTimeoutMs
      : DEFAULT_SHUTDOWN_TIMEOUT_MS;
  let interval: ReturnType<typeof setInterval> | undefined;
  let running = false;
  let cleanupInFlight: Promise<void> | undefined;

  async function performCleanup(): Promise<void> {
    if (!isWindowsOfflineInstallerConfigured(env)) return;

    let config;
    try {
      config = loadWindowsOfflineInstallerConfig(env);
    } catch {
      loggerInstance.warn('offline_installer_maintenance_failed', { code: 'CONFIG_INVALID' });
      return;
    }

    try {
      await cleanupExpired(config.artifactsDir, {
        artifactRetentionHours: config.artifactRetentionHours,
      });
    } catch {
      loggerInstance.warn('offline_installer_maintenance_failed', { code: 'CLEANUP_FAILED' });
    }
  }

  function runCleanup(): Promise<void> {
    if (cleanupInFlight !== undefined) return cleanupInFlight;

    const current = performCleanup();
    cleanupInFlight = current;
    void current.then(
      () => {
        if (cleanupInFlight === current) cleanupInFlight = undefined;
      },
      () => {
        if (cleanupInFlight === current) cleanupInFlight = undefined;
      }
    );
    return current;
  }

  function start(): void {
    if (interval !== undefined) return;
    running = true;
    interval = setIntervalImpl(() => {
      if (!running) return;
      void runCleanup();
    }, intervalMs);
    const unref = (interval as unknown as { unref?: () => void }).unref;
    if (typeof unref === 'function') unref.call(interval);
  }

  async function stop(): Promise<void> {
    running = false;
    if (interval !== undefined) {
      clearIntervalImpl(interval);
      interval = undefined;
    }

    const pendingCleanup = cleanupInFlight;
    if (pendingCleanup === undefined) return;

    let timeoutHandle: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<void>((resolve) => {
      timeoutHandle = setTimeoutImpl(() => {
        loggerInstance.warn('offline_installer_maintenance_shutdown_timeout', {
          code: 'SHUTDOWN_TIMEOUT',
        });
        resolve();
      }, shutdownTimeoutMs);
      // Keep the shutdown watchdog referenced. Unlike the periodic ticker,
      // this timer is what guarantees that stop() resolves when cleanup hangs.
    });

    try {
      await Promise.race([pendingCleanup, timeout]);
    } catch {
      loggerInstance.warn('offline_installer_maintenance_failed', { code: 'CLEANUP_FAILED' });
    } finally {
      if (timeoutHandle !== undefined) clearTimeoutImpl(timeoutHandle);
    }
  }

  return {
    runStartupCleanup: runCleanup,
    start,
    stop,
  };
}
