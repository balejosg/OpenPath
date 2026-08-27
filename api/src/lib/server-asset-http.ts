import { createHash } from 'node:crypto';

import type { Request } from 'express';

import { config } from '../config.js';

export function getPublicBaseUrl(req: Request): string {
  const configuredBaseUrl = config.publicUrl?.trim();
  if (configuredBaseUrl) {
    let parsed: URL;
    try {
      parsed = new URL(configuredBaseUrl);
    } catch {
      throw new Error('PUBLIC_URL must be a valid absolute URL');
    }
    if (!parsed.hostname || parsed.username || parsed.password) {
      throw new Error('PUBLIC_URL must contain a hostname and no URL credentials');
    }
    if (parsed.search || parsed.hash) {
      throw new Error('PUBLIC_URL must not contain a query string or fragment');
    }
    if (config.isProduction && parsed.protocol !== 'https:') {
      throw new Error('PUBLIC_URL must use HTTPS in production');
    }
    return `${parsed.origin}${parsed.pathname.replace(/\/+$/u, '')}`;
  }

  if (config.isProduction) {
    throw new Error('PUBLIC_URL must be configured for public URL generation in production');
  }

  return `${req.protocol}://${req.get('host') ?? `${config.host}:${String(config.port)}`}`.replace(
    /\/+$/,
    ''
  );
}

export function quotePowerShellSingle(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

export function buildWhitelistEtag(params: {
  groupId: string;
  updatedAt: Date;
  enabled: boolean;
  content?: string;
}): string {
  const version = [
    params.groupId,
    params.updatedAt.toISOString(),
    params.enabled ? '1' : '0',
    params.content ?? '',
  ].join(':');
  const hash = createHash('sha256').update(version).digest('base64url');
  return `"${hash}"`;
}

export function buildStaticEtag(key: string): string {
  const hash = createHash('sha256').update(key).digest('base64url');
  return `"${hash}"`;
}

export function matchesIfNoneMatch(req: Request, etag: string): boolean {
  const header = req.headers['if-none-match'];
  if (typeof header !== 'string') return false;
  const trimmed = header.trim();
  if (trimmed === '*') return true;

  const values = trimmed
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  for (const value of values) {
    if (value === etag) return true;
    if (value.startsWith('W/') && value.slice(2).trim() === etag) return true;
  }
  return false;
}
