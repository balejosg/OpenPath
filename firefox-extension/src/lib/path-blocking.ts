import { t } from './i18n.js';

export interface NativeBlockedPathsResponse {
  success: boolean;
  paths?: string[];
  hash?: string;
  mtime?: number;
  source?: string;
  error?: string;
}

export interface CompiledBlockedPathRule {
  rawRule: string;
  compiledPatterns: string[];
  regexes: RegExp[];
}

export interface BlockedPathRulesState {
  version: string;
  rules: CompiledBlockedPathRule[];
}

export interface PathBlockingEvaluationDetails {
  type?: string;
  url: string;
  originUrl?: string;
  documentUrl?: string;
}

export interface PathBlockingEvaluationResult {
  cancel?: boolean;
  redirectUrl?: string;
  reason?: string;
}

export const BLOCKED_SCREEN_PATH = 'blocked/blocked.html';
export const ROUTE_BLOCK_REASON = 'BLOCKED_PATH_POLICY';
export const PATH_BLOCKING_FILTER_TYPES = [
  'main_frame',
  'sub_frame',
  'xmlhttprequest',
  'fetch',
] as const;
export const MAX_BLOCKED_PATH_RULES = 500;

const PATH_BLOCKING_REQUEST_TYPES = new Set<string>(PATH_BLOCKING_FILTER_TYPES);

export function isExtensionUrl(url: string): boolean {
  return url.startsWith('moz-extension://') || url.startsWith('chrome-extension://');
}

export function buildBlockedScreenRedirectUrl(payload: {
  extensionOrigin: string;
  hostname: string;
  error: string;
  origin: string | null;
}): string {
  const redirectUrl = new URL(BLOCKED_SCREEN_PATH, payload.extensionOrigin);
  redirectUrl.searchParams.set('domain', payload.hostname);
  redirectUrl.searchParams.set('error', payload.error);
  if (payload.origin) {
    redirectUrl.searchParams.set('origin', payload.origin);
  }
  return redirectUrl.toString();
}

export function extractHostname(url: string): string | null {
  try {
    const urlObj = new URL(url);
    return urlObj.hostname;
  } catch {
    return null;
  }
}

export function buildPathRulePatterns(rawRule: string): string[] {
  const raw = rawRule.trim().toLowerCase();
  if (raw.length === 0) {
    return [];
  }

  let clean = raw;
  for (const prefix of ['http://', 'https://', '*://']) {
    if (clean.startsWith(prefix)) {
      clean = clean.slice(prefix.length);
      break;
    }
  }

  if (!clean.includes('/') && !clean.includes('.') && !clean.includes('*')) {
    clean = `*${clean}*`;
  } else if (!clean.endsWith('*')) {
    clean = `${clean}*`;
  }

  if (clean.startsWith('*.')) {
    const base = clean.slice(2);
    return [`*://${clean}`, `*://${base}`];
  }

  if (clean.startsWith('*/')) {
    return [`*://*${clean.slice(1)}`];
  }

  if (clean.includes('.') && clean.includes('/')) {
    return [`*://*.${clean}`, `*://${clean}`];
  }

  return [`*://${clean}`];
}

function escapeRegexChar(value: string): string {
  return value.replace(/[\\^$+?.()|[\]{}]/g, '\\$&');
}

export function globPatternToRegex(globPattern: string): RegExp {
  let regexSource = '^';
  const lastIndex = globPattern.length - 1;

  for (let i = 0; i < globPattern.length; i += 1) {
    if (globPattern.slice(i, i + 4) === '*://') {
      regexSource += '[a-z][a-z0-9+.-]*://';
      i += 3;
      continue;
    }

    const char = globPattern[i] ?? '';
    if (char === '*') {
      regexSource += i === lastIndex ? '.*?' : '[^?#]*';
    } else {
      regexSource += escapeRegexChar(char);
    }
  }

  regexSource += '$';
  return new RegExp(regexSource, 'i');
}

export function compileBlockedPathRules(
  paths: string[],
  options: {
    maxRules?: number;
    onTruncated?: (details: { provided: number; capped: number }) => void;
  } = {}
): CompiledBlockedPathRule[] {
  const compiled: CompiledBlockedPathRule[] = [];
  const seenPatterns = new Set<string>();
  const maxRules = options.maxRules ?? MAX_BLOCKED_PATH_RULES;
  const capped = paths.slice(0, maxRules);

  for (const rawPath of capped) {
    const patterns = buildPathRulePatterns(rawPath).filter((pattern) => {
      if (seenPatterns.has(pattern)) {
        return false;
      }
      seenPatterns.add(pattern);
      return true;
    });

    if (patterns.length === 0) {
      continue;
    }

    compiled.push({
      rawRule: rawPath,
      compiledPatterns: patterns,
      regexes: patterns.map((pattern) => globPatternToRegex(pattern)),
    });
  }

  if (paths.length > maxRules) {
    options.onTruncated?.({
      provided: paths.length,
      capped: maxRules,
    });
  }

  return compiled;
}

export function getBlockedPathRulesVersion(payload: NativeBlockedPathsResponse): string {
  if (typeof payload.hash === 'string' && payload.hash.length > 0) {
    return payload.hash;
  }
  if (typeof payload.mtime === 'number') {
    return payload.mtime.toString();
  }

  return Array.isArray(payload.paths) ? payload.paths.join('\n') : '';
}

export function shouldEnforcePathBlocking(type?: string): boolean {
  if (!type) {
    return false;
  }
  return PATH_BLOCKING_REQUEST_TYPES.has(type);
}

export function findMatchingBlockedPathRule(
  requestUrl: string,
  rules: CompiledBlockedPathRule[]
): CompiledBlockedPathRule | null {
  const alternateUrls = [requestUrl];
  try {
    const parsed = new URL(requestUrl);
    if (parsed.port) {
      parsed.port = '';
      alternateUrls.push(parsed.toString());
    }
  } catch {
    // Ignore malformed URLs; the original request URL is still evaluated.
  }

  for (const rule of rules) {
    if (
      rule.regexes.some((regex) => alternateUrls.some((candidateUrl) => regex.test(candidateUrl)))
    ) {
      return rule;
    }
  }

  return null;
}

export function evaluatePathBlocking(
  details: PathBlockingEvaluationDetails,
  rules: CompiledBlockedPathRule[],
  options: { extensionOrigin?: string } = {}
): PathBlockingEvaluationResult | null {
  if (!shouldEnforcePathBlocking(details.type)) {
    return null;
  }

  if (isExtensionUrl(details.url)) {
    return null;
  }

  const matchedRule = findMatchingBlockedPathRule(details.url, rules);
  if (!matchedRule) {
    return null;
  }

  const hostname = extractHostname(details.url) ?? t('blockedUnknownDomain');
  const origin = extractHostname(details.originUrl ?? details.documentUrl ?? '');
  const reason = `${ROUTE_BLOCK_REASON}:${matchedRule.rawRule}`;

  if (details.type === 'main_frame') {
    if (!options.extensionOrigin) {
      return { cancel: true, reason };
    }

    return {
      redirectUrl: buildBlockedScreenRedirectUrl({
        extensionOrigin: options.extensionOrigin,
        hostname,
        error: reason,
        origin,
      }),
      reason,
    };
  }

  return { cancel: true, reason };
}
