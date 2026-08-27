import {
  normalizeAptRepoUrl,
  parseBooleanEnv,
  parseDatabaseUrl,
  parseIntEnv,
  parseListEnv,
  parseTrustProxyEnv,
  resolveJwtSecret,
} from './config-env.js';
import { isWindowsOfflineInstallerConfigured } from './lib/windows-offline-installer-config.js';

const DEFAULT_DATABASE_URL = ['postgres://', 'openpath:openpath@localhost:5432/openpath'].join('');
const DEFAULT_ENROLLMENT_TOKEN_MAX_TTL_HOURS = 24;

function parsePositiveIntEnv(value: string | undefined, fallback: number, name: string): number {
  if (!value) return fallback;
  if (!/^\d+$/.test(value)) {
    throw new Error(`${name} must be a positive integer`);
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

function parsePublicUrl(value: string | undefined, nodeEnv: string): string | undefined {
  const trimmed = value?.trim();
  if (!trimmed) return undefined;

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new Error('PUBLIC_URL must be a valid absolute URL');
  }

  if (!parsed.hostname || parsed.username || parsed.password) {
    throw new Error('PUBLIC_URL must contain a hostname and no URL credentials');
  }
  if (parsed.search || parsed.hash) {
    throw new Error('PUBLIC_URL must not contain a query string or fragment');
  }
  if (nodeEnv === 'production' && parsed.protocol !== 'https:') {
    throw new Error('PUBLIC_URL must use HTTPS in production');
  }

  return trimmed;
}

export interface LoadedConfig {
  readonly port: number;
  readonly host: string;
  readonly publicUrl: string | undefined;
  readonly nodeEnv: string;
  readonly trustProxy: boolean | number | string | undefined;
  readonly isProduction: boolean;
  readonly isTest: boolean;
  readonly aptRepoUrl: string;
  readonly enableRateLimitInTest: boolean;
  readonly bcryptRounds: number;
  readonly jwtSecret: string;
  readonly jwtAccessExpiry: string;
  readonly jwtRefreshExpiry: string;
  readonly enrollmentTokenMaxTtlHours: number;
  readonly googleClientId: string;
  readonly globalRateLimitWindowMs: number;
  readonly globalRateLimitMax: number;
  readonly agentDeliveryRateLimitWindowMs: number;
  readonly agentDeliveryRateLimitMax: number;
  readonly authRateLimitWindowMs: number;
  readonly authRateLimitMax: number;
  readonly corsAllowedOrigins: string[];
  readonly vapidPublicKey: string;
  readonly vapidPrivateKey: string;
  readonly vapidSubject: string;
  readonly pushIconPath: string;
  readonly pushBadgePath: string;
  readonly databaseUrl: string;
  readonly database: {
    readonly host: string;
    readonly port: number;
    readonly name: string;
    readonly user: string;
    readonly password: string;
    readonly poolMax: number;
  };
  readonly logLevel: string;
  readonly enableSwagger: boolean;
}

export function loadConfig(
  env: Readonly<Record<string, string | undefined>> = process.env
): LoadedConfig {
  const parsedDbUrl = parseDatabaseUrl(env.DATABASE_URL);
  const nodeEnv = env.NODE_ENV ?? 'development';
  const corsAllowedOrigins = parseListEnv(
    env.CORS_ORIGINS,
    nodeEnv === 'production'
      ? []
      : ['http://localhost:3000', 'http://localhost:5500', 'http://127.0.0.1:3000']
  );

  if (nodeEnv === 'production' && corsAllowedOrigins.includes('*')) {
    throw new Error('CORS_ORIGINS must not include * in production');
  }

  const publicUrl = parsePublicUrl(env.PUBLIC_URL, nodeEnv);
  if (nodeEnv === 'production' && isWindowsOfflineInstallerConfigured(env) && !publicUrl) {
    throw new Error('PUBLIC_URL is required when the offline installer is configured');
  }

  return {
    port: parseIntEnv(env.PORT, 3000),
    host: env.HOST ?? '0.0.0.0',
    publicUrl,
    nodeEnv,
    trustProxy: parseTrustProxyEnv(env.TRUST_PROXY),
    isProduction: nodeEnv === 'production',
    isTest: nodeEnv === 'test',
    aptRepoUrl:
      normalizeAptRepoUrl(env.APT_REPO_URL) ??
      'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt',
    enableRateLimitInTest: parseBooleanEnv(env.ENABLE_RATE_LIMIT_IN_TEST, false),
    bcryptRounds: parseIntEnv(env.BCRYPT_ROUNDS, 12),
    jwtSecret: resolveJwtSecret(env, nodeEnv),
    jwtAccessExpiry: env.JWT_ACCESS_EXPIRY ?? env.JWT_EXPIRES_IN ?? '24h',
    jwtRefreshExpiry: env.JWT_REFRESH_EXPIRY ?? env.JWT_REFRESH_EXPIRES_IN ?? '7d',
    enrollmentTokenMaxTtlHours: parsePositiveIntEnv(
      env.ENROLLMENT_TOKEN_MAX_TTL_HOURS,
      DEFAULT_ENROLLMENT_TOKEN_MAX_TTL_HOURS,
      'ENROLLMENT_TOKEN_MAX_TTL_HOURS'
    ),
    googleClientId: env.GOOGLE_CLIENT_ID ?? '',
    globalRateLimitWindowMs: parseIntEnv(env.RATE_LIMIT_WINDOW_MS, 60 * 1000),
    globalRateLimitMax: parseIntEnv(env.RATE_LIMIT_MAX, 200),
    agentDeliveryRateLimitWindowMs: parseIntEnv(env.AGENT_DELIVERY_RATE_LIMIT_WINDOW_MS, 60 * 1000),
    agentDeliveryRateLimitMax: parseIntEnv(env.AGENT_DELIVERY_RATE_LIMIT_MAX, 500),
    authRateLimitWindowMs: parseIntEnv(env.AUTH_RATE_LIMIT_WINDOW_MS, 60 * 1000),
    authRateLimitMax: parseIntEnv(env.AUTH_RATE_LIMIT_MAX, 10),
    corsAllowedOrigins,
    vapidPublicKey: env.VAPID_PUBLIC_KEY ?? '',
    vapidPrivateKey: env.VAPID_PRIVATE_KEY ?? '',
    vapidSubject: env.VAPID_SUBJECT ?? 'mailto:admin@openpath.local',
    pushIconPath: env.PUSH_ICON_PATH ?? '/icon-192.png',
    pushBadgePath: env.PUSH_BADGE_PATH ?? '/badge.png',
    databaseUrl: env.DATABASE_URL ?? DEFAULT_DATABASE_URL,
    database: {
      host: parsedDbUrl?.host ?? env.DB_HOST ?? 'localhost',
      port: parsedDbUrl?.port ?? parseIntEnv(env.DB_PORT, 5432),
      name: parsedDbUrl?.name ?? env.DB_NAME ?? 'openpath',
      user: parsedDbUrl?.user ?? env.DB_USER ?? 'openpath',
      password: parsedDbUrl?.password ?? env.DB_PASSWORD ?? 'openpath_dev',
      poolMax: parseIntEnv(env.DB_POOL_MAX, 20),
    },
    logLevel: env.LOG_LEVEL ?? 'info',
    enableSwagger: nodeEnv !== 'production' && env.ENABLE_SWAGGER !== 'false',
  } as const;
}
