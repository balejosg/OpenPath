import {
  buildBlockedScreenRedirectUrl,
  buildPathRulePatterns,
  extractHostname,
  globPatternToRegex,
  isExtensionUrl,
} from './path-blocking.js';

export interface NativeAllowedPathsResponse {
  success: boolean;
  paths?: string[];
  hash?: string;
  mtime?: number;
  source?: string;
  error?: string;
}

export interface CompiledAllowedPathRule {
  rawRule: string;
  host: string;
  compiledPatterns: string[];
  regexes: RegExp[];
}

export interface AllowedPathRulesState {
  version: string;
  rules: CompiledAllowedPathRule[];
  managedHosts: Set<string>;
}

export interface AllowedPathEvaluationDetails {
  type?: string;
  url: string;
  originUrl?: string;
  documentUrl?: string;
}

export interface AllowedPathEvaluationResult {
  cancel?: boolean;
  redirectUrl?: string;
  reason?: string;
}

export const ALLOWED_PATH_BLOCK_REASON = 'ALLOWED_PATH_POLICY';
export const MAX_ALLOWED_PATH_RULES = 500;

// Only top-level navigations are gated. Sub-resources (scripts, media, xhr, sub_frame) must load
// freely so the allowed page itself works.
export function shouldEnforceAllowedPath(type?: string): boolean {
  return type === 'main_frame';
}

/**
 * Extract the concrete host an allowed-path rule governs (e.g. 'youtube.com' from
 * 'youtube.com/watch?v=abc'). Returns null for a global wildcard or a host without a dot.
 */
export function extractAllowedRuleHost(rawRule: string): string | null {
  let clean = rawRule.trim().toLowerCase();
  if (clean.length === 0) {
    return null;
  }
  for (const prefix of ['http://', 'https://', '*://']) {
    if (clean.startsWith(prefix)) {
      clean = clean.slice(prefix.length);
      break;
    }
  }
  const slashIndex = clean.indexOf('/');
  if (slashIndex <= 0) {
    return null;
  }
  let host = clean.slice(0, slashIndex);
  if (host.startsWith('*.')) {
    host = host.slice(2);
  }
  if (host.length === 0 || host === '*' || !host.includes('.')) {
    return null;
  }
  return host;
}

export function compileAllowedPathRules(
  paths: string[],
  options: {
    maxRules?: number;
    onTruncated?: (details: { provided: number; capped: number }) => void;
  } = {}
): { rules: CompiledAllowedPathRule[]; managedHosts: Set<string> } {
  const rules: CompiledAllowedPathRule[] = [];
  const managedHosts = new Set<string>();
  const seenPatterns = new Set<string>();
  const maxRules = options.maxRules ?? MAX_ALLOWED_PATH_RULES;
  const capped = paths.slice(0, maxRules);

  for (const rawPath of capped) {
    const host = extractAllowedRuleHost(rawPath);
    if (!host) {
      continue;
    }
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
    rules.push({
      rawRule: rawPath,
      host,
      compiledPatterns: patterns,
      regexes: patterns.map((pattern) => globPatternToRegex(pattern)),
    });
    managedHosts.add(host);
  }

  if (paths.length > maxRules) {
    options.onTruncated?.({ provided: paths.length, capped: maxRules });
  }

  return { rules, managedHosts };
}

export function getAllowedPathRulesVersion(payload: NativeAllowedPathsResponse): string {
  if (typeof payload.hash === 'string' && payload.hash.length > 0) {
    return payload.hash;
  }
  if (typeof payload.mtime === 'number') {
    return payload.mtime.toString();
  }
  return Array.isArray(payload.paths) ? payload.paths.join('\n') : '';
}

export function isHostManaged(hostname: string, managedHosts: Set<string>): boolean {
  const host = hostname.toLowerCase();
  for (const managed of managedHosts) {
    if (host === managed || host.endsWith(`.${managed}`)) {
      return true;
    }
  }
  return false;
}

export function urlMatchesAllowedRule(
  requestUrl: string,
  rules: CompiledAllowedPathRule[]
): boolean {
  const candidates = [requestUrl];
  try {
    const parsed = new URL(requestUrl);
    if (parsed.port) {
      parsed.port = '';
      candidates.push(parsed.toString());
    }
  } catch {
    // Ignore malformed URLs; the original request URL is still evaluated.
  }
  return rules.some((rule) =>
    rule.regexes.some((regex) => candidates.some((candidate) => regex.test(candidate)))
  );
}

export function evaluateAllowedPath(
  details: AllowedPathEvaluationDetails,
  state: AllowedPathRulesState,
  options: { extensionOrigin?: string } = {}
): AllowedPathEvaluationResult | null {
  if (!shouldEnforceAllowedPath(details.type)) {
    return null;
  }
  if (isExtensionUrl(details.url)) {
    return null;
  }
  if (state.managedHosts.size === 0) {
    return null;
  }

  const hostname = extractHostname(details.url);
  if (!hostname) {
    return null;
  }
  if (!isHostManaged(hostname, state.managedHosts)) {
    return null;
  }
  if (urlMatchesAllowedRule(details.url, state.rules)) {
    return null;
  }

  const origin = extractHostname(details.originUrl ?? details.documentUrl ?? '');
  const reason = `${ALLOWED_PATH_BLOCK_REASON}:${hostname}`;
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
