// react-spa/src/hooks/__tests__/useGroupedRulesData.disabled.test.tsx
import { renderHook, waitFor } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { useGroupedRulesData } from '../useGroupedRulesData';

vi.mock('../../lib/trpc', () => {
  const rule = (id: string, enabled: boolean, type = 'whitelist') => ({
    id,
    groupId: 'g',
    type,
    value: `${id}.example.com`,
    source: 'manual',
    enabled,
    comment: null,
    createdAt: '2026-01-01T00:00:00Z',
  });
  return {
    trpc: {
      groups: {
        listRules: {
          query: vi.fn(async ({ type, enabled }: { type?: string; enabled?: boolean }) => {
            if (enabled === false) return [rule('off', false)];
            if (type === 'whitelist') return [rule('on', true)];
            return [];
          }),
        },
        listRulesGrouped: {
          query: vi.fn(async () => ({ groups: [], totalGroups: 0, totalRules: 0, hasMore: false })),
        },
      },
    },
  };
});

vi.mock('@openpath/shared/domain', () => ({
  getRootDomain: (value: string) => value.split('.').slice(-2).join('.'),
}));

describe('useGroupedRulesData disabled counts', () => {
  beforeEach(() => vi.clearAllMocks());
  it('counts disabled separately and includes it in all', async () => {
    const { result } = renderHook(() =>
      useGroupedRulesData({ filter: 'all', groupId: 'g', page: 1, search: '' })
    );
    await waitFor(() => expect(result.current.counts.disabled).toBe(1));
    expect(result.current.counts.allowed).toBe(1);
    expect(result.current.counts.all).toBe(
      result.current.counts.allowed + result.current.counts.blocked + result.current.counts.disabled
    );
  });
});
