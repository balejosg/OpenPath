import { describe, expect, it } from 'vitest';

import { toDomainGroups } from '../rule-groups';
import type { Rule } from '../rules';
import type { RuleType } from '@openpath/shared/rules-validation';

function rule(type: RuleType, value: string, id = value): Rule {
  return {
    id,
    groupId: 'group-1',
    type,
    value,
    comment: null,
    createdAt: '2024-01-15T10:00:00Z',
  };
}

describe('toDomainGroups status', () => {
  it("marks a group with only whitelist rules as 'allowed'", () => {
    const groups = toDomainGroups([
      rule('whitelist', 'example.com'),
      rule('whitelist', 'sub.example.com'),
    ]);

    expect(groups).toHaveLength(1);
    expect(groups[0].status).toBe('allowed');
  });

  it("marks a group with whitelist plus blocked carve-outs as 'mixed'", () => {
    const groups = toDomainGroups([
      rule('whitelist', 'example.com'),
      rule('blocked_path', 'example.com/ads'),
    ]);

    expect(groups).toHaveLength(1);
    expect(groups[0].status).toBe('mixed');
  });

  it("marks a group whose only rules are blocked carve-outs as 'mixed', not 'blocked'", () => {
    // blocked_subdomain / blocked_path are carve-out exceptions within a domain,
    // never a block of the whole root. The parent root row must not appear fully
    // 'blocked' just because a child subdomain/path is blocked.
    const groups = toDomainGroups([
      rule('blocked_subdomain', 'ads.example.com'),
      rule('blocked_path', 'example.com/tracking'),
    ]);

    expect(groups).toHaveLength(1);
    expect(groups[0].status).toBe('mixed');
  });
});
