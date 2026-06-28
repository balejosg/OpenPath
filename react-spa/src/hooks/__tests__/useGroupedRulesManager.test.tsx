import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';
import { useGroupedRulesManager } from '../useGroupedRulesManager';

// Mock trpc
vi.mock('../../lib/trpc', () => ({
  trpc: {
    groups: {
      listRulesGrouped: {
        query: vi.fn(),
      },
      listRules: {
        query: vi.fn(),
      },
      createRule: {
        mutate: vi.fn(),
      },
      deleteRule: {
        mutate: vi.fn(),
      },
      updateRule: {
        mutate: vi.fn(),
      },
      bulkDeleteRules: {
        mutate: vi.fn(),
      },
      bulkCreateRules: {
        mutate: vi.fn(),
      },
    },
  },
}));

// Import the mocked module
import { trpc } from '../../lib/trpc';

const mockToast = vi.fn();

const mockGroupedResult = {
  groups: [
    {
      root: 'google.com',
      rules: [
        {
          id: '1',
          groupId: 'g1',
          type: 'whitelist' as const,
          source: 'manual' as const,
          value: 'mail.google.com',
          enabled: true,
          comment: null,
          createdAt: '2024-01-01',
        },
        {
          id: '2',
          groupId: 'g1',
          type: 'whitelist' as const,
          source: 'manual' as const,
          value: 'drive.google.com',
          enabled: true,
          comment: null,
          createdAt: '2024-01-01',
        },
      ],
      status: 'allowed' as const,
    },
    {
      root: 'facebook.com',
      rules: [
        {
          id: '3',
          groupId: 'g1',
          type: 'blocked_subdomain' as const,
          source: 'manual' as const,
          value: 'facebook.com',
          enabled: true,
          comment: null,
          createdAt: '2024-01-01',
        },
      ],
      status: 'blocked' as const,
    },
  ],
  totalGroups: 2,
  totalRules: 3,
  hasMore: false,
};

describe('useGroupedRulesManager', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(trpc.groups.listRulesGrouped.query).mockResolvedValue(mockGroupedResult);
    vi.mocked(trpc.groups.listRules.query).mockResolvedValue([]);
  });

  describe('initialization', () => {
    it('should fetch grouped rules on mount', async () => {
      renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(trpc.groups.listRulesGrouped.query).toHaveBeenCalledWith({
          groupId: 'test-group',
          type: undefined,
          limit: 20,
          offset: 0,
          search: undefined,
        });
      });
    });

    it('should return domain groups from the API', async () => {
      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      expect(result.current.domainGroups).toHaveLength(2);
      expect(result.current.domainGroups[0].root).toBe('google.com');
      expect(result.current.domainGroups[1].root).toBe('facebook.com');
    });

    it('should return totalGroups and totalRules', async () => {
      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      expect(result.current.totalGroups).toBe(2);
      expect(result.current.totalRules).toBe(3);
    });
  });

  describe('pagination', () => {
    it('should calculate totalPages based on totalGroups', async () => {
      vi.mocked(trpc.groups.listRulesGrouped.query).mockResolvedValue({
        ...mockGroupedResult,
        totalGroups: 45,
      });

      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      // 45 groups / 20 per page = 3 pages (ceiling)
      expect(result.current.totalPages).toBe(3);
    });

    it('should have hasMore true when more pages exist', async () => {
      vi.mocked(trpc.groups.listRulesGrouped.query).mockResolvedValue({
        ...mockGroupedResult,
        totalGroups: 45,
        hasMore: true,
      });

      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      expect(result.current.hasMore).toBe(true);
    });
  });

  describe('selection', () => {
    it('should toggle selection for individual rules', async () => {
      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      expect(result.current.selectedIds.size).toBe(0);

      act(() => {
        result.current.toggleSelection('1');
      });
      expect(result.current.selectedIds.has('1')).toBe(true);

      act(() => {
        result.current.toggleSelection('1');
      });
      expect(result.current.selectedIds.has('1')).toBe(false);
    });

    it('should select all rules in a group', async () => {
      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      act(() => {
        result.current.selectGroup('google.com');
      });

      expect(result.current.selectedIds.has('1')).toBe(true);
      expect(result.current.selectedIds.has('2')).toBe(true);
      expect(result.current.selectedIds.has('3')).toBe(false);
    });

    it('should deselect all rules in a group', async () => {
      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      // Select google group first
      act(() => {
        result.current.selectGroup('google.com');
      });
      expect(result.current.selectedIds.size).toBe(2);

      // Deselect google group
      act(() => {
        result.current.deselectGroup('google.com');
      });
      expect(result.current.selectedIds.size).toBe(0);
    });

    it('should clear all selections', async () => {
      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      act(() => {
        result.current.toggleSelection('1');
        result.current.toggleSelection('2');
      });
      expect(result.current.selectedIds.size).toBe(2);

      act(() => {
        result.current.clearSelection();
      });
      expect(result.current.selectedIds.size).toBe(0);
    });
  });

  describe('filtering', () => {
    it('should pass filter type to API query', async () => {
      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      // Change filter to 'allowed'
      act(() => {
        result.current.setFilter('allowed');
      });

      const queryMock = vi.mocked(trpc.groups.listRulesGrouped.query);

      await waitFor(() => {
        expect(queryMock).toHaveBeenCalledTimes(2);
      });

      expect(queryMock).toHaveBeenLastCalledWith(
        expect.objectContaining({
          type: 'whitelist',
        })
      );

      // Ensure the in-flight fetch resolves before the test ends (prevents act warnings).
      await (queryMock.mock.results[1]?.value ?? Promise.resolve());

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });
    });

    it('should not include a source filter when the allowed filter is applied', async () => {
      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      act(() => {
        result.current.setFilter('allowed');
      });

      const queryMock = vi.mocked(trpc.groups.listRulesGrouped.query);

      await waitFor(() => {
        expect(queryMock).toHaveBeenCalledTimes(2);
      });

      expect(queryMock).toHaveBeenLastCalledWith(
        expect.objectContaining({
          type: 'whitelist',
        })
      );
      expect(queryMock).toHaveBeenLastCalledWith(
        expect.not.objectContaining({
          source: expect.anything() as unknown,
        })
      );

      // Ensure the in-flight fetch resolves before the test ends (prevents act warnings).
      await (queryMock.mock.results[1]?.value ?? Promise.resolve());

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });
    });

    it('groups blocked subdomain and path rules locally with search filtering', async () => {
      vi.mocked(trpc.groups.listRules.query).mockImplementation((input) => {
        if (input.type === 'blocked_subdomain') {
          return Promise.resolve([
            {
              id: 'blocked-1',
              groupId: 'g1',
              type: 'blocked_subdomain',
              source: 'manual' as const,
              value: 'z-search.example.com',
              enabled: true,
              comment: null,
              createdAt: '2024-01-01',
            },
            {
              id: 'blocked-2',
              groupId: 'g1',
              type: 'blocked_subdomain',
              source: 'manual' as const,
              value: 'a-search.example.com',
              enabled: true,
              comment: null,
              createdAt: '2024-01-01',
            },
          ]);
        }
        if (input.type === 'blocked_path') {
          return Promise.resolve([
            {
              id: 'path-1',
              groupId: 'g1',
              type: 'blocked_path',
              source: 'manual' as const,
              value: 'example.com/search-track',
              enabled: true,
              comment: null,
              createdAt: '2024-01-01',
            },
            {
              id: 'path-2',
              groupId: 'g1',
              type: 'blocked_path',
              source: 'manual' as const,
              value: 'other.test/ads',
              enabled: true,
              comment: null,
              createdAt: '2024-01-01',
            },
          ]);
        }
        return Promise.resolve([]);
      });

      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      act(() => {
        result.current.setSearch('search');
        result.current.setFilter('blocked');
      });

      await waitFor(() => {
        expect(result.current.domainGroups).toHaveLength(1);
      });

      expect(result.current.domainGroups[0]).toMatchObject({
        root: 'example.com',
        status: 'blocked',
      });
      expect(result.current.domainGroups[0].rules.map((rule) => rule.value)).toEqual([
        'a-search.example.com',
        'example.com/search-track',
        'z-search.example.com',
      ]);
      expect(result.current.totalGroups).toBe(1);
      expect(result.current.totalRules).toBe(3);
    });
  });

  describe('error handling', () => {
    it('should set error state on API failure', async () => {
      vi.mocked(trpc.groups.listRulesGrouped.query).mockRejectedValue(new Error('API Error'));

      const { result } = renderHook(() =>
        useGroupedRulesManager({
          groupId: 'test-group',
          onToast: mockToast,
        })
      );

      await waitFor(() => {
        expect(result.current.loading).toBe(false);
      });

      expect(result.current.error).toBe('Unable to load rules');
    });
  });
});
