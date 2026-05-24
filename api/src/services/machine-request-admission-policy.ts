import type { Rule } from '../lib/groups-storage.js';

function normalizeAdmissionDomainCandidate(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/^\.+|\.+$/g, '');
}

export function extractAdmissionHostname(value: string | undefined): string | null {
  const raw = value?.trim();
  if (!raw) {
    return null;
  }

  const extractHostLikeValue = (): string | null => {
    const withoutProtocol = raw.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
    const host = withoutProtocol.split(/[/?#]/, 1)[0]?.split(':', 1)[0] ?? '';
    const normalized = normalizeAdmissionDomainCandidate(host);
    return normalized.length > 0 && !/\s/.test(normalized) ? normalized : null;
  };

  try {
    const normalized = normalizeAdmissionDomainCandidate(new URL(raw).hostname);
    return normalized.length > 0 ? normalized : extractHostLikeValue();
  } catch {
    return extractHostLikeValue();
  }
}

export function admissionDomainMatchesRule(hostname: string, ruleValue: string): boolean {
  const normalizedHostname = normalizeAdmissionDomainCandidate(hostname);
  const normalizedRule = normalizeAdmissionDomainCandidate(ruleValue.replace(/^\*\./, ''));
  return normalizedHostname === normalizedRule || normalizedHostname.endsWith(`.${normalizedRule}`);
}

export function admissionOriginMatchesWhitelist(
  originPage: string | undefined,
  whitelistValues: readonly string[]
): boolean {
  const originHost = extractAdmissionHostname(originPage);
  if (!originHost) {
    return false;
  }

  return whitelistValues.some((value) => admissionDomainMatchesRule(originHost, value));
}

function wildcardToRegex(value: string): RegExp {
  const escaped = value.replace(/[\\^$+?.()|[\]{}]/g, '\\$&').replace(/\*/g, '.*');
  return new RegExp(`^${escaped}$`, 'i');
}

function blockedPathRuleMatchesUrl(ruleValue: string, targetUrl: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(targetUrl);
  } catch {
    return false;
  }

  const normalizedRule = ruleValue
    .trim()
    .toLowerCase()
    .replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
  const slashIndex = normalizedRule.indexOf('/');
  if (slashIndex < 0) {
    return false;
  }

  const ruleDomain = normalizedRule.slice(0, slashIndex);
  const rulePath = normalizedRule.slice(slashIndex);
  const targetHostname = normalizeAdmissionDomainCandidate(parsed.hostname);
  const domainMatches =
    ruleDomain === '*' ||
    (ruleDomain.startsWith('*.')
      ? admissionDomainMatchesRule(targetHostname, ruleDomain)
      : admissionDomainMatchesRule(targetHostname, ruleDomain));

  if (!domainMatches) {
    return false;
  }

  const pathPattern = rulePath.endsWith('*') ? rulePath : `${rulePath}*`;
  return wildcardToRegex(pathPattern).test(`${parsed.pathname}${parsed.search}`);
}

export function admissionTargetMatchesBlockedPath(
  targetUrl: string | undefined,
  blockedPathValues: readonly string[]
): boolean {
  if (!targetUrl) {
    return false;
  }

  return blockedPathValues.some((value) => blockedPathRuleMatchesUrl(value, targetUrl));
}

export function ruleValues(rules: readonly Rule[]): string[] {
  return rules.map((rule) => rule.value);
}
