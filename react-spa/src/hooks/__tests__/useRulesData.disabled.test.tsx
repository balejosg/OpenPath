// react-spa/src/hooks/__tests__/useRulesData.disabled.test.tsx
import { renderHook, waitFor } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { useRulesData } from '../useRulesData';

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
          query: vi.fn(({ type, enabled }: { type?: string; enabled?: boolean }) => {
            if (enabled === false) return Promise.resolve([rule('off', false)]);
            if (type === 'whitelist') return Promise.resolve([rule('on', true)]);
            return Promise.resolve([]);
          }),
        },
        listRulesPaginated: {
          query: vi.fn(() => Promise.resolve({ rules: [], total: 0, hasMore: false })),
        },
      },
    },
  };
});

describe('useRulesData disabled counts', () => {
  beforeEach(() => vi.clearAllMocks());
  it('counts disabled separately and includes it in all', async () => {
    const { result } = renderHook(() =>
      useRulesData({ groupId: 'g', filter: 'all', page: 1, search: '', pageSize: 50 })
    );
    await waitFor(() => expect(result.current.counts.disabled).toBe(1));
    expect(result.current.counts.allowed).toBe(1);
    expect(result.current.counts.all).toBe(
      result.current.counts.allowed + result.current.counts.blocked + result.current.counts.disabled
    );
  });
});
