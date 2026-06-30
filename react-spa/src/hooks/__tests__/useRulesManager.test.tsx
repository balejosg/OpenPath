import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';
import { useRulesManager } from '../useRulesManager';

// Mock trpc
vi.mock('../../lib/trpc', () => ({
  trpc: {
    groups: {
      listRulesPaginated: {
        query: vi.fn().mockResolvedValue({
          rules: [
            {
              id: '1',
              groupId: 'test-group',
              type: 'whitelist',
              source: 'manual',
              value: 'google.com',
              enabled: true,
              comment: null,
              createdAt: '2024-01-15T10:00:00Z',
            },
          ],
          total: 1,
          hasMore: false,
        }),
      },
      listRules: {
        query: vi.fn().mockResolvedValue([
          {
            id: '1',
            groupId: 'test-group',
            type: 'whitelist',
            source: 'manual',
            value: 'google.com',
            enabled: true,
            comment: null,
            createdAt: '2024-01-15T10:00:00Z',
          },
        ]),
      },
      createRule: {
        mutate: vi.fn().mockResolvedValue({ id: '2' }),
      },
      deleteRule: {
        mutate: vi.fn().mockResolvedValue({ deleted: true }),
      },
      updateRule: {
        mutate: vi.fn().mockResolvedValue({
          id: '1',
          groupId: 'test-group',
          type: 'whitelist',
          source: 'manual',
          value: 'updated.com',
          enabled: true,
          comment: null,
          createdAt: '2024-01-15T10:00:00Z',
        }),
      },
    },
  },
}));

// Import the mocked module
import { trpc } from '../../lib/trpc';

describe('useRulesManager Hook', () => {
  const mockOnToast = vi.fn();
  const defaultOptions = {
    groupId: 'test-group',
    onToast: mockOnToast,
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('initializes with loading state', async () => {
    const { result } = renderHook(() => useRulesManager(defaultOptions));

    expect(result.current.loading).toBe(true);

    // Allow async effects to settle to avoid act warnings.
    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });
  });

  it('fetches rules on mount', async () => {
    const { result } = renderHook(() => useRulesManager(defaultOptions));

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.rules).toHaveLength(1);
    expect(result.current.rules[0].value).toBe('google.com');
  });

  it('provides filter state and setter', async () => {
    const { result } = renderHook(() => useRulesManager(defaultOptions));

    const listRulesMock = vi.mocked(trpc.groups.listRules.query);

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.filter).toBe('all');

    act(() => {
      result.current.setFilter('allowed');
    });

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
      expect(result.current.filter).toBe('allowed');
    });

    // When filter is 'allowed', listRules is called with whitelist and allowed_path
    expect(listRulesMock).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'whitelist', enabled: true })
    );
    expect(listRulesMock).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'allowed_path', enabled: true })
    );
  });

  it('passes allowed filter type to the flat list using client-side merge', async () => {
    const { result } = renderHook(() => useRulesManager(defaultOptions));
    const listRulesMock = vi.mocked(trpc.groups.listRules.query);
    const paginatedMock = vi.mocked(trpc.groups.listRulesPaginated.query);

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    const paginatedCallsBefore = paginatedMock.mock.calls.length;

    act(() => {
      result.current.setFilter('allowed');
    });

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    // listRulesPaginated should not have been called again for the allowed filter
    expect(paginatedMock.mock.calls.length).toBe(paginatedCallsBefore);

    // listRules should have been called with whitelist and allowed_path
    expect(listRulesMock).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'whitelist', enabled: true })
    );
    expect(listRulesMock).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'allowed_path', enabled: true })
    );
  });

  it('builds blocked tab from subdomain and path rules with search and pagination', async () => {
    vi.mocked(trpc.groups.listRules.query).mockImplementation((input) => {
      if (input.type === 'blocked_subdomain') {
        return Promise.resolve([
          {
            id: 'blocked-2',
            groupId: 'test-group',
            type: 'blocked_subdomain',
            source: 'manual',
            value: 'z-search.example.com',
            enabled: true,
            comment: null,
            createdAt: '2024-01-01T00:00:00Z',
          },
          {
            id: 'blocked-1',
            groupId: 'test-group',
            type: 'blocked_subdomain',
            source: 'manual',
            value: 'a-search.example.com',
            enabled: true,
            comment: null,
            createdAt: '2024-01-01T00:00:00Z',
          },
        ]);
      }
      if (input.type === 'blocked_path') {
        return Promise.resolve([
          {
            id: 'path-1',
            groupId: 'test-group',
            type: 'blocked_path',
            source: 'manual',
            value: 'example.com/search-track',
            enabled: true,
            comment: null,
            createdAt: '2024-01-01T00:00:00Z',
          },
          {
            id: 'path-2',
            groupId: 'test-group',
            type: 'blocked_path',
            source: 'manual',
            value: 'example.com/other',
            enabled: true,
            comment: null,
            createdAt: '2024-01-01T00:00:00Z',
          },
        ]);
      }
      return Promise.resolve([]);
    });

    const { result } = renderHook(() => useRulesManager(defaultOptions));

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    act(() => {
      result.current.setSearch('search');
      result.current.setFilter('blocked');
    });

    await waitFor(() => {
      expect(result.current.rules.map((rule) => rule.value)).toEqual([
        'a-search.example.com',
        'example.com/search-track',
        'z-search.example.com',
      ]);
    });
    expect(result.current.total).toBe(3);
    expect(result.current.totalPages).toBe(1);
  });

  it('provides search state and setter', async () => {
    const { result } = renderHook(() => useRulesManager(defaultOptions));

    const queryMock = vi.mocked(trpc.groups.listRulesPaginated.query);

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.search).toBe('');

    act(() => {
      result.current.setSearch('google');
    });

    await waitFor(() => {
      expect(queryMock).toHaveBeenCalledTimes(2);
    });

    expect(queryMock).toHaveBeenLastCalledWith(
      expect.objectContaining({
        search: 'google',
      })
    );

    // Ensure the in-flight fetch resolves before the test ends (prevents act warnings).
    await (queryMock.mock.results[1]?.value ?? Promise.resolve());

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
      expect(result.current.search).toBe('google');
    });
  });

  it('provides pagination state', async () => {
    const { result } = renderHook(() => useRulesManager(defaultOptions));

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.page).toBe(1);
    expect(result.current.totalPages).toBeGreaterThanOrEqual(1);
  });

  it('provides counts for tabs', async () => {
    const { result } = renderHook(() => useRulesManager(defaultOptions));

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.counts).toHaveProperty('all');
    expect(result.current.counts).toHaveProperty('allowed');
    expect(result.current.counts).toHaveProperty('blocked');
  });

  it('provides CRUD operations', async () => {
    const { result } = renderHook(() => useRulesManager(defaultOptions));

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(typeof result.current.addRule).toBe('function');
    expect(typeof result.current.deleteRule).toBe('function');
    expect(typeof result.current.updateRule).toBe('function');
    expect(typeof result.current.refetch).toBe('function');
  });
});
