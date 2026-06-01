import { act, renderHook } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Classroom } from '../../types';
import { useClassroomConfigActions } from '../useClassroomConfigActions';

const mockUpdateMutate = vi.fn();
const mockSetActiveGroupMutate = vi.fn();

vi.mock('../../lib/trpc', () => ({
  trpc: {
    classrooms: {
      update: { mutate: (input: unknown): unknown => mockUpdateMutate(input) },
      setActiveGroup: { mutate: (input: unknown): unknown => mockSetActiveGroupMutate(input) },
    },
  },
}));

describe('useClassroomConfigActions', () => {
  const selectedClassroom: Classroom = {
    id: 'classroom-1',
    name: 'Aula 1',
    displayName: 'Aula 1',
    computerCount: 0,
    activeGroup: null,
    currentGroupId: 'group-default',
    defaultGroupId: 'group-default',
    status: 'operational',
    onlineMachineCount: 0,
  };

  const setSelectedClassroom = vi.fn();
  const refetchClassrooms = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    refetchClassrooms.mockResolvedValue([
      {
        ...selectedClassroom,
        defaultGroupId: 'group-calendar',
      },
    ]);
  });

  it('updates active group and refreshes the selected classroom', async () => {
    mockSetActiveGroupMutate.mockResolvedValue(undefined);
    refetchClassrooms.mockResolvedValue([
      {
        ...selectedClassroom,
        activeGroup: 'group-manual',
      },
    ]);

    const { result } = renderHook(() =>
      useClassroomConfigActions({
        selectedClassroom,
        refetchClassrooms,
        setSelectedClassroom,
      })
    );

    await act(async () => {
      await result.current.handleGroupChange('group-manual');
    });

    expect(mockSetActiveGroupMutate).toHaveBeenCalledWith({
      id: 'classroom-1',
      groupId: 'group-manual',
    });
    expect(setSelectedClassroom).toHaveBeenCalledWith(
      expect.objectContaining({ activeGroup: 'group-manual' })
    );
  });

  it('normalizes empty active group changes to null', async () => {
    mockSetActiveGroupMutate.mockResolvedValue(undefined);

    const { result } = renderHook(() =>
      useClassroomConfigActions({
        selectedClassroom,
        refetchClassrooms,
        setSelectedClassroom,
      })
    );

    await act(async () => {
      await result.current.handleGroupChange('');
    });

    expect(mockSetActiveGroupMutate).toHaveBeenCalledWith({
      id: 'classroom-1',
      groupId: null,
    });
  });

  it('updates selected classroom when default group change succeeds', async () => {
    mockUpdateMutate.mockResolvedValue(undefined);

    const { result } = renderHook(() =>
      useClassroomConfigActions({
        selectedClassroom,
        refetchClassrooms,
        setSelectedClassroom,
      })
    );

    await act(async () => {
      await result.current.handleDefaultGroupChange('group-calendar');
    });

    expect(mockUpdateMutate).toHaveBeenCalledWith({
      id: 'classroom-1',
      defaultGroupId: 'group-calendar',
    });
    expect(setSelectedClassroom).toHaveBeenCalledWith(
      expect.objectContaining({ defaultGroupId: 'group-calendar' })
    );
  });

  it('sets actionable error when clearing default group fails with 400-like error', async () => {
    mockUpdateMutate.mockRejectedValue(new Error('BAD_REQUEST: default group required'));

    const { result } = renderHook(() =>
      useClassroomConfigActions({
        selectedClassroom,
        refetchClassrooms,
        setSelectedClassroom,
      })
    );

    await act(async () => {
      await result.current.handleDefaultGroupChange('');
    });

    expect(result.current.classroomConfigError).toBe(
      'You cannot leave the classroom without a default group while no valid active group exists.'
    );
  });

  it('sets fallback error when updating a non-empty default group fails', async () => {
    mockUpdateMutate.mockRejectedValue(new Error('FORBIDDEN'));

    const { result } = renderHook(() =>
      useClassroomConfigActions({
        selectedClassroom,
        refetchClassrooms,
        setSelectedClassroom,
      })
    );

    await act(async () => {
      await result.current.handleDefaultGroupChange('group-other');
    });

    expect(result.current.classroomConfigError).toBe(
      'Unable to update the default group. Try again.'
    );
  });

  it('updates captive portal domains through the classroom update model', async () => {
    mockUpdateMutate.mockResolvedValue(undefined);

    const { result } = renderHook(() =>
      useClassroomConfigActions({
        selectedClassroom,
        refetchClassrooms,
        setSelectedClassroom,
      })
    );

    await act(async () => {
      await result.current.handleCaptivePortalDomainsChange([' Login.EXAMPLE.test ']);
    });

    expect(mockUpdateMutate).toHaveBeenCalledWith({
      id: 'classroom-1',
      captivePortalDomains: [' Login.EXAMPLE.test '],
    });
  });

  it('sets actionable error when captive portal domain update fails', async () => {
    mockUpdateMutate.mockRejectedValue({ data: { code: 'BAD_REQUEST' } });

    const { result } = renderHook(() =>
      useClassroomConfigActions({
        selectedClassroom,
        refetchClassrooms,
        setSelectedClassroom,
      })
    );

    await act(async () => {
      await result.current.handleCaptivePortalDomainsChange(['https://portal.example.test']);
    });

    expect(result.current.classroomConfigError).toBe(
      'Enter exact domain names only, separated by commas.'
    );
  });

  it('ignores config changes when no classroom is selected', async () => {
    const { result } = renderHook(() =>
      useClassroomConfigActions({
        selectedClassroom: null,
        refetchClassrooms,
        setSelectedClassroom,
      })
    );

    await act(async () => {
      await result.current.handleGroupChange('group-manual');
      await result.current.handleDefaultGroupChange('group-manual');
      await result.current.handleCaptivePortalDomainsChange(['portal.example.test']);
    });

    expect(mockSetActiveGroupMutate).not.toHaveBeenCalled();
    expect(mockUpdateMutate).not.toHaveBeenCalled();
  });
});
