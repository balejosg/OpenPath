import { JWT_SECRET } from './auth.js';
import { config } from '../config.js';

import jwt, { type SignOptions } from 'jsonwebtoken';

const ENROLLMENT_TOKEN_ISSUER = 'openpath-api';
const ENROLLMENT_TOKEN_AUDIENCE = 'openpath-enroll';
const DEFAULT_EXPIRES_IN = '2h';

const TTL_UNIT_SECONDS: Record<string, number> = {
  s: 1,
  m: 60,
  h: 60 * 60,
  d: 24 * 60 * 60,
};

export class EnrollmentTokenTtlError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'EnrollmentTokenTtlError';
  }
}

export interface EnrollmentTokenPayload {
  typ: 'enroll';
  classroomId: string;
}

export interface EnrollmentTokenWithExpiry {
  enrollmentToken: string;
  expiresAt: string;
}

function parseExpiresInSeconds(expiresIn: string): number | null {
  if (/^\d+$/.test(expiresIn)) {
    return Number.parseInt(expiresIn, 10);
  }

  const match = /^(\d+)([smhd])$/.exec(expiresIn);
  if (!match) return null;

  const unit = match[2];
  const unitSeconds = unit !== undefined ? TTL_UNIT_SECONDS[unit] : undefined;
  if (unitSeconds === undefined) return null;

  return Number.parseInt(match[1] ?? '', 10) * unitSeconds;
}

export function assertWithinEnrollmentTtlCeiling(expiresIn: string | number): void {
  const seconds = typeof expiresIn === 'number' ? expiresIn : parseExpiresInSeconds(expiresIn);

  if (seconds === null || !Number.isFinite(seconds) || seconds <= 0) {
    throw new EnrollmentTokenTtlError(
      `Unsupported enrollment token expiresIn format: ${String(expiresIn)}. ` +
        'Use seconds or a value like "45m", "12h", or "7d".'
    );
  }

  const maxSeconds = config.enrollmentTokenMaxTtlHours * 60 * 60;
  if (seconds > maxSeconds) {
    const maxHours = String(config.enrollmentTokenMaxTtlHours);
    throw new EnrollmentTokenTtlError(
      `Requested enrollment token lifetime exceeds the configured maximum of ${maxHours} hours.`
    );
  }
}

export function generateEnrollmentTokenWithExpiry(
  classroomId: string,
  expiresIn = DEFAULT_EXPIRES_IN
): EnrollmentTokenWithExpiry {
  const enrollmentToken = generateEnrollmentToken(classroomId, expiresIn);
  return { enrollmentToken, expiresAt: getEnrollmentTokenExpiresAt(enrollmentToken) };
}

export function getEnrollmentTokenExpiresAt(token: string): string {
  const decoded = jwt.decode(token);
  const exp =
    decoded !== null &&
    typeof decoded === 'object' &&
    typeof (decoded as { exp?: unknown }).exp === 'number'
      ? (decoded as { exp: number }).exp
      : null;

  if (exp === null || !Number.isFinite(exp)) {
    throw new EnrollmentTokenTtlError('Issued enrollment token has no usable exp claim');
  }

  return new Date(exp * 1000).toISOString();
}

export function generateEnrollmentToken(
  classroomId: string,
  expiresIn = DEFAULT_EXPIRES_IN
): string {
  assertWithinEnrollmentTtlCeiling(expiresIn);
  const payload: EnrollmentTokenPayload = {
    typ: 'enroll',
    classroomId,
  };

  return jwt.sign(payload, JWT_SECRET, {
    expiresIn,
    issuer: ENROLLMENT_TOKEN_ISSUER,
    audience: ENROLLMENT_TOKEN_AUDIENCE,
  } as SignOptions);
}

export function verifyEnrollmentToken(token: string): EnrollmentTokenPayload | null {
  try {
    const decoded = jwt.verify(token, JWT_SECRET, {
      issuer: ENROLLMENT_TOKEN_ISSUER,
      audience: ENROLLMENT_TOKEN_AUDIENCE,
    }) as unknown;

    if (decoded === null || decoded === undefined || typeof decoded !== 'object') return null;
    const rec = decoded as Record<string, unknown>;

    if (rec.typ !== 'enroll') return null;
    if (typeof rec.classroomId !== 'string' || rec.classroomId.length === 0) return null;

    return { typ: 'enroll', classroomId: rec.classroomId };
  } catch {
    return null;
  }
}
