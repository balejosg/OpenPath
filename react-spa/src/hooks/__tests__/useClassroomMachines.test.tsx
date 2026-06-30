import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  Classroom,
  OneOffScheduleWithPermissions,
  ScheduleWithPermissions,
} from '../../types';
import {
  buildEnrollCommands,
  findActiveSchedule,
  sortOneOffSchedules,
  useClassroomMachines,
} from '../useClassroomMachines';

const {
  mockListExemptions,
  mockCreateExemption,
  mockDeleteExemption,
  mockGetAuthTokenForHeader,
  mockCopy,
  mockIsCopied,
  mockClearCopied,
  mockUseScheduleBoundaryInvalidation,
} = vi.hoisted(() => ({
  mockListExemptions: vi.fn(),
  mockCreateExemption: vi.fn(),
  mockDeleteExemption: vi.fn(),
  mockGetAuthTokenForHeader: vi.fn(),
  mockCopy: vi.fn(),
  mockIsCopied: vi.fn(),
  mockClearCopied: vi.fn(),
  mockUseScheduleBoundaryInvalidation: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    classrooms: {
      listExemptions: { query: (input: unknown): unknown => mockListExemptions(input) },
      createExemption: { mutate: (input: unknown): unknown => mockCreateExemption(input) },
      deleteExemption: { mutate: (input: unknown): unknown => mockDeleteExemption(input) },
    },
  },
}));

vi.mock('../../lib/auth-storage', () => ({
  getAuthTokenForHeader: (): unknown => mockGetAuthTokenForHeader(),
}));

vi.mock('../useClipboard', () => ({
  useClipboard: (): unknown => ({
    copy: mockCopy,
    isCopied: mockIsCopied,
    clearCopied: mockClearCopied,
  }),
}));

vi.mock('../useScheduleBoundaryInvalidation', () => ({
  useScheduleBoundaryInvalidation: (input: unknown): unknown =>
    mockUseScheduleBoundaryInvalidation(input),
}));

function decodeEncodedPowerShellCommand(command: string) {
  const encodedCommand = command.split('-EncodedCommand ')[1];
  if (!encodedCommand) {
    throw new Error('Missing PowerShell encoded command');
  }
  return Buffer.from(encodedCommand, 'base64').toString('utf16le');
}

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

describe('useClassroomMachines helpers', () => {
  it('prefers active one-off schedules over weekly ones and sorts one-offs chronologically', () => {
    const active = findActiveSchedule({
      schedules: [weeklySchedule],
      oneOffSchedules: [oneOffSchedule('2026-02-03T10:15:00.000Z', '2026-02-03T10:45:00.000Z')],
      now: new Date('2026-02-03T10:30:00.000Z'),
    });

    expect(active?.id).toContain('2026-02-03T10:15:00.000Z');

    expect(
      sortOneOffSchedules([
        oneOffSchedule('2026-02-03T12:00:00.000Z', '2026-02-03T12:30:00.000Z'),
        oneOffSchedule('2026-02-03T09:00:00.000Z', '2026-02-03T09:30:00.000Z'),
      ]).map((schedule) => schedule.startAt)
    ).toEqual(['2026-02-03T09:00:00.000Z', '2026-02-03T12:00:00.000Z']);
  });

  it('builds Linux and Windows enrollment commands from the classroom id and token', () => {
    const commands = buildEnrollCommands({
      apiUrl: 'https://openpath.test',
      classroomId: 'classroom-1',
      enrollToken: 'token-123',
    });
    const decodedWindowsCommand = decodeEncodedPowerShellCommand(commands.windowsCommand);

    expect(commands.linuxCommand).toContain('Authorization: Bearer token-123');
    expect(commands.linuxCommand).toContain('/api/enroll/classroom-1');
    expect(commands.windowsCommand).toContain('-EncodedCommand ');
    expect(decodedWindowsCommand).toContain("$t='token-123'");
    expect(decodedWindowsCommand).toContain("Authorization=('Bearer '+$t)");
    expect(decodedWindowsCommand).toContain(
      'https://openpath.test/api/enroll/classroom-1/windows.ps1'
    );
  });
});

describe('useClassroomMachines', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockListExemptions.mockResolvedValue({ exemptions: [] });
    mockCreateExemption.mockResolvedValue(undefined);
    mockDeleteExemption.mockResolvedValue(undefined);
    mockGetAuthTokenForHeader.mockReturnValue('auth-token');
    mockIsCopied.mockReturnValue(false);
    mockUseScheduleBoundaryInvalidation.mockReturnValue(undefined);
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ success: true, enrollmentToken: 'ticket-123' }),
      })
    );
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
        useClassroomMachines({
          selectedClassroom,
          schedules: [weeklySchedule],
          oneOffSchedules: [],
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

    const { result } = renderHook(() =>
      useClassroomMachines({
        selectedClassroom: classroom,
        schedules: [weeklySchedule],
        oneOffSchedules: [oneOffSchedule(startAt, endAt)],
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
      scheduleId: `${startAt}-${endAt}`,
      groupId: null,
    });

    await waitFor(() => {
      expect(result.current.exemptionByMachineId.get('machine-1')?.id).toBe('exemption-1');
    });

    await act(async () => {
      await result.current.handleDeleteExemption('machine-1');
    });

    expect(mockDeleteExemption).toHaveBeenCalledWith({ id: 'exemption-1' });
  });

  it('opens the enrollment modal, builds commands, and clears copied state on close', async () => {
    const { result } = renderHook(() =>
      useClassroomMachines({
        selectedClassroom: classroom,
        schedules: [weeklySchedule],
        oneOffSchedules: [],
        refetchClassrooms: vi.fn(),
      })
    );

    await waitFor(() => {
      expect(result.current.loadingExemptions).toBe(false);
    });

    await act(async () => {
      await result.current.enrollModal.open();
    });

    expect(mockGetAuthTokenForHeader).toHaveBeenCalled();
    expect(global.fetch).toHaveBeenCalled();
    expect(result.current.enrollModal.isOpen).toBe(true);
    expect(result.current.enrollModal.enrollCommand).toContain('/api/enroll/classroom-1');

    act(() => {
      result.current.enrollModal.selectPlatform('windows');
    });

    expect(result.current.enrollModal.enrollCommand).toContain('-EncodedCommand ');
    expect(decodeEncodedPowerShellCommand(result.current.enrollModal.enrollCommand)).toContain(
      'windows.ps1'
    );

    act(() => {
      result.current.enrollModal.copy();
      result.current.enrollModal.close();
    });

    expect(mockCopy).toHaveBeenCalled();
    expect(mockClearCopied).toHaveBeenCalled();
    expect(result.current.enrollModal.isOpen).toBe(false);
  });
});
