import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const { queryMock, reportErrorMock } = vi.hoisted(() => ({
  queryMock: vi.fn(),
  reportErrorMock: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    auth: {
      me: {
        query: queryMock,
      },
    },
  },
}));

vi.mock('../../lib/reportError', () => ({
  reportError: reportErrorMock,
}));

import { getRoleDisplayLabel, useCurrentUser } from '../useCurrentUser';

describe('useCurrentUser', () => {
  beforeEach(() => {
    queryMock.mockReset();
    reportErrorMock.mockReset();
  });

  it('maps the current profile into display-ready user state', async () => {
    queryMock.mockResolvedValue({
      user: {
        id: 'user-1',
        name: 'Teacher One',
        email: 'teacher@example.com',
        roles: [{ role: 'teacher' }],
        capabilities: { teacherGroups: true },
      },
    });

    const { result } = renderHook(() => useCurrentUser());

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.error).toBeNull();
    expect(result.current.user).toEqual({
      id: 'user-1',
      name: 'Teacher One',
      email: 'teacher@example.com',
      roles: ['teacher'],
      capabilities: { teacherGroups: true },
      initials: 'TO',
      primaryRole: 'teacher',
    });
  });

  it('clears the user and reports an error when the profile request fails', async () => {
    const failure = new Error('profile unavailable');
    queryMock.mockRejectedValue(failure);

    const { result } = renderHook(() => useCurrentUser());

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.user).toBeNull();
    expect(result.current.error).toBe('Error al cargar perfil de usuario');
    expect(reportErrorMock).toHaveBeenCalledWith('Failed to fetch current user:', failure);
  });

  it('supports manual refetch and role display labels', async () => {
    queryMock
      .mockResolvedValueOnce({
        user: {
          id: 'user-1',
          name: '',
          email: 'first@example.com',
          roles: [],
          capabilities: {},
        },
      })
      .mockResolvedValueOnce({
        user: {
          id: 'user-2',
          name: 'Admin Two',
          email: 'admin@example.com',
          roles: [{ role: 'admin' }],
        },
      });

    const { result } = renderHook(() => useCurrentUser());

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.user?.initials).toBe('??');
    expect(result.current.user?.capabilities.teacherGroups).toBe(false);

    await act(async () => {
      await result.current.refetch();
    });

    await waitFor(() => expect(result.current.user?.id).toBe('user-2'));
    expect(result.current.user?.primaryRole).toBe('admin');
    expect(getRoleDisplayLabel('teacher')).toBe('Profesor');
  });
});
