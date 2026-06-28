import compression from 'compression';
import cors from 'cors';
import express from 'express';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';

import type { Config } from './config.js';
import { requestIdMiddleware } from './lib/error-tracking.js';
import { logger } from './lib/logger.js';
import { isCookieAuthenticatedMutation, isTrustedCsrfOrigin } from './lib/server-request-auth.js';
import { shouldBypassCompression } from './app-bootstrap-helpers.js';

export function getTrustedBrowserOrigins(runtimeConfig: Config): string[] {
  return [
    ...runtimeConfig.corsAllowedOrigins,
    ...(runtimeConfig.publicUrl ? [new URL(runtimeConfig.publicUrl).origin] : []),
  ];
}

export function registerAppMiddleware(
  app: express.Express,
  runtimeConfig: Config,
  trustedBrowserOrigins: string[]
): void {
  if (runtimeConfig.trustProxy !== undefined) {
    app.set('trust proxy', runtimeConfig.trustProxy);
    logger.info('Express trust proxy configured', { trustProxy: runtimeConfig.trustProxy });
  }

  registerSecurityHeaders(app, runtimeConfig);
  registerExtensionRequestCors(app, runtimeConfig);
  registerCors(app, runtimeConfig);
  registerRateLimits(app, runtimeConfig);

  app.use(express.json({ limit: '10kb' }));
  app.use(requestIdMiddleware);
  registerCsrfProtection(app, trustedBrowserOrigins);
  app.use(logger.requestMiddleware);

  app.use(
    compression({
      filter: (req, res) => {
        if (shouldBypassCompression(req.path)) {
          return false;
        }

        return compression.filter(req, res);
      },
    })
  );
}

function registerSecurityHeaders(app: express.Express, runtimeConfig: Config): void {
  const connectSrcDirectives = ["'self'", 'https://accounts.google.com'];
  if (!runtimeConfig.isProduction) {
    connectSrcDirectives.push('http://localhost:*', 'ws://localhost:*');
  }

  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          styleSrc: [
            "'self'",
            "'unsafe-inline'",
            'https://fonts.googleapis.com',
            'https://accounts.google.com',
          ],
          fontSrc: ["'self'", 'https://fonts.gstatic.com'],
          scriptSrc: ["'self'", 'https://accounts.google.com/gsi/client'],
          frameSrc: ["'self'", 'https://accounts.google.com'],
          imgSrc: ["'self'", 'data:', 'https:'],
          connectSrc: connectSrcDirectives,
        },
      },
      frameguard: { action: 'deny' },
      crossOriginEmbedderPolicy: false,
      crossOriginResourcePolicy: { policy: 'cross-origin' },
      crossOriginOpenerPolicy: { policy: 'same-origin-allow-popups' },
    })
  );
}

function registerCors(app: express.Express, runtimeConfig: Config): void {
  const corsOrigins = runtimeConfig.corsAllowedOrigins;

  if (runtimeConfig.isProduction) {
    if (corsOrigins.length === 0) {
      logger.warn('CORS_ORIGINS not set in production - all cross-origin requests will be blocked');
    } else if (corsOrigins.includes('*')) {
      logger.warn('CORS_ORIGINS="*" in production - this is insecure, set explicit origins');
    }
  }

  app.use(
    cors({
      origin(origin, callback) {
        if (!origin) {
          callback(null, true);
          return;
        }

        callback(null, corsOrigins.includes(origin));
      },
      methods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
      allowedHeaders: ['Content-Type', 'Authorization', 'trpc-batch-mode'],
      credentials: true,
    })
  );
}

function registerExtensionRequestCors(app: express.Express, runtimeConfig: Config): void {
  const corsOrigins = runtimeConfig.corsAllowedOrigins;

  app.use(
    '/api/requests/submit',
    cors({
      origin(origin, callback) {
        if (!origin) {
          callback(null, true);
          return;
        }

        callback(null, corsOrigins.includes(origin) || isTrustedExtensionOrigin(origin));
      },
      methods: ['POST', 'OPTIONS'],
      allowedHeaders: ['Content-Type'],
      credentials: false,
    })
  );
}

function isTrustedExtensionOrigin(origin: string): boolean {
  try {
    const parsed = new URL(origin);
    return (
      (parsed.protocol === 'moz-extension:' || parsed.protocol === 'chrome-extension:') &&
      parsed.hostname.length > 0
    );
  } catch {
    return false;
  }
}

function registerRateLimits(app: express.Express, runtimeConfig: Config): void {
  const rateLimitDisabled = runtimeConfig.isTest && !runtimeConfig.enableRateLimitInTest;

  const globalLimiter = rateLimit({
    windowMs: runtimeConfig.globalRateLimitWindowMs,
    max: runtimeConfig.globalRateLimitMax,
    message: {
      success: false,
      error: 'Too many requests from this IP, please try again later',
      code: 'GLOBAL_RATE_LIMITED',
    },
    standardHeaders: true,
    legacyHeaders: false,
    skip: (req) =>
      req.path === '/health' || req.path.startsWith('/api/agent/') || rateLimitDisabled,
  });
  app.use(globalLimiter);

  const agentDeliveryLimiter = rateLimit({
    windowMs: runtimeConfig.agentDeliveryRateLimitWindowMs,
    max: runtimeConfig.agentDeliveryRateLimitMax,
    message: {
      success: false,
      error: 'Too many agent delivery requests from this IP, please try again later',
      code: 'AGENT_DELIVERY_RATE_LIMITED',
    },
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: (req) => req.ip ?? 'unknown',
    skip: () => rateLimitDisabled,
  });
  app.use('/api/agent', agentDeliveryLimiter);

  const authLimiter = rateLimit({
    windowMs: runtimeConfig.authRateLimitWindowMs,
    max: runtimeConfig.authRateLimitMax,
    message: {
      success: false,
      error: 'Too many authentication attempts, please try again later',
      code: 'AUTH_RATE_LIMITED',
    },
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: (req) => req.ip ?? 'unknown',
    skip: () => rateLimitDisabled,
  });

  const publicRequestLimiter = rateLimit({
    windowMs: 60 * 1000,
    max: 5,
    message: {
      success: false,
      error: 'Too many domain requests, please try again later',
      code: 'REQUEST_RATE_LIMITED',
    },
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: (req) => req.ip ?? 'unknown',
    skip: () => rateLimitDisabled,
  });
  app.use('/trpc/auth.login', authLimiter);
  app.use('/trpc/auth.register', authLimiter);
  app.use('/trpc/auth.googleLogin', authLimiter);
  app.use('/trpc/auth.resetPassword', authLimiter);
  app.use('/trpc/setup.createFirstAdmin', authLimiter);
  app.use('/api/setup/first-admin', authLimiter);

  app.use('/trpc/requests.create', publicRequestLimiter);
  app.use('/api/requests/submit', publicRequestLimiter);
}

function registerCsrfProtection(app: express.Express, trustedBrowserOrigins: string[]): void {
  app.use((req, res, next) => {
    if (!isCookieAuthenticatedMutation(req)) {
      next();
      return;
    }

    if (isTrustedCsrfOrigin(req, trustedBrowserOrigins)) {
      next();
      return;
    }

    logger.warn('Rejected cookie-authenticated request with invalid CSRF origin', {
      path: req.originalUrl || req.url,
      method: req.method,
      origin: req.get('origin'),
      referer: req.get('referer'),
      requestOrigin: `${req.protocol}://${req.get('host') ?? 'localhost'}`,
    });

    res.status(403).json({
      success: false,
      error: 'Invalid CSRF origin',
      code: 'FORBIDDEN',
      requestId: (req as typeof req & { id?: string }).id,
    });
  });
}
