import type { Server } from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { getErrorMessage } from '@openpath/shared';

import type { Config } from './config.js';
import { cleanupBlacklist } from './lib/auth.js';
import { logger } from './lib/logger.js';
import { ensureDefaultAdminFromEnv } from './services/default-admin.service.js';
import {
  checkWindowsOfflineInstallerReadiness,
  type WindowsOfflineInstallerReadiness,
} from './lib/windows-offline-installer-readiness.js';
import {
  createWindowsOfflineInstallerMaintenance,
  type WindowsOfflineInstallerMaintenance,
} from './services/windows-offline-installer-maintenance.service.js';

export interface ServerRuntimeDeps {
  cleanupTokenBlacklist: () => Promise<void>;
  ensureDefaultAdmin: (env?: Readonly<Record<string, string | undefined>>) => Promise<void>;
  exitProcess: (code: number) => void;
  initializeSchema: () => Promise<void>;
  loggerInstance: Pick<typeof logger, 'error' | 'info' | 'warn'>;
  processApi: {
    on: (event: string, listener: (...args: unknown[]) => void) => unknown;
  };
  windowsOfflineInstallerMaintenance?: WindowsOfflineInstallerMaintenance;
  verifyWindowsOfflineInstallerPreflight?: (
    env: Readonly<Record<string, string | undefined>>
  ) => Promise<void>;
}

export interface ServerRuntime {
  getServer: () => Server | undefined;
  gracefulShutdown: (signal: string) => void;
  registerProcessHandlers: () => void;
  startServer: () => Promise<Server>;
}

const SHUTDOWN_TIMEOUT_MS = 30000;

function verifyWindowsOfflineInstallerPreflight(
  env: Readonly<Record<string, string | undefined>>
): Promise<void> {
  const readiness: WindowsOfflineInstallerReadiness = checkWindowsOfflineInstallerReadiness({
    env,
  });
  if (!readiness.ready || (env.NODE_ENV === 'production' && readiness.code === 'NOT_CONFIGURED')) {
    return Promise.reject(
      new Error(`Windows offline installer readiness failed: ${readiness.code}`)
    );
  }
  return Promise.resolve();
}

const defaultDeps: ServerRuntimeDeps = {
  cleanupTokenBlacklist: cleanupBlacklist,
  ensureDefaultAdmin: ensureDefaultAdminFromEnv,
  exitProcess: (code) => {
    process.exit(code);
  },
  initializeSchema: async () => {
    const { initializeSchema } = await import('./db/index.js');
    await initializeSchema();
  },
  loggerInstance: logger,
  processApi: process,
  verifyWindowsOfflineInstallerPreflight,
  windowsOfflineInstallerMaintenance: createWindowsOfflineInstallerMaintenance(),
};

interface ListenableApp {
  listen: (port: number, host: string, callback?: () => void) => Server;
}

export function shouldStartServerModule(
  moduleUrl: string,
  argvEntry = process.argv[1],
  env: Readonly<Record<string, string | undefined>> = process.env
): boolean {
  if (env.OPENPATH_FORCE_SERVER_START === 'true') {
    return true;
  }

  return argvEntry !== undefined && moduleUrl === pathToFileURL(path.resolve(argvEntry)).href;
}

function logServerBanner(runtimeConfig: Config, loggerInstance: Pick<typeof logger, 'info'>): void {
  const baseUrl =
    runtimeConfig.publicUrl ?? `http://${runtimeConfig.host}:${String(runtimeConfig.port)}`;
  loggerInstance.info('');
  loggerInstance.info('╔═══════════════════════════════════════════════════════╗');
  loggerInstance.info('║       OpenPath Request API Server                     ║');
  loggerInstance.info('╚═══════════════════════════════════════════════════════╝');
  loggerInstance.info(`Server is running on ${baseUrl}`);
  if (runtimeConfig.enableSwagger) {
    loggerInstance.info(`API Documentation: ${baseUrl}/api-docs`);
  }
  loggerInstance.info(`Health Check: ${baseUrl}/health`);
  loggerInstance.info('─────────────────────────────────────────────────────────');
  loggerInstance.info('');
}

export function createServerRuntime(
  app: ListenableApp,
  runtimeConfig: Config,
  env: Readonly<Record<string, string | undefined>> = process.env,
  deps: ServerRuntimeDeps = defaultDeps
): ServerRuntime {
  let server: Server | undefined;
  let isShuttingDown = false;

  async function onServerStarted(serverStartTime: Date): Promise<void> {
    try {
      await deps.cleanupTokenBlacklist();
      deps.loggerInstance.info('Token blacklist cleanup completed');
    } catch (error) {
      deps.loggerInstance.warn('Token blacklist cleanup failed', {
        error: getErrorMessage(error),
      });
    }

    deps.loggerInstance.info('Server started', {
      host: runtimeConfig.host,
      port: String(runtimeConfig.port),
      env: env.NODE_ENV,
      apiId: env.API_ID,
      startup_time: {
        start: serverStartTime.toISOString(),
        elapsed_ms: String(Date.now() - serverStartTime.getTime()),
      },
    });

    await deps.ensureDefaultAdmin(env);
    logServerBanner(runtimeConfig, deps.loggerInstance);
  }

  async function startServer(): Promise<Server> {
    const serverStartTime = new Date();

    if (env.SKIP_DB_MIGRATIONS !== 'true') {
      await deps.initializeSchema();
    } else {
      deps.loggerInstance.warn('Skipping database migrations (SKIP_DB_MIGRATIONS=true)');
    }

    await (deps.verifyWindowsOfflineInstallerPreflight ?? verifyWindowsOfflineInstallerPreflight)(
      env
    );

    try {
      await deps.windowsOfflineInstallerMaintenance?.runStartupCleanup();
    } catch {
      deps.loggerInstance.warn('offline_installer_maintenance_failed', {
        code: 'STARTUP_CLEANUP_FAILED',
      });
    }

    let startedServer: Server | undefined;
    await new Promise<void>((resolve) => {
      startedServer = app.listen(runtimeConfig.port, runtimeConfig.host, () => {
        resolve();
      });
    });

    if (startedServer === undefined) {
      throw new Error('Server failed to start');
    }

    server = startedServer;
    deps.windowsOfflineInstallerMaintenance?.start();

    void onServerStarted(serverStartTime);

    return server;
  }

  function gracefulShutdown(signal: string): void {
    if (isShuttingDown) {
      deps.loggerInstance.warn(`Shutdown already in progress, ignoring ${signal}`);
      return;
    }
    isShuttingDown = true;

    deps.loggerInstance.info(`Received ${signal}, starting graceful shutdown...`);
    deps.windowsOfflineInstallerMaintenance?.stop();

    const forceShutdownTimeout = setTimeout(() => {
      deps.loggerInstance.error('Graceful shutdown timeout exceeded, forcing exit');
      deps.exitProcess(1);
    }, SHUTDOWN_TIMEOUT_MS);

    const finish = (exitCode: number): void => {
      clearTimeout(forceShutdownTimeout);
      deps.exitProcess(exitCode);
    };

    if (server === undefined) {
      deps.loggerInstance.info('No active server instance to close');
      finish(0);
      return;
    }

    server.close((error) => {
      if (error) {
        deps.loggerInstance.error('Error during server close', { error: error.message });
        finish(1);
        return;
      }
      deps.loggerInstance.info('Server closed, no longer accepting connections');
      finish(0);
    });
  }

  function registerProcessHandlers(): void {
    deps.processApi.on('SIGTERM', () => {
      gracefulShutdown('SIGTERM');
    });
    deps.processApi.on('SIGINT', () => {
      gracefulShutdown('SIGINT');
    });
    deps.processApi.on('uncaughtException', (error) => {
      deps.loggerInstance.error('Uncaught exception', {
        error: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : undefined,
      });
      gracefulShutdown('uncaughtException');
    });
    deps.processApi.on('unhandledRejection', (reason) => {
      deps.loggerInstance.error('Unhandled rejection', {
        reason: reason instanceof Error ? reason.message : String(reason),
        stack: reason instanceof Error ? reason.stack : undefined,
      });
    });
  }

  return {
    getServer: () => server,
    gracefulShutdown,
    registerProcessHandlers,
    startServer,
  };
}
