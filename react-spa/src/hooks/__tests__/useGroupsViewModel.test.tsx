import { beforeEach, describe, expect, it, vi } from 'vitest';
import { act, waitFor } from '@testing-library/react';
import { renderHookWithQueryClient } from '../../test-utils/query';
import { useGroupsViewModel } from '../useGroupsViewModel';

const { mockLibraryList } = vi.hoisted(() => ({
  mockLibraryList: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    groups: {
      libraryList: { query: mockLibraryList },
      create: { mutate: vi.fn() },
      update: { mutate: vi.fn() },
      clone: { mutate: vi.fn() },
    },
  },
}));

const { isAdminMock, isTeacherMock } = vi.hoisted(() => ({
  isAdminMock: vi.fn(() => true),
  isTeacherMock: vi.fn(() => false),
}));

vi.mock('../../lib/auth', () => ({
  isAdmin: () => isAdminMock(),
  isTeacher: () => isTeacherMock(),
}));

vi.mock('../useAllowedGroups', () => ({
  useAllowedGroups: () => ({
    groups: [
      {
        id: 'group-1',
        name: 'grupo-1',
        displayName: 'Grupo 1',
        whitelistCount: 1,
        blockedSubdomainCount: 0,
        blockedPathCount: 0,
        enabled: true,
        visibility: 'private',
      },
    ],
    groupById: new Map(),
    isLoading: false,
    error: null,
    refetch: vi.fn(),
  }),
}));

vi.mock('../../lib/reportError', () => ({
  reportError: vi.fn(),
}));

describe('useGroupsViewModel', () => {
  beforeEach(() => {
    isAdminMock.mockReturnValue(true);
    isTeacherMock.mockReturnValue(false);
  });

  it('lets a teacher create groups without any capability flag', () => {
    isAdminMock.mockReturnValue(false);
    isTeacherMock.mockReturnValue(true);

    const { result } = renderHookWithQueryClient(() =>
      useGroupsViewModel({ onNavigateToRules: vi.fn() })
    );

    expect(result.current.canCreateGroups).toBe(true);
    expect(result.current.teacherCanCreateGroups).toBe(true);
  });

  it('loads library groups and opens clone modal with derived defaults', async () => {
    mockLibraryList.mockResolvedValueOnce([
      {
        id: 'library-1',
        name: 'biblioteca',
        displayName: 'Biblioteca',
        whitelistCount: 2,
        blockedSubdomainCount: 0,
        blockedPathCount: 0,
        enabled: true,
        visibility: 'instance_public',
      },
    ]);

    const { result } = renderHookWithQueryClient(() =>
      useGroupsViewModel({ onNavigateToRules: vi.fn() })
    );

    act(() => {
      result.current.setActiveView('library');
    });

    await waitFor(() => {
      expect(result.current.groups[0]?.id).toBe('library-1');
    });

    act(() => {
      result.current.openCloneModal('library-1');
    });

    expect(result.current.cloneSource?.id).toBe('library-1');
    expect(result.current.cloneName).toBe('biblioteca-copia');
    expect(result.current.cloneDisplayName).toBe('Biblioteca Copia');
  });
});
