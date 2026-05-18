import { act, renderHook } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Classroom } from '../../types';
import { useClassroomGroupControls } from '../useClassroomGroupControls';

const { mockHandleGroupChange, mockHandleDefaultGroupChange, mockUseClassroomConfigActions } =
  vi.hoisted(() => ({
    mockHandleGroupChange: vi.fn(),
    mockHandleDefaultGroupChange: vi.fn(),
    mockUseClassroomConfigActions: vi.fn(),
  }));

vi.mock('../useClassroomConfigActions', () => ({
  useClassroomConfigActions: (params: unknown): unknown => mockUseClassroomConfigActions(params),
}));

const groupById = new Map([
  ['group-default', { id: 'group-default', name: 'default', displayName: 'Grupo Default' }],
  ['group-manual', { id: 'group-manual', name: 'manual', displayName: 'Grupo Manual' }],
  ['group-next', { id: 'group-next', name: 'next', displayName: 'Grupo Next' }],
]);

const baseClassroom: Classroom = {
  id: 'classroom-1',
  name: 'Aula 1',
  displayName: 'Aula 1',
  defaultGroupId: 'group-default',
  computerCount: 0,
  activeGroup: null,
  currentGroupId: 'group-default',
  currentGroupSource: 'default',
  status: 'operational',
  onlineMachineCount: 0,
};

describe('useClassroomGroupControls', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockUseClassroomConfigActions.mockReturnValue({
      classroomConfigError: '',
      handleGroupChange: mockHandleGroupChange,
      handleDefaultGroupChange: mockHandleDefaultGroupChange,
    });
  });

  it('derives selector values for the selected classroom', () => {
    const { result } = renderHook(() =>
      useClassroomGroupControls({
        admin: true,
        selectedClassroom: baseClassroom,
        groupById,
        refetchClassrooms: vi.fn(),
        setSelectedClassroom: vi.fn(),
      })
    );

    expect(result.current.selectedClassroomSource).toBe('default');
    expect(result.current.activeGroupSelectValue).toBe('');
    expect(result.current.defaultGroupSelectValue).toBe('group-default');
    expect(result.current.resolveGroupName('group-manual')).toBe('Grupo Manual');
  });

  it('changes the active group immediately when there is no manual group to replace', () => {
    const { result } = renderHook(() =>
      useClassroomGroupControls({
        admin: true,
        selectedClassroom: baseClassroom,
        groupById,
        refetchClassrooms: vi.fn(),
        setSelectedClassroom: vi.fn(),
      })
    );

    act(() => {
      result.current.requestActiveGroupChange('group-next');
    });

    expect(mockHandleGroupChange).toHaveBeenCalledWith('group-next');
    expect(result.current.activeGroupOverwriteConfirm).toBeNull();
  });

  it('opens an overwrite confirmation when replacing an existing manual group', () => {
    const classroom = {
      ...baseClassroom,
      activeGroup: 'group-manual',
      currentGroupId: 'group-manual',
      currentGroupSource: 'manual' as const,
    };

    const { result } = renderHook(() =>
      useClassroomGroupControls({
        admin: true,
        selectedClassroom: classroom,
        groupById,
        refetchClassrooms: vi.fn(),
        setSelectedClassroom: vi.fn(),
      })
    );

    act(() => {
      result.current.requestActiveGroupChange('group-next');
    });

    expect(mockHandleGroupChange).not.toHaveBeenCalled();
    expect(result.current.activeGroupOverwriteConfirm).toEqual({
      classroomId: 'classroom-1',
      currentGroupId: 'group-manual',
      nextGroupId: 'group-next',
    });
  });

  it('confirms overwrite requests through the shared classroom action hook', async () => {
    mockHandleGroupChange.mockResolvedValue(undefined);
    const classroom = {
      ...baseClassroom,
      activeGroup: 'group-manual',
      currentGroupId: 'group-manual',
      currentGroupSource: 'manual' as const,
    };

    const { result } = renderHook(() =>
      useClassroomGroupControls({
        admin: true,
        selectedClassroom: classroom,
        groupById,
        refetchClassrooms: vi.fn(),
        setSelectedClassroom: vi.fn(),
      })
    );

    act(() => {
      result.current.requestActiveGroupChange('group-next');
    });

    await act(async () => {
      await result.current.confirmActiveGroupOverwrite();
    });

    expect(mockHandleGroupChange).toHaveBeenCalledWith('group-next');
    expect(result.current.activeGroupOverwriteConfirm).toBeNull();
    expect(result.current.activeGroupOverwriteLoading).toBe(false);
  });
});
