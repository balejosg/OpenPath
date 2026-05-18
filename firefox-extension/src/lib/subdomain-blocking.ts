import {
  buildBlockedScreenRedirectUrl,
  extractHostname,
  isExtensionUrl,
  type PathBlockingEvaluationDetails,
  type PathBlockingEvaluationResult,
} from './path-blocking.js';
import { t } from './i18n.js';

export interface NativeBlockedSubdomainsResponse {
  success: boolean;
  subdomains?: string[];
  hash?: string;
  mtime?: number;
  source?: string;
  error?: string;
}

export interface CompiledBlockedSubdomainRule {
  rawRule: string;
  normalizedRule: string;
}

export interface BlockedSubdomainRulesState {
  version: string;
  rules: CompiledBlockedSubdomainRule[];
}

export const BLOCKED_SUBDOMAIN_REASON = 'BLOCKED_SUBDOMAIN_POLICY';
export const MAX_BLOCKED_SUBDOMAIN_RULES = 1000;

export function compileBlockedSubdomainRules(
  rules: string[],
  options: {
    maxRules?: number;
    onTruncated?: (details: { provided: number; capped: number }) => void;
  } = {}
): CompiledBlockedSubdomainRule[] {
  const maxRules = options.maxRules ?? MAX_BLOCKED_SUBDOMAIN_RULES;
  const capped = rules.slice(0, maxRules);
  const seen = new Set<string>();
  const compiled: CompiledBlockedSubdomainRule[] = [];

  for (const rawRule of capped) {
    const normalizedRule = rawRule.trim().toLowerCase().replace(/^\*\./, '');
    if (!normalizedRule || seen.has(normalizedRule)) {
      continue;
    }
    seen.add(normalizedRule);
    compiled.push({ rawRule: rawRule.trim().toLowerCase(), normalizedRule });
  }

  if (rules.length > maxRules) {
    options.onTruncated?.({ provided: rules.length, capped: maxRules });
  }

  return compiled;
}

export function getBlockedSubdomainRulesVersion(payload: NativeBlockedSubdomainsResponse): string {
  if (typeof payload.hash === 'string' && payload.hash.length > 0) {
    return payload.hash;
  }
  if (typeof payload.mtime === 'number') {
    return payload.mtime.toString();
  }
  return Array.isArray(payload.subdomains) ? payload.subdomains.join('\n') : '';
}

export function findMatchingBlockedSubdomainRule(
  requestUrl: string,
  rules: CompiledBlockedSubdomainRule[]
): CompiledBlockedSubdomainRule | null {
  const hostname = extractHostname(requestUrl)?.toLowerCase();
  if (!hostname) {
    return null;
  }

  return (
    rules.find(
      (rule) => hostname === rule.normalizedRule || hostname.endsWith(`.${rule.normalizedRule}`)
    ) ?? null
  );
}

export function evaluateSubdomainBlocking(
  details: PathBlockingEvaluationDetails,
  rules: CompiledBlockedSubdomainRule[],
  options: { extensionOrigin?: string } = {}
): PathBlockingEvaluationResult | null {
  if (isExtensionUrl(details.url)) {
    return null;
  }

  const matchedRule = findMatchingBlockedSubdomainRule(details.url, rules);
  if (!matchedRule) {
    return null;
  }

  const hostname = extractHostname(details.url) ?? t('blockedUnknownDomain');
  const origin = extractHostname(details.originUrl ?? details.documentUrl ?? '');
  const reason = `${BLOCKED_SUBDOMAIN_REASON}:${matchedRule.rawRule}`;

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
