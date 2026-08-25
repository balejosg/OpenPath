import fs from 'node:fs';
import path from 'node:path';

import express from 'express';
import type { Request, Response } from 'express';
import { createExpressMiddleware } from '@trpc/server/adapters/express';

import type { Config } from './config.js';
import { logger } from './lib/logger.js';
import { registerPublicRequestRoutes } from './routes/public-requests.js';
import { registerCoreRoutes } from './routes/core.js';
import { registerExtensionRoutes } from './routes/extensions.js';
import { registerSetupRoutes } from './routes/setup.js';
import { registerEnrollmentRoutes } from './routes/enrollment.js';
import { registerMachineRoutes } from './routes/machines.js';
import { registerWindowsOfflineInstallerRoutes } from './routes/windows-offline-installer.js';
import { registerTestSupportRoutes } from './routes/test-support.js';
import { createContext } from './trpc/context.js';
import { appRouter } from './trpc/routers/index.js';
import { logTrpcError } from './trpc/trpc.js';
import { getReactSpaPath, shouldServeSpaFallback } from './app-bootstrap-helpers.js';

interface RouteDependencies {
  currentDirname: string;
  getCurrentEvaluationTime: () => Date;
  getSwaggerSpec: (() => object) | undefined;
  setTestNowOverride: (value: Date | null) => void;
  swaggerUi: typeof import('swagger-ui-express') | undefined;
}

export function registerAppRoutes(
  app: express.Express,
  runtimeConfig: Config,
  deps: RouteDependencies
): void {
  registerCoreRoutes(app);
  registerExtensionRoutes(app);
  registerPublicRequestRoutes(app);
  registerSetupRoutes(app);
  registerEnrollmentRoutes(app);
  registerTestSupportRoutes(app, {
    getCurrentEvaluationTime: deps.getCurrentEvaluationTime,
    setTestNowOverride: deps.setTestNowOverride,
  });
  registerMachineRoutes(app, { getCurrentEvaluationTime: deps.getCurrentEvaluationTime });
  registerWindowsOfflineInstallerRoutes(app);

  registerSwaggerRoutes(app, deps.swaggerUi, deps.getSwaggerSpec);
  registerTrpcRoutes(app);
  registerV2Fallback(app);
  registerSpaRoutes(app, runtimeConfig, deps.currentDirname);
}

function registerSwaggerRoutes(
  app: express.Express,
  swaggerUi?: typeof import('swagger-ui-express'),
  getSwaggerSpec?: () => object
): void {
  if (!swaggerUi || !getSwaggerSpec) {
    return;
  }

  app.use(
    '/api-docs',
    swaggerUi.serve,
    swaggerUi.setup(getSwaggerSpec(), {
      customCss: '.swagger-ui .topbar { display: none }',
      customSiteTitle: 'OpenPath API Documentation',
    })
  );

  app.get('/api-docs.json', (_req: Request, res: Response): void => {
    res.setHeader('Content-Type', 'application/json');
    res.send(getSwaggerSpec());
  });
}

function registerTrpcRoutes(app: express.Express): void {
  app.use(
    '/trpc',
    createExpressMiddleware({
      router: appRouter,
      createContext,
      onError({ path, ctx, error }) {
        logTrpcError({ path, ctx, error });
      },
    })
  );
}

function registerV2Fallback(app: express.Express): void {
  app.use('/v2', (_req, res) => {
    res.status(404).type('text/plain').send('Not found');
  });
}

function registerSpaRoutes(
  app: express.Express,
  runtimeConfig: Config,
  currentDirname: string
): void {
  const reactSpaPath = getReactSpaPath(currentDirname);

  logger.info('React SPA path check', {
    path: reactSpaPath,
    exists: fs.existsSync(reactSpaPath),
    __dirname: currentDirname,
    isCompiledCode: currentDirname.includes('/dist'),
  });

  if (!fs.existsSync(reactSpaPath)) {
    return;
  }

  app.use(express.static(reactSpaPath));
  logger.info('React SPA enabled at /', {
    isProduction: runtimeConfig.isProduction,
  });

  app.get(/.*/, (req: Request, res: Response, next) => {
    const url = req.originalUrl || req.url;
    if (!shouldServeSpaFallback(url)) {
      next();
      return;
    }

    res.sendFile(path.join(reactSpaPath, 'index.html'));
  });
}
