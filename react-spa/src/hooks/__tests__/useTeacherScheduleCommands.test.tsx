import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import type { TeacherScheduleEntry } from '../../components/teacher/teacher-schedule-model';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../types';
import { useTeacherScheduleCommands } from '../useTeacherScheduleCommands';

type MockFn = ReturnType<typeof vi.fn<(input?: unknown) => unknown>>;
type ReportErrorMock = ReturnType<typeof vi.fn<(message: string, err: unknown) => void>>;

const makeWeeklySchedule = (
  overrides: Partial<ScheduleWithPermissions> = {}
): ScheduleWithPermissions => ({
  id: 'weekly-1',
  classroomId: 'classroom-1',
  dayOfWeek: 1,
  startTime: '09:00',
  endTime: '10:00',
  groupId: 'group-1',
  teacherId: 'teacher-1',
  recurrence: undefined,
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
  groupDisplayName: 'Investigacion',
  isMine: true,
  canEdit: true,
  ...overrides,
});

const makeOneOffSchedule = (
  overrides: Partial<OneOffScheduleWithPermissions> = {}
): OneOffScheduleWithPermissions => ({
  id: 'one-off-1',
  classroomId: 'classroom-2',
  startAt: '2026-04-30T12:00:00.000Z',
  endAt: '2026-04-30T13:00:00.000Z',
  groupId: 'group-2',
  teacherId: 'teacher-1',
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
  groupDisplayName: 'Examen',
  isMine: true,
  canEdit: true,
  ...overrides,
});

function makeEntry(
  overrides: Partial<TeacherScheduleEntry> = {},
  schedule: ScheduleWithPermissions | OneOffScheduleWithPermissions = makeWeeklySchedule()
): TeacherScheduleEntry {
  const kind = 'dayOfWeek' in schedule ? 'weekly' : 'one_off';
  return {
    kind,
    id: schedule.id,
    schedule,
    dayOfWeek: 1,
    startAt: new Date('2026-04-27T09:00:00'),
    endAt: new Date('2026-04-27T10:00:00'),
    startTime: '09:00',
    endTime: '10:00',
    startMinutes: 540,
    endMinutes: 600,
    classroomId: schedule.classroomId,
    colorKey: schedule.groupId,
    label: 'Investigacion - Lab A',
    groupName: 'research',
    classroomName: 'Lab A',
    canEdit: true,
    laneIndex: 0,
    laneCount: 1,
    ...overrides,
  };
}

function renderUseTeacherScheduleCommands(
  overrides: {
    refetchClassrooms?: () => Promise<unknown>;
    refetchMySchedules?: () => Promise<unknown>;
    onNavigateToRules?: (group: { id: string; name: string }) => void;
    update?: MockFn;
    updateOneOff?: MockFn;
    deleteSchedule?: MockFn;
    setActiveGroup?: MockFn;
    reportError?: ReportErrorMock;
  } = {}
) {
  const refetchClassrooms = overrides.refetchClassrooms ?? vi.fn().mockResolvedValue(undefined);
  const refetchMySchedules = overrides.refetchMySchedules ?? vi.fn().mockResolvedValue(undefined);
  const update = overrides.update ?? vi.fn().mockResolvedValue(undefined);
  const updateOneOff = overrides.updateOneOff ?? vi.fn().mockResolvedValue(undefined);
  const deleteSchedule = overrides.deleteSchedule ?? vi.fn().mockResolvedValue(undefined);
  const setActiveGroup = overrides.setActiveGroup ?? vi.fn().mockResolvedValue(undefined);
  const reportError = overrides.reportError ?? vi.fn();

  const result = renderHook(() =>
    useTeacherScheduleCommands({
      refetchClassrooms,
      refetchMySchedules,
      onNavigateToRules: overrides.onNavigateToRules,
      reportError,
      trpcClient: {
        classrooms: {
          setActiveGroup: { mutate: setActiveGroup },
        },
        schedules: {
          update: { mutate: update },
          updateOneOff: { mutate: updateOneOff },
          delete: { mutate: deleteSchedule },
        },
      },
    })
  );

  return {
    ...result,
    refetchClassrooms,
    refetchMySchedules,
    update,
    updateOneOff,
    deleteSchedule,
    setActiveGroup,
    reportError,
  };
}

describe('useTeacherScheduleCommands', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('saves a weekly schedule, refreshes dashboard data, and clears the editing entry', async () => {
    const weeklyEntry = makeEntry();
    const { result, update, refetchClassrooms, refetchMySchedules } =
      renderUseTeacherScheduleCommands();

    act(() => {
      result.current.handleEditSchedule(weeklyEntry);
    });

    await act(async () => {
      await result.current.handleSaveWeeklySchedule({
        dayOfWeek: 4,
        startTime: '10:00',
        endTime: '11:00',
        groupId: 'group-2',
      });
    });

    expect(update).toHaveBeenCalledWith({
      id: 'weekly-1',
      dayOfWeek: 4,
      startTime: '10:00',
      endTime: '11:00',
      groupId: 'group-2',
    });
    expect(refetchClassrooms).toHaveBeenCalledTimes(1);
    expect(refetchMySchedules).toHaveBeenCalledTimes(1);
    expect(result.current.editingEntry).toBeNull();
  });

  it('saves a one-off schedule, refreshes dashboard data, and clears the editing entry', async () => {
    const oneOffEntry = makeEntry(
      { label: 'Examen - Lab B', startTime: '12:00', endTime: '13:00' },
      makeOneOffSchedule()
    );
    const { result, updateOneOff, refetchClassrooms, refetchMySchedules } =
      renderUseTeacherScheduleCommands();

    act(() => {
      result.current.handleEditSchedule(oneOffEntry);
    });

    await act(async () => {
      await result.current.handleSaveOneOffSchedule({
        startAt: '2026-04-30T10:15:00',
        endAt: '2026-04-30T11:00:00',
        groupId: 'group-1',
      });
    });

    expect(updateOneOff).toHaveBeenCalledWith({
      id: 'one-off-1',
      startAt: '2026-04-30T10:15:00',
      endAt: '2026-04-30T11:00:00',
      groupId: 'group-1',
    });
    expect(refetchClassrooms).toHaveBeenCalledTimes(1);
    expect(refetchMySchedules).toHaveBeenCalledTimes(1);
    expect(result.current.editingEntry).toBeNull();
  });

  it('deletes a schedule, refreshes dashboard data, and clears selected and delete entries', async () => {
    const weeklyEntry = makeEntry();
    const { result, deleteSchedule, refetchClassrooms, refetchMySchedules } =
      renderUseTeacherScheduleCommands();

    act(() => {
      result.current.handleOpenClassroom(weeklyEntry);
      result.current.handleDeleteSchedule(weeklyEntry);
    });

    await act(async () => {
      await result.current.handleConfirmDeleteSchedule();
    });

    expect(deleteSchedule).toHaveBeenCalledWith({ id: 'weekly-1' });
    expect(refetchClassrooms).toHaveBeenCalledTimes(1);
    expect(refetchMySchedules).toHaveBeenCalledTimes(1);
    expect(result.current.deleteEntry).toBeNull();
    expect(result.current.selectedEntry).toBeNull();
  });

  it('takes control and releases a classroom through setActiveGroup', async () => {
    const weeklyEntry = makeEntry();
    const { result, setActiveGroup } = renderUseTeacherScheduleCommands();

    await act(async () => {
      await result.current.handleTakeControl(weeklyEntry);
      await result.current.handleReleaseClassroom(weeklyEntry);
    });

    expect(setActiveGroup).toHaveBeenNthCalledWith(1, {
      id: 'classroom-1',
      groupId: 'group-1',
    });
    expect(setActiveGroup).toHaveBeenNthCalledWith(2, {
      id: 'classroom-1',
      groupId: null,
    });
  });

  it('formats conflict errors as the stable Spanish schedule message', async () => {
    const update = vi.fn().mockRejectedValue({ data: { code: 'CONFLICT' } });
    const reportError = vi.fn();
    const { result } = renderUseTeacherScheduleCommands({ update, reportError });

    act(() => {
      result.current.handleEditSchedule(makeEntry());
    });

    await act(async () => {
      await result.current.handleSaveWeeklySchedule({
        dayOfWeek: 4,
        startTime: '10:00',
        endTime: '11:00',
        groupId: 'group-2',
      });
    });

    await waitFor(() => {
      expect(result.current.scheduleError).toBe('That time slot is already reserved');
    });
    expect(result.current.editingEntry).not.toBeNull();
    expect(reportError).toHaveBeenCalledWith('Failed to save schedule:', {
      data: { code: 'CONFLICT' },
    });
  });
});
