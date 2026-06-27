// react-spa/src/hooks/__tests__/useRulesData.disabledList.test.tsx
import { renderHook, waitFor } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import { useRulesData } from '../useRulesData';

const paginated = vi.fn(async (_input: unknown) => ({ rules: [], total: 0, hasMore: false }));
vi.mock('../../lib/trpc', () => ({
  trpc: {
    groups: {
      listRules: { query: vi.fn(async () => []) },
      listRulesPaginated: { query: (input: unknown) => paginated(input) },
    },
  },
}));

describe('useRulesData disabled list', () => {
  it('passes enabled:false when filter=disabled', async () => {
    renderHook(() =>
      useRulesData({ groupId: 'g', filter: 'disabled', page: 1, search: '', pageSize: 50 })
    );
    await waitFor(() => expect(paginated).toHaveBeenCalled());
    expect(paginated).toHaveBeenCalledWith(expect.objectContaining({ enabled: false }));
  });
});
