import type React from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { Classroom, ClassroomExemption } from '../../../types';
import ClassroomMachinesCard from '../ClassroomMachinesCard';

function buildClassroom(overrides: Partial<Classroom> = {}): Classroom {
  return {
    id: 'classroom-1',
    name: 'Aula 1',
    displayName: 'Aula 1',
    defaultGroupId: 'group-default',
    computerCount: 2,
    activeGroup: null,
    currentGroupId: 'group-default',
    currentGroupDisplayName: 'Grupo Default',
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

function buildExemption(): ClassroomExemption {
  return {
    id: 'exemption-1',
    machineId: 'machine-1',
    machineHostname: 'pc-01',
    classroomId: 'classroom-1',
    scheduleId: 'schedule-1',
    source: 'schedule',
    reason: null,
    createdBy: 'teacher-1',
    createdAt: '2026-03-06T08:00:00.000Z',
    expiresAt: '2026-03-06T11:00:00.000Z',
  };
}

function buildProps(overrides: Partial<React.ComponentProps<typeof ClassroomMachinesCard>> = {}) {
  return {
    admin: true,
    classroom: buildClassroom(),
    hasActiveSchedule: true,
    exemptionByMachineId: new Map([['machine-1', buildExemption()]]),
    exemptionMutating: {},
    exemptionsError: null,
    loadingExemptions: false,
    enrollModalLoadingToken: false,
    onOpenEnrollModal: vi.fn(),
    onCreateExemption: vi.fn(),
    onCreateOperationalExemption: vi.fn(),
    onDeleteExemption: vi.fn(),
    ...overrides,
  };
}

describe('ClassroomMachinesCard', () => {
  it('renders exemptions and forwards machine actions', () => {
    const props = buildProps();
    render(<ClassroomMachinesCard {...props} />);

    expect(screen.getByText(/no restriction/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /install computers/i }));
    fireEvent.click(screen.getByRole('button', { name: 'Restrict' }));
    fireEvent.click(screen.getByRole('button', { name: 'Exempt' }));

    expect(props.onOpenEnrollModal).toHaveBeenCalledTimes(1);
    expect(props.onDeleteExemption).toHaveBeenCalledWith('machine-1');
    expect(screen.getByLabelText('Hours')).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('Hours'), { target: { value: '3' } });
    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'Mantenimiento' } });
    fireEvent.click(screen.getByRole('button', { name: 'Create exemption' }));
    expect(props.onCreateOperationalExemption).toHaveBeenCalledWith(
      'machine-2',
      3,
      'Mantenimiento'
    );
  });

  it('renders empty and teacher no-active-schedule states without release controls', () => {
    render(
      <ClassroomMachinesCard
        {...buildProps({
          admin: false,
          classroom: buildClassroom({
            computerCount: 0,
            onlineMachineCount: 0,
            machines: [],
          }),
          hasActiveSchedule: false,
        })}
      />
    );

    expect(screen.getByText('No active machines')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Release' })).not.toBeInTheDocument();
  });

  it('shows teacher release only for calendar-controlled classrooms', () => {
    const props = buildProps({
      admin: false,
      classroom: buildClassroom({ currentGroupSource: 'manual' }),
      exemptionByMachineId: new Map(),
      hasActiveSchedule: true,
    });
    const { rerender } = render(<ClassroomMachinesCard {...props} />);

    expect(screen.queryByRole('button', { name: 'Release' })).not.toBeInTheDocument();

    rerender(
      <ClassroomMachinesCard
        {...props}
        classroom={buildClassroom({ currentGroupSource: 'schedule' })}
      />
    );

    expect(screen.getAllByRole('button', { name: 'Release' })).toHaveLength(2);
  });

  it('labels operational exemptions before schedule exemptions', () => {
    const operational = {
      ...buildExemption(),
      id: 'exemption-admin',
      source: 'operational' as const,
      scheduleId: null,
      reason: 'Incidencia',
    };

    render(
      <ClassroomMachinesCard
        {...buildProps({
          exemptionByMachineId: new Map([['machine-1', operational]]),
        })}
      />
    );

    expect(screen.getByText(/Admin/)).toBeInTheDocument();
    expect(screen.getByText(/Incidencia/)).toBeInTheDocument();
  });
});
