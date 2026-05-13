import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  Classroom,
  OneOffScheduleWithPermissions,
  ScheduleWithPermissions,
} from '../../types';
import { useClassroomExemptions } from '../useClassroomExemptions';

const {
  mockCreateExemption,
  mockCreateOperationalExemption,
  mockDeleteExemption,
  mockListExemptions,
  mockUseScheduleBoundaryInvalidation,
} = vi.hoisted(() => ({
  mockCreateExemption: vi.fn(),
  mockCreateOperationalExemption: vi.fn(),
  mockDeleteExemption: vi.fn(),
  mockListExemptions: vi.fn(),
  mockUseScheduleBoundaryInvalidation: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    classrooms: {
      listExemptions: { query: (input: unknown): unknown => mockListExemptions(input) },
      createExemption: { mutate: (input: unknown): unknown => mockCreateExemption(input) },
      createOperationalExemption: {
        mutate: (input: unknown): unknown => mockCreateOperationalExemption(input),
      },
      deleteExemption: { mutate: (input: unknown): unknown => mockDeleteExemption(input) },
    },
  },
}));

vi.mock('../useScheduleBoundaryInvalidation', () => ({
  useScheduleBoundaryInvalidation: (input: unknown): unknown =>
    mockUseScheduleBoundaryInvalidation(input),
}));

const classroom: Classroom = {
  id: 'classroom-1',
  name: 'Aula 1',
  displayName: 'Aula 1',
  defaultGroupId: 'group-default',
  computerCount: 1,
  activeGroup: null,
  currentGroupId: 'group-default',
  currentGroupSource: 'default',
  status: 'operational',
  onlineMachineCount: 1,
  machines: [{ id: 'machine-1', hostname: 'pc-1', lastSeen: null, status: 'online' }],
};

const weeklySchedule: ScheduleWithPermissions = {
  id: 'schedule-1',
  classroomId: 'classroom-1',
  dayOfWeek: 2,
  startTime: '10:00',
  endTime: '11:00',
  groupId: 'group-1',
  teacherId: 'teacher-1',
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
  isMine: true,
  canEdit: true,
};

const oneOffSchedule = (startAt: string, endAt: string): OneOffScheduleWithPermissions => ({
  id: `${startAt}-${endAt}`,
  classroomId: 'classroom-1',
  startAt,
  endAt,
  groupId: 'group-1',
  teacherId: 'teacher-1',
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
  isMine: true,
  canEdit: true,
});

describe('useClassroomExemptions', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockListExemptions.mockResolvedValue({ exemptions: [] });
    mockCreateExemption.mockResolvedValue(undefined);
    mockCreateOperationalExemption.mockResolvedValue(undefined);
    mockDeleteExemption.mockResolvedValue(undefined);
    mockUseScheduleBoundaryInvalidation.mockReturnValue(undefined);
  });

  it('loads exemptions for the selected classroom and clears them when the classroom disappears', async () => {
    mockListExemptions.mockResolvedValueOnce({
      exemptions: [
        {
          id: 'exemption-1',
          machineId: 'machine-1',
          machineHostname: 'pc-1',
          classroomId: 'classroom-1',
          scheduleId: 'schedule-1',
          createdBy: 'teacher-1',
          createdAt: '2026-02-03T10:00:00.000Z',
          expiresAt: '2026-02-03T11:00:00.000Z',
        },
      ],
    });

    const { result, rerender } = renderHook(
      ({ selectedClassroom }) =>
        useClassroomExemptions({
          selectedClassroom,
          activeSchedule: weeklySchedule,
          scheduleBoundarySources: [weeklySchedule],
          refetchClassrooms: vi.fn(),
        }),
      { initialProps: { selectedClassroom: classroom as Classroom | null } }
    );

    await waitFor(() => {
      expect(mockListExemptions).toHaveBeenCalledWith({ classroomId: 'classroom-1' });
      expect(result.current.exemptionByMachineId.get('machine-1')?.id).toBe('exemption-1');
    });

    rerender({ selectedClassroom: null });

    await waitFor(() => {
      expect(result.current.exemptionByMachineId.size).toBe(0);
      expect(result.current.exemptionsError).toBeNull();
    });
  });

  it('creates and deletes machine exemptions around the active schedule', async () => {
    const now = new Date();
    const startAt = new Date(now.getTime() - 15 * 60 * 1000).toISOString();
    const endAt = new Date(now.getTime() + 15 * 60 * 1000).toISOString();

    mockListExemptions
      .mockResolvedValueOnce({ exemptions: [] })
      .mockResolvedValueOnce({
        exemptions: [
          {
            id: 'exemption-1',
            machineId: 'machine-1',
            machineHostname: 'pc-1',
            classroomId: 'classroom-1',
            scheduleId: 'schedule-1',
            createdBy: 'teacher-1',
            createdAt: '2026-02-03T10:00:00.000Z',
            expiresAt: '2026-02-03T11:00:00.000Z',
          },
        ],
      })
      .mockResolvedValueOnce({ exemptions: [] });

    const activeSchedule = oneOffSchedule(startAt, endAt);
    const { result } = renderHook(() =>
      useClassroomExemptions({
        selectedClassroom: classroom,
        activeSchedule,
        scheduleBoundarySources: [weeklySchedule, activeSchedule],
        refetchClassrooms: vi.fn(),
      })
    );

    await waitFor(() => {
      expect(result.current.loadingExemptions).toBe(false);
    });

    await act(async () => {
      await result.current.handleCreateExemption('machine-1');
    });

    expect(mockCreateExemption).toHaveBeenCalledWith({
      machineId: 'machine-1',
      classroomId: 'classroom-1',
      scheduleId: activeSchedule.id,
    });

    await waitFor(() => {
      expect(result.current.exemptionByMachineId.get('machine-1')?.id).toBe('exemption-1');
    });

    await act(async () => {
      await result.current.handleDeleteExemption('machine-1');
    });

    expect(mockDeleteExemption).toHaveBeenCalledWith({ id: 'exemption-1' });
  });

  it('creates operational exemptions with admin duration and reason', async () => {
    const { result } = renderHook(() =>
      useClassroomExemptions({
        selectedClassroom: classroom,
        activeSchedule: weeklySchedule,
        scheduleBoundarySources: [weeklySchedule],
        refetchClassrooms: vi.fn(),
      })
    );

    await waitFor(() => {
      expect(result.current.loadingExemptions).toBe(false);
    });

    await act(async () => {
      await result.current.handleCreateOperationalExemption('machine-1', 4, 'Mantenimiento');
    });

    expect(mockCreateOperationalExemption).toHaveBeenCalledWith({
      machineId: 'machine-1',
      classroomId: 'classroom-1',
      durationHours: 4,
      reason: 'Mantenimiento',
    });
  });

  it('reports an error when the initial exemptions fetch fails', async () => {
    mockListExemptions.mockRejectedValueOnce(new Error('boom'));

    const { result } = renderHook(() =>
      useClassroomExemptions({
        selectedClassroom: classroom,
        activeSchedule: weeklySchedule,
        scheduleBoundarySources: [weeklySchedule],
        refetchClassrooms: vi.fn(),
      })
    );

    await waitFor(() => {
      expect(result.current.loadingExemptions).toBe(false);
      expect(result.current.exemptionsError).toBe('Error al cargar exenciones');
      expect(result.current.exemptionByMachineId.size).toBe(0);
    });
  });

  it('refreshes classrooms and exemptions on schedule boundaries when no active group is pinned', async () => {
    const refetchClassrooms = vi.fn().mockResolvedValue([]);

    renderHook(() =>
      useClassroomExemptions({
        selectedClassroom: classroom,
        activeSchedule: weeklySchedule,
        scheduleBoundarySources: [weeklySchedule],
        refetchClassrooms,
      })
    );

    await waitFor(() => {
      expect(mockListExemptions).toHaveBeenCalledTimes(1);
    });

    const boundaryInput = mockUseScheduleBoundaryInvalidation.mock.calls[0]?.[0] as
      | { enabled: boolean; onBoundary: () => void }
      | undefined;

    expect(boundaryInput?.enabled).toBe(true);

    act(() => {
      boundaryInput?.onBoundary();
    });

    await waitFor(() => {
      expect(refetchClassrooms).toHaveBeenCalledTimes(1);
      expect(mockListExemptions).toHaveBeenCalledTimes(2);
    });
  });

  it('disables schedule-boundary invalidation when the classroom already has an active group', async () => {
    renderHook(() =>
      useClassroomExemptions({
        selectedClassroom: { ...classroom, activeGroup: 'group-live' },
        activeSchedule: weeklySchedule,
        scheduleBoundarySources: [weeklySchedule],
        refetchClassrooms: vi.fn(),
      })
    );

    await waitFor(() => {
      expect(mockUseScheduleBoundaryInvalidation).toHaveBeenCalled();
    });

    const boundaryInput = mockUseScheduleBoundaryInvalidation.mock.calls[0]?.[0] as
      | { enabled: boolean }
      | undefined;

    expect(boundaryInput?.enabled).toBe(false);
  });
});
