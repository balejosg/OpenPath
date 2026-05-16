import express from 'express';

import { registerAuthRoutes } from './app-auth.js';
import { registerErrorHandlers } from './app-errors.js';
import { registerDashboardRoutes } from './app-groups.js';
import { registerCommonMiddleware } from './app-middleware.js';

const DEVELOPMENT_COOKIE_SECRET = 'dashboard-dev-secret';

export interface DashboardAppOptions {
  cookieSecret?: string;
  cookieSecure?: boolean;
}

export function resolveDashboardCookieSecret(
  cookieSecret = process.env.COOKIE_SECRET,
  nodeEnv = process.env.NODE_ENV
): string {
  if (nodeEnv === 'production') {
    if (!cookieSecret || cookieSecret === DEVELOPMENT_COOKIE_SECRET) {
      throw new Error('COOKIE_SECRET must be set to a non-default value in production');
    }
    return cookieSecret;
  }

  return cookieSecret ?? DEVELOPMENT_COOKIE_SECRET;
}

export function createDashboardApp(options: DashboardAppOptions = {}): express.Express {
  const app = express();

  registerCommonMiddleware(app, resolveDashboardCookieSecret(options.cookieSecret));
  registerAuthRoutes(app, { cookieSecure: options.cookieSecure ?? false });
  registerDashboardRoutes(app);
  registerErrorHandlers(app);

  return app;
}
