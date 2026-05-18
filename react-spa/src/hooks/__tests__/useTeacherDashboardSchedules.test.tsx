import { act, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { ClassroomListModel } from '../../lib/classrooms';
import { renderHookWithQueryClient } from '../../test-utils/query';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../types';
import { useTeacherDashboardSchedules } from '../useTeacherDashboardSchedules';

let queryClient: ReturnType<typeof renderHookWithQueryClient>['queryClient'] | null = null;

const { mockGetByClassroomQuery, mockGetMineQuery } = vi.hoisted(() => ({
  mockGetByClassroomQuery: vi.fn(),
  mockGetMineQuery: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    schedules: {
      getByClassroom: { query: (input: unknown): unknown => mockGetByClassroomQuery(input) },
      getMine: { query: (input: unknown): unknown => mockGetMineQuery(input) },
    },
  },
}));

const classrooms: readonly ClassroomListModel[] = [
  {
    id: 'classroom-1',
    name: 'lab-a',
    displayName: 'Lab A',
    defaultGroupId: 'group-1',
    defaultGroupDisplayName: 'Investigacion',
    machineCount: 12,
    activeGroupId: null,
    currentGroupId: 'group-1',
    currentGroupDisplayName: 'Investigacion',
    currentGroupSource: 'schedule',
    status: 'operational',
    onlineMachineCount: 10,
    machines: [],
  },
  {
    id: 'classroom-2',
    name: 'lab-b',
    displayName: 'Lab B',
    defaultGroupId: 'group-2',
    defaultGroupDisplayName: 'Examen',
    machineCount: 14,
    activeGroupId: null,
    currentGroupId: 'group-2',
    currentGroupDisplayName: 'Examen',
    currentGroupSource: 'schedule',
    status: 'operational',
    onlineMachineCount: 13,
    machines: [],
  },
];

function makeSchedule(overrides: Partial<ScheduleWithPermissions> = {}): ScheduleWithPermissions {
  return {
    id: 'schedule-1',
    classroomId: 'classroom-1',
    dayOfWeek: 1,
    startTime: '08:00',
    endTime: '09:00',
    groupId: 'group-1',
    groupDisplayName: 'Investigacion',
    teacherId: 'teacher-1',
    teacherName: 'Ada',
    recurrence: undefined,
    createdAt: '2026-04-01T00:00:00.000Z',
    updatedAt: '2026-04-01T00:00:00.000Z',
    isMine: true,
    canEdit: true,
    ...overrides,
  };
}

function makeOneOffSchedule(
  overrides: Partial<OneOffScheduleWithPermissions> = {}
): OneOffScheduleWithPermissions {
  return {
    id: 'one-off-1',
    classroomId: 'classroom-1',
    startAt: '2026-04-29T08:00:00.000Z',
    endAt: '2026-04-29T09:00:00.000Z',
    groupId: 'group-1',
    groupDisplayName: 'Investigacion',
    teacherId: 'teacher-1',
    teacherName: 'Ada',
    recurrence: 'one_off',
    createdAt: '2026-04-01T00:00:00.000Z',
    updatedAt: '2026-04-01T00:00:00.000Z',
    isMine: true,
    canEdit: true,
    ...overrides,
  };
}

function renderUseTeacherDashboardSchedules(input: readonly ClassroomListModel[]) {
  const rendered = renderHookWithQueryClient(() => useTeacherDashboardSchedules(input));
  queryClient = rendered.queryClient;
  return rendered;
}

describe('useTeacherDashboardSchedules', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockGetMineQuery.mockResolvedValue([]);
    mockGetByClassroomQuery
      .mockResolvedValueOnce({
        schedules: [
          makeSchedule({ id: 'schedule-1', classroomId: 'classroom-1', isMine: true }),
          makeSchedule({ id: 'schedule-2', classroomId: 'classroom-1', isMine: false }),
        ],
        oneOffSchedules: [
          makeOneOffSchedule({ id: 'one-off-1', classroomId: 'classroom-1', isMine: true }),
          makeOneOffSchedule({ id: 'one-off-2', classroomId: 'classroom-1', isMine: false }),
        ],
      })
      .mockResolvedValueOnce({
        schedules: [
          makeSchedule({
            id: 'schedule-3',
            classroomId: 'classroom-2',
            groupId: 'group-2',
            groupDisplayName: 'Examen',
            isMine: true,
          }),
        ],
        oneOffSchedules: [
          makeOneOffSchedule({
            id: 'one-off-3',
            classroomId: 'classroom-2',
            groupId: 'group-2',
            groupDisplayName: 'Examen',
            isMine: true,
          }),
        ],
      });
  });

  afterEach(() => {
    queryClient?.clear();
    queryClient = null;
  });

  it('queries each visible classroom once and keeps only teacher-owned schedules', async () => {
    const { result } = renderUseTeacherDashboardSchedules(classrooms);

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    expect(mockGetByClassroomQuery).toHaveBeenNthCalledWith(1, { classroomId: 'classroom-1' });
    expect(mockGetByClassroomQuery).toHaveBeenNthCalledWith(2, { classroomId: 'classroom-2' });
    expect(mockGetMineQuery).not.toHaveBeenCalled();

    expect(result.current.weeklySchedules.map((schedule) => schedule.id)).toEqual([
      'schedule-1',
      'schedule-3',
    ]);
    expect(result.current.oneOffSchedules.map((schedule) => schedule.id)).toEqual([
      'one-off-1',
      'one-off-3',
    ]);
    expect(result.current.error).toBeNull();
  });

  it('returns empty arrays and skips schedule queries when there are no classrooms', () => {
    const { result } = renderUseTeacherDashboardSchedules([]);

    expect(mockGetByClassroomQuery).not.toHaveBeenCalled();
    expect(mockGetMineQuery).not.toHaveBeenCalled();
    expect(result.current.weeklySchedules).toEqual([]);
    expect(result.current.oneOffSchedules).toEqual([]);
    expect(result.current.loading).toBe(false);
    expect(result.current.error).toBeNull();
  });

  it('surfaces a localized error when any classroom schedule query fails', async () => {
    mockGetByClassroomQuery.mockReset();
    mockGetByClassroomQuery
      .mockResolvedValueOnce({
        schedules: [makeSchedule({ id: 'schedule-1', classroomId: 'classroom-1' })],
        oneOffSchedules: [],
      })
      .mockRejectedValueOnce(new Error('boom'));

    const { result } = renderUseTeacherDashboardSchedules(classrooms);

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.error).toBe('Unable to load your schedules');
  });

  it('refetches every classroom schedule query', async () => {
    const { result } = renderUseTeacherDashboardSchedules(classrooms);

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    mockGetByClassroomQuery.mockResolvedValue({ schedules: [], oneOffSchedules: [] });

    await act(async () => {
      await result.current.refetchSchedules();
    });

    expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(4);
  });
});
