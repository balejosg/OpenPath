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

interface MaintenanceLogger {
  warn: (message: string, metadata?: Record<string, unknown>) => void;
}

export interface WindowsOfflineInstallerMaintenance {
  runStartupCleanup: () => Promise<void>;
  start: () => void;
  stop: () => void;
}

export interface WindowsOfflineInstallerMaintenanceDeps {
  cleanupExpired?: (artifactsDir: string, options?: CleanupExpiredOptions) => Promise<number>;
  clearIntervalImpl?: typeof clearInterval;
  env?: Readonly<Record<string, string | undefined>>;
  intervalMs?: number;
  loggerInstance?: MaintenanceLogger;
  refs?: Pick<WindowsOfflineDownloadRefsService, 'cleanupExpired'>;
  setIntervalImpl?: typeof setInterval;
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
  const intervalMs = deps.intervalMs ?? DEFAULT_CLEANUP_INTERVAL_MS;
  let interval: ReturnType<typeof setInterval> | undefined;
  let running = false;

  async function runCleanup(): Promise<void> {
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

  function stop(): void {
    if (interval === undefined) return;
    running = false;
    clearIntervalImpl(interval);
    interval = undefined;
  }

  return {
    runStartupCleanup: runCleanup,
    start,
    stop,
  };
}
