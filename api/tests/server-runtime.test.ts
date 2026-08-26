import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'server-runtime-test-secret';

function createLogger(events: string[]): {
  error: (message: string) => void;
  info: (message: string) => void;
  warn: (message: string) => void;
} {
  return {
    error: (message: string): void => {
      events.push(`error:${message}`);
    },
    info: (message: string): void => {
      events.push(`info:${message}`);
    },
    warn: (message: string): void => {
      events.push(`warn:${message}`);
    },
  };
}

await describe('server runtime', async () => {
  const { loadConfig } = await import('../src/config.js');
  const { createServerRuntime, shouldStartServerModule } = await import('../src/server-runtime.js');

  await test('shouldStartServerModule respects force-start env', () => {
    assert.equal(
      shouldStartServerModule('file:///tmp/server.ts', undefined, {
        OPENPATH_FORCE_SERVER_START: 'true',
      }),
      true
    );
    assert.equal(shouldStartServerModule('file:///tmp/server.ts', '/tmp/other.ts', {}), false);
  });

  await test('startServer skips migrations when configured and runs startup hooks', async () => {
    const events: string[] = [];
    const fakeServer = {
      close: (callback: (error?: Error) => void): void => {
        callback();
      },
    };
    const fakeApp = {
      listen: (_port: number, _host: string, callback?: () => void): typeof fakeServer => {
        events.push('listen');
        callback?.();
        return fakeServer;
      },
    };
    const config = loadConfig({
      ...process.env,
      NODE_ENV: 'test',
      JWT_SECRET: 'server-runtime-test-secret',
      HOST: '127.0.0.1',
      PORT: '3011',
      ENABLE_SWAGGER: 'false',
    });

    const runtime = createServerRuntime(
      fakeApp as never,
      config,
      { ...process.env, SKIP_DB_MIGRATIONS: 'true' },
      {
        cleanupTokenBlacklist: () => {
          events.push('cleanup');
          return Promise.resolve();
        },
        ensureDefaultAdmin: () => {
          events.push('default-admin');
          return Promise.resolve();
        },
        exitProcess: (): void => undefined,
        initializeSchema: () => {
          events.push('init-schema');
          return Promise.resolve();
        },
        loggerInstance: createLogger(events),
        processApi: {
          on: () => undefined,
        },
      }
    );

    await runtime.startServer();
    await new Promise((resolve) => setImmediate(resolve));

    assert.equal(events.includes('init-schema'), false);
    assert.equal(events.includes('listen'), true);
    assert.equal(events.includes('cleanup'), true);
    assert.equal(events.includes('default-admin'), true);
  });

  await test('runs the offline installer readiness preflight before accepting traffic', async () => {
    const events: string[] = [];
    const fakeApp = {
      listen: (_port: number, _host: string, callback?: () => void): { close: () => void } => {
        events.push('listen');
        callback?.();
        return { close: (): void => undefined };
      },
    };
    const config = loadConfig({
      ...process.env,
      NODE_ENV: 'test',
      JWT_SECRET: 'server-runtime-test-secret',
      HOST: '127.0.0.1',
      PORT: '3012',
      ENABLE_SWAGGER: 'false',
    });

    const runtime = createServerRuntime(
      fakeApp as never,
      config,
      { ...process.env, SKIP_DB_MIGRATIONS: 'true' },
      {
        cleanupTokenBlacklist: () => Promise.resolve(),
        ensureDefaultAdmin: () => Promise.resolve(),
        exitProcess: (): void => undefined,
        initializeSchema: () => Promise.resolve(),
        loggerInstance: createLogger(events),
        processApi: { on: () => undefined },
        verifyWindowsOfflineInstallerPreflight: (): Promise<void> => {
          events.push('offline-preflight');
          return Promise.resolve();
        },
      }
    );

    await runtime.startServer();
    assert.equal(events.indexOf('offline-preflight') < events.indexOf('listen'), true);
  });

  await test('does not expose a public production server with an unconfigured installer', async () => {
    const events: string[] = [];
    const fakeApp = {
      listen: (): { close: () => void } => {
        events.push('listen');
        return { close: (): void => undefined };
      },
    };
    const productionEnv = {
      NODE_ENV: 'production',
      JWT_SECRET: 'server-runtime-production-secret',
      SKIP_DB_MIGRATIONS: 'true',
    };
    const config = loadConfig(productionEnv);
    const runtime = createServerRuntime(fakeApp as never, config, productionEnv, {
      cleanupTokenBlacklist: () => Promise.resolve(),
      ensureDefaultAdmin: () => Promise.resolve(),
      exitProcess: (): void => undefined,
      initializeSchema: () => Promise.resolve(),
      loggerInstance: createLogger(events),
      processApi: { on: () => undefined },
    });

    await assert.rejects(() => runtime.startServer(), /readiness failed: NOT_CONFIGURED/u);
    assert.equal(events.includes('listen'), false);
  });

  await test('registerProcessHandlers wires signal and error handlers', () => {
    const handlers: string[] = [];
    const config = loadConfig({
      ...process.env,
      NODE_ENV: 'test',
      JWT_SECRET: 'server-runtime-test-secret',
      ENABLE_SWAGGER: 'false',
    });
    const listenOnlyApp = {
      listen: (): { close: () => void } => ({ close: (): void => undefined }),
    };
    const runtime = createServerRuntime(listenOnlyApp as never, config, process.env, {
      cleanupTokenBlacklist: () => Promise.resolve(),
      ensureDefaultAdmin: () => Promise.resolve(),
      exitProcess: (): void => undefined,
      initializeSchema: () => Promise.resolve(),
      loggerInstance: createLogger(handlers),
      processApi: {
        on: (event): void => {
          handlers.push(event);
        },
      },
    });

    runtime.registerProcessHandlers();

    assert.deepEqual(handlers, ['SIGTERM', 'SIGINT', 'uncaughtException', 'unhandledRejection']);
  });
});
