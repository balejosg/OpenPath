import { getStats } from '../lib/user-storage.js';
import { logger } from '../lib/logger.js';
import { getErrorMessage } from '@openpath/shared';
import { checkWindowsOfflineInstallerReadiness } from '../lib/windows-offline-installer-readiness.js';

export interface ReadinessCheckStatus {
  status: string;
  totalRequests?: number;
  error?: string;
}

export interface ReadinessResult {
  status: string;
  service: 'openpath-api';
  uptime: number;
  checks: Record<string, ReadinessCheckStatus>;
  responseTime: string;
}

export async function getReadinessStatus(): Promise<ReadinessResult> {
  const startTime = Date.now();
  const checks: Record<string, ReadinessCheckStatus> = {};
  let status = 'ok';

  try {
    const stats = await getStats();
    checks.storage = { status: 'ok', totalRequests: stats.total };
  } catch (error: unknown) {
    const message = getErrorMessage(error);
    logger.error('Healthcheck readiness check failed', { error: message });
    checks.storage = { status: 'error', error: message };
    status = 'degraded';
  }

  const authConfigured = process.env.JWT_SECRET !== undefined && process.env.JWT_SECRET !== '';
  checks.auth = { status: authConfigured ? 'configured' : 'not_configured' };
  if (!authConfigured) {
    status = 'degraded';
  }

  const windowsOfflineInstaller = checkWindowsOfflineInstallerReadiness();
  checks.windowsOfflineInstaller = {
    status:
      windowsOfflineInstaller.code === 'NOT_CONFIGURED'
        ? 'not_configured'
        : windowsOfflineInstaller.ready
          ? 'ok'
          : 'error',
    ...(windowsOfflineInstaller.ready ? {} : { error: windowsOfflineInstaller.code }),
  };
  if (
    !windowsOfflineInstaller.ready ||
    (process.env.NODE_ENV === 'production' && windowsOfflineInstaller.code === 'NOT_CONFIGURED')
  ) {
    status = 'degraded';
  }

  return {
    status,
    service: 'openpath-api',
    uptime: process.uptime(),
    checks,
    responseTime: `${String(Date.now() - startTime)} ms`,
  };
}

export default {
  getReadinessStatus,
};
