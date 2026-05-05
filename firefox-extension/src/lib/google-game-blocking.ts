import type { WebRequest } from 'webextension-polyfill';
import { buildBlockedScreenRedirectUrl } from './path-blocking.js';

export const GOOGLE_GAME_POLICY_REASON = 'GOOGLE_GAME_POLICY';

export interface GoogleGameMatch {
  kind: 'doodles' | 'logo-game' | 'snake';
}

export interface GoogleGameBlockingOptions {
  extensionOrigin?: string;
}

export interface GoogleGameBlockingOutcome {
  cancel?: boolean;
  redirectUrl?: string;
  reason: string;
}

interface RequestLike {
  type?: string;
  url?: string;
}

const GOOGLE_GAME_LOGO_PATTERN =
  /(?:snake|pac[\s._-]?man|solitaire|tic[\s._-]?tac[\s._-]?toe|minesweeper|memory|arcade|game)/i;

function isGoogleHost(hostname: string): boolean {
  return /^(.+\.)?google\.[a-z.]+$/i.test(hostname);
}

function isDoodlesHost(hostname: string): boolean {
  return hostname === 'doodles.google' || hostname.endsWith('.doodles.google');
}

function buildReason(kind: GoogleGameMatch['kind']): string {
  return `${GOOGLE_GAME_POLICY_REASON}:${kind}`;
}

export function isGoogleGameUrl(url: string): GoogleGameMatch | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }

  const hostname = parsed.hostname.toLowerCase();
  if (isDoodlesHost(hostname)) {
    return { kind: 'doodles' };
  }

  if (!isGoogleHost(hostname)) {
    return null;
  }

  if (
    parsed.pathname === '/fbx' &&
    (parsed.searchParams.get('fbx') ?? '').toLowerCase() === 'snake_arcade'
  ) {
    return { kind: 'snake' };
  }

  if (parsed.pathname.startsWith('/logos/') && GOOGLE_GAME_LOGO_PATTERN.test(parsed.pathname)) {
    return { kind: 'logo-game' };
  }

  return null;
}

export function evaluateGoogleGameBlocking(
  request: RequestLike,
  options: GoogleGameBlockingOptions = {}
): GoogleGameBlockingOutcome | null {
  const url = request.url ?? '';
  const match = isGoogleGameUrl(url);
  if (!match) {
    return null;
  }

  const reason = buildReason(match.kind);
  if (request.type === 'main_frame' && options.extensionOrigin !== undefined) {
    return {
      redirectUrl: buildBlockedScreenRedirectUrl({
        extensionOrigin: options.extensionOrigin,
        hostname: new URL(url).hostname,
        error: reason,
        origin: url,
      }),
      reason,
    };
  }

  return { cancel: true, reason };
}

export function isGoogleGamePolicyOutcome(
  outcome: { reason?: string } | null | undefined
): outcome is { cancel?: boolean; redirectUrl?: string; reason: string } {
  return (
    typeof outcome?.reason === 'string' &&
    outcome.reason.startsWith(`${GOOGLE_GAME_POLICY_REASON}:`)
  );
}

export function toGoogleGameGuardEvent(details: WebRequest.OnBeforeRequestDetailsType): {
  blockedAt: number;
  pageHost: string;
  pagePath: string;
  reason: string;
  signals: string[];
} | null {
  const match = isGoogleGameUrl(details.url);
  if (!match) {
    return null;
  }

  const parsed = new URL(details.url);
  return {
    blockedAt: Date.now(),
    pageHost: parsed.hostname.toLowerCase(),
    pagePath: parsed.pathname,
    reason: buildReason(match.kind),
    signals: ['runtime-policy', match.kind],
  };
}
