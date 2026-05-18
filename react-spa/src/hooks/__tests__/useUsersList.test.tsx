import { act, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { UserRole } from '../../types';
import { useUsersList } from '../useUsersList';
import { renderHookWithQueryClient } from '../../test-utils/query';

let queryClient: ReturnType<typeof renderHookWithQueryClient>['queryClient'] | null = null;

const { mockUsersList } = vi.hoisted(() => ({
  mockUsersList: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    users: {
      list: { query: (): unknown => mockUsersList() },
    },
  },
}));

describe('useUsersList', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockUsersList.mockResolvedValue([]);
  });

  afterEach(() => {
    queryClient?.clear();
    queryClient = null;
  });

  function renderUseUsersList() {
    const rendered = renderHookWithQueryClient(() => useUsersList());
    queryClient = rendered.queryClient;
    return rendered;
  }

  it('fetches users on mount and maps roles/status', async () => {
    mockUsersList.mockResolvedValueOnce([
      {
        id: 'u1',
        name: 'Teacher User',
        email: 'teacher@example.com',
        isActive: true,
        roles: [{ role: 'teacher' }],
      },
    ]);

    const { result } = renderUseUsersList();

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.error).toBeNull();
    expect(result.current.users).toEqual([
      {
        id: 'u1',
        name: 'Teacher User',
        email: 'teacher@example.com',
        roles: [UserRole.TEACHER],
        status: 'Active',
      },
    ]);
  });

  it('refetches users via fetchUsers()', async () => {
    mockUsersList.mockResolvedValueOnce([
      {
        id: 'u1',
        name: 'User 1',
        email: 'user1@example.com',
        isActive: true,
        roles: [{ role: 'teacher' }],
      },
    ]);

    const { result } = renderUseUsersList();

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.users[0]?.id).toBe('u1');

    mockUsersList.mockResolvedValueOnce([
      {
        id: 'u2',
        name: 'User 2',
        email: 'user2@example.com',
        isActive: false,
        roles: [{ role: 'admin' }],
      },
    ]);

    await act(async () => {
      await result.current.fetchUsers();
    });

    await waitFor(() => {
      expect(result.current.users[0]?.id).toBe('u2');
    });
  });

  it('surfaces fetch errors via error state', async () => {
    mockUsersList.mockRejectedValueOnce(new Error('network'));

    const { result } = renderUseUsersList();

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.error).toBe('Unable to load users');
    expect(result.current.users).toEqual([]);
  });
});
