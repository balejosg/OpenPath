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

// Import the mocked module so tests can drive create/clone rejection scenarios.
import { trpc } from '../../lib/trpc';

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

  it('rejects a new group name that sanitizes to an empty slug', async () => {
    const { result } = renderHookWithQueryClient(() =>
      useGroupsViewModel({ onNavigateToRules: vi.fn() })
    );

    act(() => {
      result.current.setNewGroupName('===');
    });

    await act(async () => {
      await result.current.handleCreateGroup();
    });

    expect(result.current.newGroupError).toBe('Group slug is invalid');
    expect(trpc.groups.create.mutate).not.toHaveBeenCalled();
  });

  it('surfaces a duplicate-slug error when create rejects with CONFLICT', async () => {
    vi.mocked(trpc.groups.create.mutate).mockRejectedValueOnce({ data: { code: 'CONFLICT' } });

    const { result } = renderHookWithQueryClient(() =>
      useGroupsViewModel({ onNavigateToRules: vi.fn() })
    );

    act(() => {
      result.current.setNewGroupName('Nuevo Grupo');
    });

    await act(async () => {
      await result.current.handleCreateGroup();
    });

    expect(result.current.newGroupError).toBe(
      'A group already exists with that identifier (slug): "nuevo-grupo". Try "nuevo-grupo-2".'
    );
  });

  it('surfaces a fallback error on create failure and clears it when the name changes', async () => {
    vi.mocked(trpc.groups.create.mutate).mockRejectedValueOnce(new Error('boom'));

    const { result } = renderHookWithQueryClient(() =>
      useGroupsViewModel({ onNavigateToRules: vi.fn() })
    );

    act(() => {
      result.current.setNewGroupName('Otro Grupo');
    });

    await act(async () => {
      await result.current.handleCreateGroup();
    });

    expect(result.current.newGroupError).toBe('Unable to create group. Try again.');

    act(() => {
      result.current.handleNewGroupNameChange('Fresh Name');
    });

    expect(result.current.newGroupName).toBe('Fresh Name');
    expect(result.current.newGroupError).toBe('');
  });

  it('rejects a clone name that sanitizes to an empty slug', async () => {
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

    act(() => {
      result.current.setCloneName('===');
    });

    await act(async () => {
      await result.current.handleCloneGroup();
    });

    expect(result.current.cloneError).toBe('Group slug is invalid');
    expect(trpc.groups.clone.mutate).not.toHaveBeenCalled();
  });

  it('surfaces a fallback error on clone failure and clears it as the name fields change', async () => {
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
    vi.mocked(trpc.groups.clone.mutate).mockRejectedValueOnce(new Error('boom'));

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

    await act(async () => {
      await result.current.handleCloneGroup();
    });

    expect(result.current.cloneError).toBe('Unable to clone group. Try again.');

    act(() => {
      result.current.handleCloneNameChange('nuevo-nombre');
    });
    expect(result.current.cloneError).toBe('');

    act(() => {
      result.current.handleCloneDisplayNameChange('Nuevo Nombre');
    });
    expect(result.current.cloneDisplayName).toBe('Nuevo Nombre');
  });

  it('opens and closes the clone modal, resetting clone state', async () => {
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

    act(() => {
      result.current.closeCloneModal();
    });

    expect(result.current.cloneSource).toBeNull();
    expect(result.current.showCloneModal).toBe(false);
    expect(result.current.cloneError).toBe('');
  });
});
