/**
 * Domain utilities for root domain extraction with ccTLD support.
 * Used by both frontend (hierarchical view) and backend (grouped pagination).
 */

/**
 * Common country-code second-level domains (ccSLDs)
 * These require 3 parts to identify the root domain (e.g., example.co.uk)
 */
export const CC_SLDS = new Set([
  // UK
  'co.uk',
  'org.uk',
  'me.uk',
  'ac.uk',
  'gov.uk',
  'ltd.uk',
  'plc.uk',
  'net.uk',
  'sch.uk',
  // Australia
  'com.au',
  'net.au',
  'org.au',
  'edu.au',
  'gov.au',
  'asn.au',
  'id.au',
  // Brazil
  'com.br',
  'net.br',
  'org.br',
  'gov.br',
  'edu.br',
  // Argentina
  'com.ar',
  'net.ar',
  'org.ar',
  'gov.ar',
  'edu.ar',
  'gob.ar',
  // Mexico
  'com.mx',
  'net.mx',
  'org.mx',
  'gob.mx',
  'edu.mx',
  // Spain
  'com.es',
  'org.es',
  'gob.es',
  'edu.es',
  // Japan
  'co.jp',
  'or.jp',
  'ne.jp',
  'ac.jp',
  'go.jp',
  'gr.jp',
  // New Zealand
  'co.nz',
  'net.nz',
  'org.nz',
  'govt.nz',
  'ac.nz',
  'school.nz',
  // South Africa
  'co.za',
  'org.za',
  'gov.za',
  'net.za',
  'edu.za',
  // India
  'co.in',
  'net.in',
  'org.in',
  'gov.in',
  'ac.in',
  'edu.in',
  // China
  'com.cn',
  'net.cn',
  'org.cn',
  'gov.cn',
  'edu.cn',
  // Korea
  'co.kr',
  'or.kr',
  'ne.kr',
  'go.kr',
  'ac.kr',
  // Others
  'com.sg',
  'org.sg',
  'edu.sg',
  'gov.sg',
  'com.hk',
  'org.hk',
  'edu.hk',
  'gov.hk',
  'com.tw',
  'org.tw',
  'edu.tw',
  'gov.tw',
  'com.my',
  'org.my',
  'edu.my',
  'gov.my',
  'com.ph',
  'org.ph',
  'edu.ph',
  'gov.ph',
  'com.vn',
  'org.vn',
  'edu.vn',
  'gov.vn',
  'com.tr',
  'org.tr',
  'edu.tr',
  'gov.tr',
  'com.ua',
  'org.ua',
  'edu.ua',
  'gov.ua',
  'com.ru',
  'org.ru',
  'edu.ru',
  'gov.ru',
  'com.pl',
  'org.pl',
  'edu.pl',
  'gov.pl',
]);

/**
 * Extract the root domain from a URL or domain string.
 * Handles ccTLDs like .co.uk, .com.ar correctly.
 *
 * @example
 * getRootDomain('mail.google.com') // 'google.com'
 * getRootDomain('www.bbc.co.uk') // 'bbc.co.uk'
 * getRootDomain('facebook.com/gaming') // 'facebook.com'
 */
export const getRootDomain = (value: string): string => {
  try {
    // Remove protocol and www prefix
    let domain = value.replace(/^(https?:\/\/)?(www\.)?/, '');

    // Remove path and query string
    const pathParts = domain.split('/');
    domain = pathParts[0] ?? domain;
    const queryParts = domain.split('?');
    domain = queryParts[0] ?? domain;
    const hashParts = domain.split('#');
    domain = hashParts[0] ?? domain;

    // Remove port
    const portParts = domain.split(':');
    domain = portParts[0] ?? domain;

    // Handle wildcards
    domain = domain.replace(/^\*\.?/, '');

    const parts = domain.split('.');

    if (parts.length < 2) {
      return domain;
    }

    // Check for ccSLD (e.g., co.uk, com.ar)
    if (parts.length >= 3) {
      const possibleCcSld = parts.slice(-2).join('.');
      if (CC_SLDS.has(possibleCcSld)) {
        // Return last 3 parts (e.g., example.co.uk)
        return parts.slice(-3).join('.');
      }
    }

    // Standard TLD - return last 2 parts
    return parts.slice(-2).join('.');
  } catch {
    return value;
  }
};

/**
 * Normalize manually submitted request domains to the root domain.
 * Manual approvals intentionally whitelist the domain family, while automatic
 * machine requests keep exact-host behavior at the caller.
 */
export const normalizeManualRequestDomain = (value: string): string => getRootDomain(value);

/**
 * Group rules by their root domain.
 * Returns a Map where keys are root domains and values are arrays of rules.
 */
export const groupByRootDomain = <T extends { value: string }>(rules: T[]): Map<string, T[]> => {
  const groups = new Map<string, T[]>();

  for (const rule of rules) {
    const root = getRootDomain(rule.value);
    const existing = groups.get(root) ?? [];
    existing.push(rule);
    groups.set(root, existing);
  }

  return groups;
};
