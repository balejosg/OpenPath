import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, screen, waitFor, within } from '@testing-library/react';

import TeacherDashboard from '../TeacherDashboard';
import { renderWithQueryClient } from '../../test-utils/query';
import type { ClassroomListItem } from '../../lib/classrooms';
import { USER_KEY } from '../../lib/auth-storage';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../types';

let queryClient: ReturnType<typeof renderWithQueryClient>['queryClient'] | null = null;
const RealDate = Date;

type MockClassroomListItem = ClassroomListItem & {
  defaultGroupDisplayName?: string | null;
  currentGroupDisplayName?: string | null;
};

const {
  mockClassroomsListQuery,
  mockGroupsListQuery,
  mockGetByClassroomQuery,
  mockSetActiveGroup,
  mockSchedulesUpdate,
  mockSchedulesUpdateOneOff,
  mockSchedulesDelete,
  mockReportError,
} = vi.hoisted(() => ({
  mockClassroomsListQuery: vi.fn(),
  mockGroupsListQuery: vi.fn(),
  mockGetByClassroomQuery: vi.fn(),
  mockSetActiveGroup: vi.fn(),
  mockSchedulesUpdate: vi.fn(),
  mockSchedulesUpdateOneOff: vi.fn(),
  mockSchedulesDelete: vi.fn(),
  mockReportError: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    classrooms: {
      list: { query: (): unknown => mockClassroomsListQuery() },
      setActiveGroup: { mutate: (input: unknown): unknown => mockSetActiveGroup(input) },
    },
    groups: {
      list: { query: (): unknown => mockGroupsListQuery() },
    },
    schedules: {
      getByClassroom: { query: (input: unknown): unknown => mockGetByClassroomQuery(input) },
      update: { mutate: (input: unknown): unknown => mockSchedulesUpdate(input) },
      updateOneOff: { mutate: (input: unknown): unknown => mockSchedulesUpdateOneOff(input) },
      delete: { mutate: (input: unknown): unknown => mockSchedulesDelete(input) },
    },
  },
}));

vi.mock('../../lib/reportError', () => ({
  reportError: mockReportError,
}));

vi.mock('../../components/ScheduleFormModal', () => ({
  default: ({
    schedule,
    error,
    onSave,
    onClose,
  }: {
    schedule: ScheduleWithPermissions | null;
    error?: string;
    onSave: (data: {
      dayOfWeek: number;
      startTime: string;
      endTime: string;
      groupId: string;
    }) => void;
    onClose: () => void;
  }) => (
    <div data-testid="schedule-form-modal">
      Horario semanal:{schedule?.id ?? 'nuevo'}
      {error ? <p>{error}</p> : null}
      <button
        onClick={() =>
          onSave({ dayOfWeek: 4, startTime: '10:00', endTime: '11:00', groupId: 'group-2' })
        }
      >
        Guardar horario semanal
      </button>
      <button onClick={onClose}>Cerrar horario semanal</button>
    </div>
  ),
}));

vi.mock('../../components/OneOffScheduleFormModal', () => ({
  default: ({
    schedule,
    error,
    onSave,
    onClose,
  }: {
    schedule: OneOffScheduleWithPermissions | null;
    error?: string;
    onSave: (data: { startAt: string; endAt: string; groupId: string }) => void;
    onClose: () => void;
  }) => (
    <div data-testid="one-off-schedule-form-modal">
      Horario puntual:{schedule?.id ?? 'nuevo'}
      {error ? <p>{error}</p> : null}
      <button
        onClick={() =>
          onSave({
            startAt: '2026-04-30T10:15:00',
            endAt: '2026-04-30T11:00:00',
            groupId: 'group-1',
          })
        }
      >
        Guardar horario puntual
      </button>
      <button onClick={onClose}>Cerrar horario puntual</button>
    </div>
  ),
}));

function renderTeacherDashboard(props?: React.ComponentProps<typeof TeacherDashboard>) {
  const rendered = renderWithQueryClient(<TeacherDashboard {...props} />);
  queryClient = rendered.queryClient;
  return rendered;
}

async function renderTeacherDashboardReady(props?: React.ComponentProps<typeof TeacherDashboard>) {
  const rendered = renderTeacherDashboard(props);
  await Promise.resolve();
  return rendered;
}

function mockNow(isoString: string) {
  const fixed = new RealDate(isoString);

  type MockDateArgs =
    | []
    | [value: string | number | Date]
    | [year: number, monthIndex: number]
    | [year: number, monthIndex: number, date: number]
    | [year: number, monthIndex: number, date: number, hours: number]
    | [year: number, monthIndex: number, date: number, hours: number, minutes: number]
    | [
        year: number,
        monthIndex: number,
        date: number,
        hours: number,
        minutes: number,
        seconds: number,
      ]
    | [
        year: number,
        monthIndex: number,
        date: number,
        hours: number,
        minutes: number,
        seconds: number,
        ms: number,
      ];

  class MockDate extends RealDate {
    constructor(...args: MockDateArgs) {
      if (args.length === 0) {
        super(fixed.valueOf());
        return;
      }

      if (args.length === 1) {
        super(args[0]);
        return;
      }

      if (args.length === 2) {
        super(args[0], args[1]);
        return;
      }

      if (args.length === 3) {
        super(args[0], args[1], args[2]);
        return;
      }

      if (args.length === 4) {
        super(args[0], args[1], args[2], args[3]);
        return;
      }

      if (args.length === 5) {
        super(args[0], args[1], args[2], args[3], args[4]);
        return;
      }

      if (args.length === 6) {
        super(args[0], args[1], args[2], args[3], args[4], args[5]);
        return;
      }

      super(args[0], args[1], args[2], args[3], args[4], args[5], args[6]);
    }

    static now(): number {
      return fixed.valueOf();
    }

    static parse = RealDate.parse;
    static UTC = RealDate.UTC;
  }

  vi.stubGlobal('Date', MockDate);
}

function makeClassroom(overrides: Partial<MockClassroomListItem> = {}): MockClassroomListItem {
  return {
    id: 'classroom-1',
    name: 'lab-a',
    displayName: 'Lab A',
    defaultGroupId: 'group-1',
    defaultGroupDisplayName: 'Investigacion',
    activeGroupId: null,
    createdAt: '2026-04-01T00:00:00.000Z',
    updatedAt: '2026-04-01T00:00:00.000Z',
    currentGroupId: 'group-1',
    currentGroupDisplayName: 'Investigacion',
    currentGroupSource: 'schedule',
    machineCount: 12,
    onlineMachineCount: 10,
    status: 'operational',
    machines: [],
    ...overrides,
  };
}

function makeWeeklySchedule(
  overrides: Partial<ScheduleWithPermissions> = {}
): ScheduleWithPermissions {
  return {
    id: 'weekly-1',
    classroomId: 'classroom-1',
    dayOfWeek: 3,
    startTime: '09:00',
    endTime: '10:00',
    groupId: 'group-1',
    groupDisplayName: 'Investigacion',
    teacherId: 'teacher-1',
    teacherName: 'Ada',
    recurrence: 'weekly',
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
    classroomId: 'classroom-2',
    startAt: '2026-04-29T12:00:00',
    endAt: '2026-04-29T13:00:00',
    groupId: 'group-2',
    groupDisplayName: 'Examen',
    teacherId: 'teacher-1',
    teacherName: 'Ada',
    recurrence: 'one_off',
    createdAt: '2026-04-01T00:00:00',
    updatedAt: '2026-04-01T00:00:00',
    isMine: true,
    canEdit: true,
    ...overrides,
  };
}

function primeDashboardData(options?: {
  classrooms?: MockClassroomListItem[];
  schedulesByClassroom?: Record<
    string,
    {
      schedules: ScheduleWithPermissions[];
      oneOffSchedules: OneOffScheduleWithPermissions[];
    }
  >;
}) {
  const classrooms = options?.classrooms ?? [
    makeClassroom(),
    makeClassroom({
      id: 'classroom-2',
      name: 'lab-b',
      displayName: 'Lab B',
      defaultGroupId: 'group-2',
      defaultGroupDisplayName: 'Examen',
      currentGroupId: 'group-2',
      currentGroupDisplayName: 'Examen',
      machineCount: 14,
      onlineMachineCount: 14,
    }),
  ];

  const schedulesByClassroom = options?.schedulesByClassroom ?? {
    'classroom-1': {
      schedules: [makeWeeklySchedule()],
      oneOffSchedules: [],
    },
    'classroom-2': {
      schedules: [],
      oneOffSchedules: [makeOneOffSchedule()],
    },
  };

  mockClassroomsListQuery.mockResolvedValue(classrooms);
  mockGroupsListQuery.mockResolvedValue([
    { id: 'group-1', name: 'research', displayName: 'Investigacion', enabled: true },
    { id: 'group-2', name: 'exam', displayName: 'Examen', enabled: true },
  ]);
  mockSetActiveGroup.mockResolvedValue({});
  mockSchedulesUpdate.mockResolvedValue({});
  mockSchedulesUpdateOneOff.mockResolvedValue({});
  mockSchedulesDelete.mockResolvedValue({});
  mockGetByClassroomQuery.mockImplementation(({ classroomId }: { classroomId: string }) => {
    return Promise.resolve(
      schedulesByClassroom[classroomId] ?? {
        schedules: [],
        oneOffSchedules: [],
      }
    );
  });
}

afterEach(() => {
  queryClient?.clear();
  queryClient = null;
  vi.unstubAllGlobals();
});

describe('TeacherDashboard', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockNow('2026-04-29T09:30:00');
    localStorage.clear();
    primeDashboardData();
  });

  it('renders the daily focus panel before the weekly calendar and shows the current class label', async () => {
    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    await waitFor(() => {
      expect(screen.getByText('Tu horario de hoy')).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(screen.getByText('Clase actual')).toBeInTheDocument();
    });
    expect(screen.getAllByText('Investigacion - Lab A').length).toBeGreaterThan(0);

    const headings = screen.getAllByRole('heading').map((heading) => heading.textContent);
    expect(headings.indexOf('Tu horario de hoy')).toBeLessThan(headings.indexOf('Semana'));
  });

  it('shows the next class when no entry is active', async () => {
    mockNow('2026-04-29T10:30:00');
    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    expect(await screen.findByText('Siguiente clase')).toBeInTheDocument();
    expect(screen.getAllByText('Examen - Lab B').length).toBeGreaterThan(0);
  });

  it('resets the selected week when pressing Hoy', async () => {
    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    await screen.findByRole('button', { name: 'Ver detalles Investigacion - Lab A 09:00-10:00' });

    fireEvent.click(screen.getByRole('button', { name: 'Semana siguiente' }));
    await waitFor(() => {
      expect(
        screen.queryByRole('button', { name: 'Ver detalles Examen - Lab B 12:00-13:00' })
      ).not.toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: 'Hoy' }));
    expect(
      await screen.findByRole('button', { name: 'Ver detalles Examen - Lab B 12:00-13:00' })
    ).toBeInTheDocument();
  });

  it('shows prior-week entries when pressing previous week', async () => {
    primeDashboardData({
      schedulesByClassroom: {
        'classroom-1': {
          schedules: [
            makeWeeklySchedule({
              dayOfWeek: 3,
              startTime: '08:00',
              endTime: '09:00',
            }),
          ],
          oneOffSchedules: [],
        },
        'classroom-2': {
          schedules: [],
          oneOffSchedules: [
            makeOneOffSchedule({
              startAt: '2026-04-22T12:00:00',
              endAt: '2026-04-22T13:00:00',
            }),
          ],
        },
      },
    });

    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    fireEvent.click(screen.getByRole('button', { name: 'Semana anterior' }));

    expect(
      await screen.findByRole('button', { name: 'Ver detalles Examen - Lab B 12:00-13:00' })
    ).toBeInTheDocument();
  });

  it('opens the detail panel when selecting a calendar block', async () => {
    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    const block = await screen.findByRole('button', {
      name: 'Ver detalles Investigacion - Lab A 09:00-10:00',
    });

    fireEvent.click(block);

    expect(await screen.findByRole('heading', { name: 'Detalle del horario' })).toBeInTheDocument();
    expect(screen.getByText('Semanal')).toBeInTheDocument();
  });

  it('routes classroom actions from the detail panel and opens the expected edit and delete flows', async () => {
    const onNavigateToRules = vi.fn();
    await renderTeacherDashboardReady({ onNavigateToRules });
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    const block = await screen.findByRole('button', {
      name: 'Ver detalles Investigacion - Lab A 09:00-10:00',
    });
    fireEvent.click(block);

    const dialog = await screen.findByRole('dialog', { name: 'Detalle del horario' });

    fireEvent.click(within(dialog).getByRole('button', { name: 'Ver reglas' }));
    expect(onNavigateToRules).toHaveBeenCalledWith({ id: 'group-1', name: 'Investigacion' });

    fireEvent.click(within(dialog).getByRole('button', { name: 'Tomar control' }));
    await waitFor(() => {
      expect(mockSetActiveGroup).toHaveBeenCalledWith({ id: 'classroom-1', groupId: 'group-1' });
    });

    fireEvent.click(within(dialog).getByRole('button', { name: 'Liberar aula' }));
    await waitFor(() => {
      expect(mockSetActiveGroup).toHaveBeenCalledWith({ id: 'classroom-1', groupId: null });
    });

    fireEvent.click(within(dialog).getByRole('button', { name: 'Editar horario' }));
    expect(await screen.findByTestId('schedule-form-modal')).toHaveTextContent(
      'Horario semanal:weekly-1'
    );

    fireEvent.click(screen.getByRole('button', { name: 'Cerrar horario semanal' }));
    await waitFor(() => {
      expect(screen.queryByTestId('schedule-form-modal')).not.toBeInTheDocument();
    });

    fireEvent.click(
      screen.getByRole('button', {
        name: 'Ver detalles Examen - Lab B 12:00-13:00',
      })
    );

    const oneOffDialog = await screen.findByRole('dialog', { name: 'Detalle del horario' });
    fireEvent.click(within(oneOffDialog).getByRole('button', { name: 'Editar horario' }));
    expect(await screen.findByTestId('one-off-schedule-form-modal')).toHaveTextContent(
      'Horario puntual:one-off-1'
    );

    fireEvent.click(screen.getByRole('button', { name: 'Cerrar horario puntual' }));
    await waitFor(() => {
      expect(screen.queryByTestId('one-off-schedule-form-modal')).not.toBeInTheDocument();
    });

    fireEvent.click(
      screen.getByRole('button', {
        name: 'Ver detalles Investigacion - Lab A 09:00-10:00',
      })
    );
    const deleteDialog = await screen.findByRole('dialog', { name: 'Detalle del horario' });
    fireEvent.click(within(deleteDialog).getByRole('button', { name: 'Eliminar horario' }));

    const confirmDialog = await screen.findByRole('dialog', { name: 'Eliminar horario' });
    expect(confirmDialog).toHaveTextContent('Investigacion - Lab A');
    expect(confirmDialog).toHaveTextContent('Semanal');
    expect(confirmDialog).toHaveTextContent('09:00 - 10:00');
  });

  it('saves edited weekly and one-off schedules and refreshes dashboard data', async () => {
    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Ver detalles Investigacion - Lab A 09:00-10:00',
      })
    );
    fireEvent.click(
      within(await screen.findByRole('dialog', { name: 'Detalle del horario' })).getByRole(
        'button',
        { name: 'Editar horario' }
      )
    );
    fireEvent.click(await screen.findByRole('button', { name: 'Guardar horario semanal' }));

    await waitFor(() => {
      expect(mockSchedulesUpdate).toHaveBeenCalledWith({
        id: 'weekly-1',
        dayOfWeek: 4,
        startTime: '10:00',
        endTime: '11:00',
        groupId: 'group-2',
      });
    });
    await waitFor(() => {
      expect(screen.queryByTestId('schedule-form-modal')).not.toBeInTheDocument();
    });

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Ver detalles Examen - Lab B 12:00-13:00',
      })
    );
    fireEvent.click(
      within(await screen.findByRole('dialog', { name: 'Detalle del horario' })).getByRole(
        'button',
        { name: 'Editar horario' }
      )
    );
    fireEvent.click(await screen.findByRole('button', { name: 'Guardar horario puntual' }));

    await waitFor(() => {
      expect(mockSchedulesUpdateOneOff).toHaveBeenCalledWith({
        id: 'one-off-1',
        startAt: '2026-04-30T10:15:00',
        endAt: '2026-04-30T11:00:00',
        groupId: 'group-1',
      });
    });
    await waitFor(() => {
      expect(screen.queryByTestId('one-off-schedule-form-modal')).not.toBeInTheDocument();
    });
    expect(mockClassroomsListQuery).toHaveBeenCalledTimes(3);
  });

  it('deletes a selected schedule and closes both detail and confirm dialogs', async () => {
    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Ver detalles Investigacion - Lab A 09:00-10:00',
      })
    );
    fireEvent.click(
      within(await screen.findByRole('dialog', { name: 'Detalle del horario' })).getByRole(
        'button',
        { name: 'Eliminar horario' }
      )
    );
    fireEvent.click(
      within(await screen.findByRole('dialog', { name: 'Eliminar horario' })).getByRole('button', {
        name: 'Eliminar',
      })
    );

    await waitFor(() => {
      expect(mockSchedulesDelete).toHaveBeenCalledWith({ id: 'weekly-1' });
    });
    await waitFor(() => {
      expect(screen.queryByRole('dialog', { name: 'Eliminar horario' })).not.toBeInTheDocument();
    });
    expect(screen.queryByRole('dialog', { name: 'Detalle del horario' })).not.toBeInTheDocument();
  });

  it('shows schedule mutation errors and reports the failed operation', async () => {
    mockSetActiveGroup.mockRejectedValueOnce(new Error('cannot control'));
    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Ver detalles Investigacion - Lab A 09:00-10:00',
      })
    );
    const dialog = await screen.findByRole('dialog', { name: 'Detalle del horario' });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Tomar control' }));

    expect(await screen.findByText('Error al aplicar el grupo al aula')).toBeInTheDocument();
    expect(mockReportError).toHaveBeenCalledWith(
      'Failed to apply active group:',
      expect.any(Error)
    );

    mockSchedulesUpdate.mockRejectedValueOnce(new Error('Ese tramo horario ya está reservado'));
    fireEvent.click(within(dialog).getByRole('button', { name: 'Editar horario' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Guardar horario semanal' }));

    await waitFor(() => {
      expect(screen.getAllByText('Ese tramo horario ya está reservado').length).toBeGreaterThan(0);
    });
    expect(mockReportError).toHaveBeenCalledWith('Failed to save schedule:', expect.any(Error));
  });

  it('keeps schedule dialogs open when release, one-off save, or delete attempts fail', async () => {
    mockSetActiveGroup.mockRejectedValueOnce(new Error('cannot release'));
    mockSchedulesUpdateOneOff.mockRejectedValueOnce(new Error('one-off conflict'));
    mockSchedulesDelete.mockRejectedValueOnce(new Error('cannot delete'));

    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Ver detalles Investigacion - Lab A 09:00-10:00',
      })
    );
    const weeklyDialog = await screen.findByRole('dialog', { name: 'Detalle del horario' });

    fireEvent.click(within(weeklyDialog).getByRole('button', { name: 'Liberar aula' }));
    expect(await screen.findByText('Error al aplicar el grupo al aula')).toBeInTheDocument();
    expect(mockReportError).toHaveBeenCalledWith('Failed to release classroom:', expect.any(Error));

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Ver detalles Examen - Lab B 12:00-13:00',
      })
    );
    fireEvent.click(
      within(await screen.findByRole('dialog', { name: 'Detalle del horario' })).getByRole(
        'button',
        { name: 'Editar horario' }
      )
    );
    fireEvent.click(await screen.findByRole('button', { name: 'Guardar horario puntual' }));

    await waitFor(() => {
      expect(mockSchedulesUpdateOneOff).toHaveBeenCalledWith({
        id: 'one-off-1',
        startAt: '2026-04-30T10:15:00',
        endAt: '2026-04-30T11:00:00',
        groupId: 'group-1',
      });
    });
    expect(screen.getByTestId('one-off-schedule-form-modal')).toBeInTheDocument();
    expect(mockReportError).toHaveBeenCalledWith(
      'Failed to save one-off schedule:',
      expect.any(Error)
    );

    fireEvent.click(screen.getByRole('button', { name: 'Cerrar horario puntual' }));
    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Ver detalles Investigacion - Lab A 09:00-10:00',
      })
    );
    fireEvent.click(
      within(await screen.findByRole('dialog', { name: 'Detalle del horario' })).getByRole(
        'button',
        { name: 'Eliminar horario' }
      )
    );
    fireEvent.click(
      within(await screen.findByRole('dialog', { name: 'Eliminar horario' })).getByRole('button', {
        name: 'Eliminar',
      })
    );

    await waitFor(() => {
      expect(screen.getAllByText('cannot delete').length).toBeGreaterThan(0);
    });
    expect(screen.getByRole('dialog', { name: 'Eliminar horario' })).toBeInTheDocument();
    expect(mockReportError).toHaveBeenCalledWith('Failed to delete schedule:', expect.any(Error));
  });

  it('confirms manual control replacement before applying it', async () => {
    const onNavigateToRules = vi.fn();
    primeDashboardData({
      classrooms: [
        makeClassroom({
          activeGroupId: 'group-2',
          currentGroupId: 'group-2',
          currentGroupDisplayName: 'Examen',
          currentGroupSource: 'manual',
        }),
      ],
      schedulesByClassroom: {
        'classroom-1': {
          schedules: [makeWeeklySchedule()],
          oneOffSchedules: [],
        },
      },
    });

    await renderTeacherDashboardReady({ onNavigateToRules });
    const [classroomSelect, groupSelect] = await screen.findAllByRole('combobox');

    fireEvent.change(classroomSelect, { target: { value: 'classroom-1' } });
    fireEvent.change(groupSelect, { target: { value: 'group-1' } });
    fireEvent.click(screen.getByRole('button', { name: 'Gestionar reglas de esta política' }));
    expect(onNavigateToRules).toHaveBeenCalledWith({ id: 'group-1', name: 'research' });

    fireEvent.click(screen.getByRole('button', { name: 'Aplicar Política' }));

    const confirmDialog = await screen.findByRole('dialog', { name: 'Confirmar cambio' });
    expect(confirmDialog).toHaveTextContent('Examen');
    expect(confirmDialog).toHaveTextContent('Investigacion');
    expect(mockSetActiveGroup).not.toHaveBeenCalled();

    fireEvent.click(within(confirmDialog).getByRole('button', { name: 'Reemplazar' }));

    await waitFor(() => {
      expect(mockSetActiveGroup).toHaveBeenCalledWith({ id: 'classroom-1', groupId: 'group-1' });
    });
  });

  it('closes the manual replacement dialog without applying the change', async () => {
    primeDashboardData({
      classrooms: [
        makeClassroom({
          activeGroupId: 'group-2',
          currentGroupId: 'group-2',
          currentGroupDisplayName: 'Examen',
          currentGroupSource: 'manual',
        }),
      ],
      schedulesByClassroom: {
        'classroom-1': {
          schedules: [makeWeeklySchedule()],
          oneOffSchedules: [],
        },
      },
    });

    await renderTeacherDashboardReady();
    const [classroomSelect, groupSelect] = await screen.findAllByRole('combobox');

    fireEvent.change(classroomSelect, { target: { value: 'classroom-1' } });
    fireEvent.change(groupSelect, { target: { value: 'group-1' } });
    fireEvent.click(screen.getByRole('button', { name: 'Aplicar Política' }));

    const confirmDialog = await screen.findByRole('dialog', { name: 'Confirmar cambio' });
    fireEvent.click(within(confirmDialog).getByRole('button', { name: 'Cancelar' }));

    await waitFor(() => {
      expect(screen.queryByRole('dialog', { name: 'Confirmar cambio' })).not.toBeInTheDocument();
    });
    expect(mockSetActiveGroup).not.toHaveBeenCalled();
  });

  it('shows and closes a one-off delete confirmation', async () => {
    await renderTeacherDashboardReady();
    await waitFor(() => {
      expect(mockGetByClassroomQuery).toHaveBeenCalledTimes(2);
    });

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Ver detalles Examen - Lab B 12:00-13:00',
      })
    );
    fireEvent.click(
      within(await screen.findByRole('dialog', { name: 'Detalle del horario' })).getByRole(
        'button',
        { name: 'Eliminar horario' }
      )
    );

    const confirmDialog = await screen.findByRole('dialog', { name: 'Eliminar horario' });
    expect(confirmDialog).toHaveTextContent('Tipo: Puntual');

    fireEvent.click(within(confirmDialog).getByRole('button', { name: 'Cancelar' }));

    await waitFor(() => {
      expect(screen.queryByRole('dialog', { name: 'Eliminar horario' })).not.toBeInTheDocument();
    });
    expect(mockSchedulesDelete).not.toHaveBeenCalled();
  });

  it('shows classroom control hints from the server-derived teacher groups capability', async () => {
    mockGroupsListQuery.mockResolvedValue([]);
    const firstRender = await renderTeacherDashboardReady();

    expect(
      await screen.findByText(
        'No tienes políticas asignadas. Pide a un administrador que te asigne una.'
      )
    ).toBeInTheDocument();

    firstRender.unmount();
    localStorage.setItem('openpath_teacher_groups_enabled', '1');
    localStorage.setItem(
      USER_KEY,
      JSON.stringify({
        id: 'teacher-1',
        email: 'teacher@example.com',
        name: 'Teacher',
        roles: [{ role: 'teacher' }],
        capabilities: { teacherGroups: true },
      })
    );
    mockGroupsListQuery.mockResolvedValue([]);
    await renderTeacherDashboardReady();

    expect(
      await screen.findByText('No tienes políticas. Ve a "Mis Políticas" para crear una.')
    ).toBeInTheDocument();
  });

  it('shows retry UI when classroom loading fails and triggers a refetch', async () => {
    mockClassroomsListQuery.mockRejectedValueOnce(new Error('boom'));
    mockClassroomsListQuery.mockResolvedValueOnce([]);

    await renderTeacherDashboardReady();

    expect(await screen.findByText('Error al cargar aulas')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Reintentar' }));

    await waitFor(() => {
      expect(mockClassroomsListQuery).toHaveBeenCalledTimes(2);
    });
    expect(mockReportError).toHaveBeenCalledWith('Failed to fetch classrooms:', expect.any(Error));
  });
});
