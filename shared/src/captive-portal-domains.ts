const MAX_CAPTIVE_PORTAL_DOMAINS = 10;
const MAX_CAPTIVE_PORTAL_DOMAINS_TEXT = '10';
const DOMAIN_LABEL_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

function isExactHostname(value: string): boolean {
  if (value.length > 253 || value.includes('..')) {
    return false;
  }

  const labels = value.split('.');
  const tld = labels.at(-1);
  return (
    labels.length >= 2 &&
    tld !== undefined &&
    labels.every((label) => DOMAIN_LABEL_PATTERN.test(label)) &&
    tld.length >= 2
  );
}

/**
 * Validates and normalizes admin-entered captive portal domains.
 *
 * Input is required to be an exact hostname (no wildcards/URLs); admins enter a
 * base host such as `nce.wedu.comunidad.madrid`. Subdomain coverage is NOT part
 * of the stored value — it is applied at enforcement time. The Windows agent
 * forwards each configured domain AND all of its subdomains (Acrylic `FW >domain`
 * + `*.domain` affinity), so captive portal login/asset/redirect subdomains
 * resolve. Matching is therefore suffix-based even though the stored value is exact.
 */
export function normalizeCaptivePortalDomains(
  values: readonly string[] | null | undefined
): string[] {
  const normalized: string[] = [];
  const seen = new Set<string>();

  for (const value of values ?? []) {
    const domain = value.trim().toLowerCase().replace(/\.$/, '');
    if (!domain) {
      continue;
    }
    if (
      domain.includes('://') ||
      domain.includes('/') ||
      domain.includes('?') ||
      domain.includes('#')
    ) {
      throw new Error('Captive portal domains must be exact hostnames, not URLs');
    }
    if (domain.includes('*')) {
      throw new Error('Captive portal domains must not use wildcard domains');
    }
    if (!isExactHostname(domain)) {
      throw new Error('Captive portal domains must be valid domain hostnames');
    }
    if (!seen.has(domain)) {
      seen.add(domain);
      normalized.push(domain);
    }
  }

  if (normalized.length > MAX_CAPTIVE_PORTAL_DOMAINS) {
    throw new Error(
      `Captive portal domains can include at most ${MAX_CAPTIVE_PORTAL_DOMAINS_TEXT} entries`
    );
  }

  return normalized;
}
