import type React from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type {
  Classroom,
  OneOffScheduleWithPermissions,
  ScheduleWithPermissions,
} from '../../../types';
import ClassroomDetailPane from '../ClassroomDetailPane';

vi.mock('../../WeeklyCalendar', () => ({
  default: ({ onAddClick }: { onAddClick: (dayOfWeek: number, startTime: string) => void }) => (
    <button data-testid="weekly-calendar" onClick={() => onAddClick(2, '10:00')}>
      weekly-calendar
    </button>
  ),
}));

function buildClassroom(overrides: Partial<Classroom> = {}): Classroom {
  return {
    id: 'classroom-1',
    name: 'Aula 1',
    displayName: 'Aula 1',
    defaultGroupId: 'group-default',
    computerCount: 2,
    activeGroup: null,
    currentGroupId: 'group-default',
    currentGroupSource: 'default',
    status: 'operational',
    onlineMachineCount: 1,
    machines: [
      {
        id: 'machine-1',
        hostname: 'pc-01',
        lastSeen: '2026-03-06T08:00:00.000Z',
        status: 'online',
      },
      {
        id: 'machine-2',
        hostname: 'pc-02',
        lastSeen: null,
        status: 'offline',
      },
    ],
    ...overrides,
  };
}

function buildWeeklySchedule(
  overrides: Partial<ScheduleWithPermissions> = {}
): ScheduleWithPermissions {
  return {
    id: 'schedule-1',
    classroomId: 'classroom-1',
    dayOfWeek: 2,
    startTime: '10:00',
    endTime: '11:00',
    groupId: 'group-default',
    teacherId: 'teacher-1',
    recurrence: 'weekly',
    createdAt: '2026-03-06T08:00:00.000Z',
    isMine: true,
    canEdit: true,
    ...overrides,
  };
}

function buildOneOffSchedule(
  overrides: Partial<OneOffScheduleWithPermissions> = {}
): OneOffScheduleWithPermissions {
  return {
    id: 'one-off-1',
    classroomId: 'classroom-1',
    startAt: '2026-03-06T10:00:00.000Z',
    endAt: '2026-03-06T11:00:00.000Z',
    groupId: 'group-default',
    teacherId: 'teacher-1',
    recurrence: 'one_off',
    createdAt: '2026-03-06T08:00:00.000Z',
    isMine: true,
    canEdit: true,
    ...overrides,
  };
}

function buildProps(overrides: Partial<React.ComponentProps<typeof ClassroomDetailPane>> = {}) {
  return {
    admin: true,
    allowedGroups: [
      { id: 'group-default', name: 'default', displayName: 'Grupo Default', enabled: true },
      { id: 'group-alt', name: 'alt', displayName: 'Grupo Alterno', enabled: true },
    ],
    calendarGroupsForDisplay: [{ id: 'group-default', displayName: 'Grupo Default' }],
    classroomConfigError: '',
    activeGroupSelectValue: '',
    defaultGroupSelectValue: 'group-default',
    selectedClassroom: buildClassroom(),
    selectedClassroomSource: 'default' as const,
    groupById: new Map([
      ['group-default', { id: 'group-default', name: 'default', displayName: 'Grupo Default' }],
      ['group-alt', { id: 'group-alt', name: 'alt', displayName: 'Grupo Alterno' }],
    ]),
    schedules: [buildWeeklySchedule()],
    sortedOneOffSchedules: [buildOneOffSchedule()],
    loadingSchedules: false,
    scheduleError: '',
    activeSchedule: buildWeeklySchedule(),
    exemptionByMachineId: new Map([
      [
        'machine-1',
        {
          id: 'exemption-1',
          machineId: 'machine-1',
          machineHostname: 'pc-01',
          classroomId: 'classroom-1',
          scheduleId: 'schedule-1',
          source: 'schedule' as const,
          reason: null,
          createdBy: 'teacher-1',
          createdAt: '2026-03-06T08:00:00.000Z',
          expiresAt: '2026-03-06T11:00:00.000Z',
        },
      ],
    ]),
    exemptionMutating: {},
    exemptionsError: null,
    loadingExemptions: false,
    enrollModalLoadingToken: false,
    onOpenNewModal: vi.fn(),
    onOpenDeleteDialog: vi.fn(),
    onRequestActiveGroupChange: vi.fn(),
    onDefaultGroupChange: vi.fn(),
    onOpenEnrollModal: vi.fn(),
    onCreateExemption: vi.fn(),
    onCreateOperationalExemption: vi.fn(),
    onDeleteExemption: vi.fn(),
    onOpenScheduleCreate: vi.fn(),
    onOpenScheduleEdit: vi.fn(),
    onRequestScheduleDelete: vi.fn(),
    onOpenOneOffScheduleCreate: vi.fn(),
    onOpenOneOffScheduleEdit: vi.fn(),
    onRequestOneOffScheduleDelete: vi.fn(),
    ...overrides,
  };
}

describe('ClassroomDetailPane', () => {
  it('shows the empty admin state and opens the create modal', () => {
    const props = buildProps({ selectedClassroom: null });
    render(<ClassroomDetailPane {...props} />);

    expect(screen.getByTestId('classrooms-empty-state')).toBeInTheDocument();
    expect(screen.getByText('No classrooms')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /create classroom/i }));

    expect(props.onOpenNewModal).toHaveBeenCalledTimes(1);
  });

  it('hides the create CTA in the empty non-admin state', () => {
    render(<ClassroomDetailPane {...buildProps({ admin: false, selectedClassroom: null })} />);

    expect(screen.getByText('No classrooms')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /create classroom/i })).not.toBeInTheDocument();
  });

  it('renders classroom actions, machine exemptions, and one-off schedule actions', () => {
    const props = buildProps();
    render(<ClassroomDetailPane {...props} />);

    expect(screen.getByText('Classroom settings and status')).toBeInTheDocument();
    expect(screen.getByText('Operational')).toBeInTheDocument();
    expect(screen.getByText(/currently using/i)).toBeInTheDocument();
    expect(
      screen.getByText(
        (_, node) => node?.textContent === 'Currently using Grupo Default by default'
      )
    ).toBeInTheDocument();
    expect(screen.getAllByText(/no restriction/)[0]).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /Delete Classroom/i }));
    fireEvent.click(screen.getByRole('button', { name: /install computers/i }));
    fireEvent.click(screen.getByRole('button', { name: 'Restrict' }));
    fireEvent.click(screen.getByRole('button', { name: 'Exempt' }));
    fireEvent.change(screen.getByLabelText('Hours'), { target: { value: '2' } });
    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'Mantenimiento' } });
    fireEvent.click(screen.getByRole('button', { name: 'Create exemption' }));
    fireEvent.click(screen.getAllByRole('button', { name: 'Edit' })[0]);
    fireEvent.click(screen.getAllByRole('button', { name: 'Delete' })[0]);

    expect(props.onOpenDeleteDialog).toHaveBeenCalledTimes(1);
    expect(props.onOpenEnrollModal).toHaveBeenCalledTimes(1);
    expect(props.onDeleteExemption).toHaveBeenCalledWith('machine-1');
    expect(props.onCreateOperationalExemption).toHaveBeenCalledWith(
      'machine-2',
      2,
      'Mantenimiento'
    );
    expect(props.onOpenOneOffScheduleEdit).toHaveBeenCalledWith(props.sortedOneOffSchedules[0]);
    expect(props.onRequestOneOffScheduleDelete).toHaveBeenCalledWith(
      props.sortedOneOffSchedules[0]
    );
  });

  it('renders loading and error states for schedules and classroom config', () => {
    render(
      <ClassroomDetailPane
        {...buildProps({
          selectedClassroom: buildClassroom({ status: 'degraded' }),
          classroomConfigError: 'You cannot leave the classroom without a default group.',
          loadingSchedules: true,
          scheduleError: 'Unable to load schedules',
        })}
      />
    );

    expect(screen.getByText('Degraded')).toBeInTheDocument();
    expect(
      screen.getByText('You cannot leave the classroom without a default group.')
    ).toBeInTheDocument();
    expect(screen.getByText('Loading schedules...')).toBeInTheDocument();
  });

  it('renders offline and empty-machine states without release controls', () => {
    render(
      <ClassroomDetailPane
        {...buildProps({
          selectedClassroom: buildClassroom({
            status: 'offline',
            computerCount: 0,
            onlineMachineCount: 0,
            machines: [],
          }),
          sortedOneOffSchedules: [],
          activeSchedule: null,
        })}
      />
    );

    expect(screen.getByText('Offline')).toBeInTheDocument();
    expect(screen.getByText('No active machines')).toBeInTheDocument();
    expect(screen.getByText('No one-off assignments.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Release' })).not.toBeInTheDocument();
  });

  it('forwards calendar add actions from the extracted weekly calendar section', () => {
    const props = buildProps();
    render(<ClassroomDetailPane {...props} />);

    fireEvent.click(screen.getByTestId('weekly-calendar'));

    expect(props.onOpenScheduleCreate).toHaveBeenCalledWith(2, '10:00');
  });
});
