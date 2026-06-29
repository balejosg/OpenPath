import { getRootDomain } from '@openpath/shared/domain';

import type { Rule } from './rules';

export interface DomainGroup {
  root: string;
  rules: Rule[];
  status: 'allowed' | 'blocked' | 'mixed';
}

export function toDomainGroups(rules: Rule[]): DomainGroup[] {
  if (rules.length === 0) {
    return [];
  }

  const grouped = new Map<string, DomainGroup>();

  for (const rule of rules) {
    const root = getRootDomain(rule.value);
    const existing = grouped.get(root);
    if (existing) {
      existing.rules.push(rule);
      continue;
    }

    grouped.set(root, { root, rules: [rule], status: 'mixed' });
  }

  for (const group of grouped.values()) {
    // blocked_subdomain / blocked_path are carve-out exceptions within a domain,
    // never a block of the whole root domain. A group is therefore 'allowed' when
    // every rule is a whitelist entry, and 'mixed' as soon as it contains any blocked
    // carve-out (with or without a whitelist). The parent root row must not appear
    // fully 'blocked' just because a child subdomain/path is blocked.
    const hasBlockedCarveOut = group.rules.some((rule) => rule.type !== 'whitelist');
    group.status = hasBlockedCarveOut ? 'mixed' : 'allowed';
  }

  return Array.from(grouped.values()).sort((left, right) => left.root.localeCompare(right.root));
}
