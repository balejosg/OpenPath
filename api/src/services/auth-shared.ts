import jwt from 'jsonwebtoken';

import * as auth from '../lib/auth.js';
import type { AuthUser, LoginResponse, RoleInfo } from '../types/index.js';
import { normalizeUserRoleString } from '@openpath/shared/roles';

export type { LoginResponse };

export type AuthServiceError =
  | { code: 'CONFLICT'; message: string }
  | { code: 'UNAUTHORIZED'; message: string }
  | { code: 'FORBIDDEN'; message: string }
  | { code: 'NOT_FOUND'; message: string }
  | { code: 'BAD_REQUEST'; message: string };

export type AuthResult<T> = { ok: true; data: T } | { ok: false; error: AuthServiceError };

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: string;
  tokenType: 'Bearer';
}

export interface RegisterResponse {
  user: AuthUser;
  verificationRequired: true;
  verificationToken: string;
  verificationExpiresAt: string;
}

export interface EmailVerificationTokenResponse {
  email: string;
  verificationRequired: true;
  verificationToken: string;
  verificationExpiresAt: string;
}

export const EMAIL_VERIFICATION_REQUIRED_MESSAGE = 'Email verification required before signing in';

function parseDurationToSeconds(value: string): number | null {
  const trimmed = value.trim();
  if (trimmed === '') {
    return null;
  }

  if (/^\d+(\.\d+)?$/.test(trimmed)) {
    const milliseconds = Number.parseFloat(trimmed);
    if (!Number.isFinite(milliseconds) || milliseconds < 0) {
      return null;
    }
    return Math.floor(milliseconds / 1000);
  }

  const match =
    /^(\d+(?:\.\d+)?)\s*(ms|msecs?|milliseconds?|s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?|w|weeks?|y|yrs?|years?)$/i.exec(
      trimmed
    );
  if (!match) {
    return null;
  }

  const [, amountText, unitText] = match;
  if (!amountText || !unitText) {
    return null;
  }

  const amount = Number.parseFloat(amountText);
  if (!Number.isFinite(amount) || amount < 0) {
    return null;
  }

  const unit = unitText.toLowerCase();
  const unitToSeconds: Record<string, number> = {
    ms: 1 / 1000,
    msec: 1 / 1000,
    msecs: 1 / 1000,
    millisecond: 1 / 1000,
    milliseconds: 1 / 1000,
    s: 1,
    sec: 1,
    secs: 1,
    second: 1,
    seconds: 1,
    m: 60,
    min: 60,
    mins: 60,
    minute: 60,
    minutes: 60,
    h: 60 * 60,
    hr: 60 * 60,
    hrs: 60 * 60,
    hour: 60 * 60,
    hours: 60 * 60,
    d: 24 * 60 * 60,
    day: 24 * 60 * 60,
    days: 24 * 60 * 60,
    w: 7 * 24 * 60 * 60,
    week: 7 * 24 * 60 * 60,
    weeks: 7 * 24 * 60 * 60,
    y: 365.25 * 24 * 60 * 60,
    yr: 365.25 * 24 * 60 * 60,
    yrs: 365.25 * 24 * 60 * 60,
    year: 365.25 * 24 * 60 * 60,
    years: 365.25 * 24 * 60 * 60,
  };
  const secondsPerUnit = unitToSeconds[unit];
  if (secondsPerUnit === undefined) {
    return null;
  }

  return Math.floor(amount * secondsPerUnit);
}

function getAccessTokenLifetimeSeconds(accessToken: string): number | null {
  const decoded = jwt.decode(accessToken);
  if (decoded === null || typeof decoded !== 'object') {
    return null;
  }

  const exp = 'exp' in decoded && typeof decoded.exp === 'number' ? decoded.exp : null;
  const iat = 'iat' in decoded && typeof decoded.iat === 'number' ? decoded.iat : null;
  if (exp === null || iat === null) {
    return null;
  }

  const lifetime = exp - iat;
  return Number.isFinite(lifetime) && lifetime >= 0 ? lifetime : null;
}

function currentSessionTransport(): LoginResponse['sessionTransport'] {
  return process.env.OPENPATH_ACCESS_TOKEN_COOKIE_NAME ? 'cookie' : 'token';
}

export function buildAuthUser(
  user: {
    id: string;
    email: string;
    name: string;
    emailVerified?: boolean | undefined;
  },
  roleInfo: RoleInfo[]
): AuthUser {
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    emailVerified: user.emailVerified ?? false,
    roles: roleInfo,
  };
}

export function buildLoginResponse(
  tokens: TokenPair,
  user: { id: string; email: string; name: string },
  roleInfo: RoleInfo[]
): LoginResponse {
  const expiresIn =
    getAccessTokenLifetimeSeconds(tokens.accessToken) ??
    parseDurationToSeconds(tokens.expiresIn) ??
    86400;

  return {
    ...tokens,
    expiresIn,
    sessionTransport: currentSessionTransport(),
    user: buildAuthUser(user, roleInfo),
  };
}

export function mapRoleInfo(
  roles: {
    groupIds: string[] | null;
    role: string;
  }[]
): RoleInfo[] {
  return roles
    .map((role) => {
      const normalizedRole = normalizeUserRoleString(role.role);
      if (!normalizedRole) return null;
      return { role: normalizedRole, groupIds: role.groupIds ?? [] };
    })
    .filter((role): role is RoleInfo => role !== null);
}

export function generateTokensForUser(
  user: Parameters<typeof auth.generateTokens>[0],
  roleInfo: RoleInfo[]
): TokenPair {
  return auth.generateTokens(user, roleInfo);
}
