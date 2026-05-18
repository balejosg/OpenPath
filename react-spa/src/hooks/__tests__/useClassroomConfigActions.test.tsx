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
});
