import { act, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useClassroomsViewModel } from '../useClassroomsViewModel';
import { renderHookWithQueryClient } from '../../test-utils/query';

const {
  mockIsAdmin,
  mockListClassrooms,
  mockCreateClassroom,
  mockDeleteClassroom,
  mockRefetchGroups,
  mockUseAllowedGroups,
} = vi.hoisted(() => ({
  mockIsAdmin: vi.fn(),
  mockListClassrooms: vi.fn(),
  mockCreateClassroom: vi.fn(),
  mockDeleteClassroom: vi.fn(),
  mockRefetchGroups: vi.fn(),
  mockUseAllowedGroups: vi.fn(),
}));

vi.mock('../../lib/auth', () => ({
  isAdmin: (): unknown => mockIsAdmin(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    classrooms: {
      list: { query: (): unknown => mockListClassrooms() },
      create: { mutate: (input: unknown): unknown => mockCreateClassroom(input) },
      delete: { mutate: (input: unknown): unknown => mockDeleteClassroom(input) },
    },
  },
}));

vi.mock('../useAllowedGroups', () => ({
  useAllowedGroups: (): unknown => mockUseAllowedGroups(),
}));

let queryClient: ReturnType<typeof renderHookWithQueryClient>['queryClient'] | null = null;

function renderUseClassroomsViewModel(initialSelectedClassroomId?: string | null) {
  const rendered = renderHookWithQueryClient(() =>
    useClassroomsViewModel({ initialSelectedClassroomId })
  );
  queryClient = rendered.queryClient;
  return rendered;
}

describe('useClassroomsViewModel', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIsAdmin.mockReturnValue(true);
    mockCreateClassroom.mockResolvedValue({ id: 'classroom-2' });
    mockDeleteClassroom.mockResolvedValue(undefined);
    mockRefetchGroups.mockResolvedValue(undefined);
    mockUseAllowedGroups.mockReturnValue({
      groups: [{ id: 'group-1', name: 'grupo-1', displayName: 'Grupo 1' }],
      groupById: new Map([['group-1', { id: 'group-1', name: 'grupo-1', displayName: 'Grupo 1' }]]),
      options: [{ value: 'group-1', label: 'Grupo 1' }],
      isLoading: false,
      error: null,
      refetch: mockRefetchGroups,
    });
  });

  afterEach(() => {
    queryClient?.clear();
    queryClient = null;
  });

  it('loads classrooms, derives display state, and clears selection when the filter empties the list', async () => {
    mockListClassrooms.mockResolvedValueOnce([
      {
        id: 'classroom-1',
        name: 'Laboratorio Norte',
        displayName: 'Laboratorio Norte',
        defaultGroupId: null,
        activeGroupId: null,
        currentGroupId: null,
        currentGroupSource: 'none',
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
        machines: [],
      },
      {
        id: 'classroom-2',
        name: 'South Classroom',
        displayName: 'South Classroom',
        defaultGroupId: null,
        activeGroupId: null,
        currentGroupId: null,
        currentGroupSource: 'none',
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
        machines: [],
      },
    ]);

    const firstRender = renderUseClassroomsViewModel();
    const { result } = firstRender;

    await waitFor(() => {
      expect(result.current.isInitialLoading).toBe(false);
    });

    expect(result.current.filteredClassrooms).toHaveLength(2);
    expect(result.current.selectedClassroomId).toBe('classroom-1');
    expect(result.current.calendarGroupsForDisplay).toEqual([
      { id: 'group-1', displayName: 'Grupo 1' },
    ]);

    act(() => {
      result.current.setSearchQuery('  south classroom  ');
    });

    await waitFor(() => {
      expect(result.current.filteredClassrooms).toHaveLength(1);
      expect(result.current.filteredClassrooms[0].id).toBe('classroom-2');
      expect(result.current.selectedClassroomId).toBe('classroom-2');
    });

    act(() => {
      result.current.setSearchQuery('sin coincidencias');
    });

    await waitFor(() => {
      expect(result.current.filteredClassrooms).toEqual([]);
      expect(result.current.selectedClassroom).toBeNull();
      expect(result.current.selectedClassroomId).toBeNull();
    });
  });

  it('selects the requested classroom first when a classroom id is provided', async () => {
    mockListClassrooms.mockResolvedValueOnce([
      {
        id: 'classroom-1',
        name: 'Laboratorio Norte',
        displayName: 'Laboratorio Norte',
        defaultGroupId: null,
        activeGroupId: null,
        currentGroupId: null,
        currentGroupSource: 'none',
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
        machines: [],
      },
      {
        id: 'classroom-2',
        name: 'South Classroom',
        displayName: 'South Classroom',
        defaultGroupId: null,
        activeGroupId: null,
        currentGroupId: null,
        currentGroupSource: 'none',
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
        machines: [],
      },
    ]);

    const { result } = renderUseClassroomsViewModel('classroom-2');

    await waitFor(() => {
      expect(result.current.isInitialLoading).toBe(false);
    });

    expect(result.current.selectedClassroomId).toBe('classroom-2');
    expect(result.current.selectedClassroom?.id).toBe('classroom-2');
  });

  it('creates a classroom, refreshes the list, and selects the created row', async () => {
    mockListClassrooms
      .mockResolvedValueOnce([
        {
          id: 'classroom-1',
          name: 'Aula 1',
          displayName: 'Aula 1',
          defaultGroupId: null,
          activeGroupId: null,
          currentGroupId: null,
          currentGroupSource: 'none',
          status: 'operational',
          machineCount: 0,
          onlineMachineCount: 0,
          machines: [],
        },
      ])
      .mockResolvedValueOnce([
        {
          id: 'classroom-1',
          name: 'Aula 1',
          displayName: 'Aula 1',
          defaultGroupId: null,
          activeGroupId: null,
          currentGroupId: null,
          currentGroupSource: 'none',
          status: 'operational',
          machineCount: 0,
          onlineMachineCount: 0,
          machines: [],
        },
        {
          id: 'classroom-2',
          name: 'Aula 2',
          displayName: 'Aula 2',
          defaultGroupId: 'group-1',
          activeGroupId: null,
          currentGroupId: 'group-1',
          currentGroupSource: 'default',
          status: 'operational',
          machineCount: 0,
          onlineMachineCount: 0,
          machines: [],
        },
      ]);

    const { result } = renderUseClassroomsViewModel();

    await waitFor(() => {
      expect(result.current.isInitialLoading).toBe(false);
    });

    act(() => {
      result.current.newModal.open();
      result.current.newModal.setName('Aula 2');
      result.current.newModal.setGroup('group-1');
    });

    await act(async () => {
      await result.current.newModal.create();
    });

    expect(mockCreateClassroom).toHaveBeenCalledWith({
      name: 'Aula 2',
      defaultGroupId: 'group-1',
    });

    await waitFor(() => {
      expect(result.current.selectedClassroomId).toBe('classroom-2');
      expect(result.current.newModal.isOpen).toBe(false);
      expect(result.current.newModal.newName).toBe('');
    });
  });

  it('validates blank classroom names before calling the API', async () => {
    mockListClassrooms.mockResolvedValueOnce([]);

    const { result } = renderUseClassroomsViewModel();

    await waitFor(() => {
      expect(result.current.isInitialLoading).toBe(false);
    });

    act(() => {
      result.current.newModal.open();
      result.current.newModal.setName('   ');
    });

    await act(async () => {
      await result.current.newModal.create();
    });

    expect(mockCreateClassroom).not.toHaveBeenCalled();
    expect(result.current.newModal.newError).toBe('Classroom name is required');
  });

  it('deletes the selected classroom and exposes retry helpers after load failures', async () => {
    mockListClassrooms
      .mockRejectedValueOnce(new Error('boom'))
      .mockResolvedValueOnce([
        {
          id: 'classroom-1',
          name: 'Aula 1',
          displayName: 'Aula 1',
          defaultGroupId: null,
          activeGroupId: null,
          currentGroupId: null,
          currentGroupSource: 'none',
          status: 'operational',
          machineCount: 0,
          onlineMachineCount: 0,
          machines: [],
        },
        {
          id: 'classroom-2',
          name: 'Aula 2',
          displayName: 'Aula 2',
          defaultGroupId: null,
          activeGroupId: null,
          currentGroupId: null,
          currentGroupSource: 'none',
          status: 'operational',
          machineCount: 0,
          onlineMachineCount: 0,
          machines: [],
        },
      ])
      .mockResolvedValueOnce([
        {
          id: 'classroom-2',
          name: 'Aula 2',
          displayName: 'Aula 2',
          defaultGroupId: null,
          activeGroupId: null,
          currentGroupId: null,
          currentGroupSource: 'none',
          status: 'operational',
          machineCount: 0,
          onlineMachineCount: 0,
          machines: [],
        },
      ]);

    const { result } = renderUseClassroomsViewModel();

    await waitFor(() => {
      expect(result.current.isInitialLoading).toBe(false);
      expect(result.current.loadError).toBe('Unable to load classrooms');
    });

    act(() => {
      result.current.retryLoad();
    });

    await waitFor(() => {
      expect(result.current.filteredClassrooms).toHaveLength(2);
      expect(mockRefetchGroups).toHaveBeenCalledTimes(1);
    });

    act(() => {
      result.current.deleteDialog.open();
    });

    await act(async () => {
      await result.current.deleteDialog.confirm();
    });

    expect(mockDeleteClassroom).toHaveBeenCalledWith({ id: 'classroom-1' });

    await waitFor(() => {
      expect(result.current.selectedClassroomId).toBe('classroom-2');
      expect(result.current.deleteDialog.isOpen).toBe(false);
    });
  });
});
