import type React from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../../types';
import ClassroomScheduleCard from '../ClassroomScheduleCard';

vi.mock('../../WeeklyCalendar', () => ({
  default: ({
    onAddClick,
    fillAvailable,
  }: {
    onAddClick: (dayOfWeek: number, startTime: string) => void;
    fillAvailable?: boolean;
  }) => (
    <button
      data-testid="weekly-calendar"
      data-fill-available={fillAvailable ? 'true' : 'false'}
      onClick={() => onAddClick(2, '10:00')}
    >
      weekly-calendar
    </button>
  ),
}));

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
    groupDisplayName: 'Grupo Default',
    teacherId: 'teacher-1',
    teacherName: 'Teacher Uno',
    recurrence: 'one_off',
    createdAt: '2026-03-06T08:00:00.000Z',
    isMine: true,
    canEdit: true,
    ...overrides,
  };
}

function buildProps(overrides: Partial<React.ComponentProps<typeof ClassroomScheduleCard>> = {}) {
  return {
    admin: true,
    calendarGroupsForDisplay: [{ id: 'group-default', displayName: 'Grupo Default' }],
    groupById: new Map([
      ['group-default', { id: 'group-default', name: 'default', displayName: 'Grupo Default' }],
    ]),
    schedules: [buildWeeklySchedule()],
    sortedOneOffSchedules: [buildOneOffSchedule()],
    loadingSchedules: false,
    scheduleError: '',
    onOpenScheduleCreate: vi.fn(),
    onOpenScheduleEdit: vi.fn(),
    onRequestScheduleDelete: vi.fn(),
    onOpenOneOffScheduleCreate: vi.fn(),
    onOpenOneOffScheduleEdit: vi.fn(),
    onRequestOneOffScheduleDelete: vi.fn(),
    ...overrides,
  };
}

describe('ClassroomScheduleCard', () => {
  it('renders schedule actions and forwards weekly and one-off interactions', () => {
    const props = buildProps();
    render(<ClassroomScheduleCard {...props} />);

    fireEvent.click(screen.getByTestId('weekly-calendar'));
    fireEvent.click(screen.getAllByRole('button', { name: 'Edit' })[0]);
    fireEvent.click(screen.getAllByRole('button', { name: 'Delete' })[0]);

    expect(props.onOpenScheduleCreate).toHaveBeenCalledWith(2, '10:00');
    expect(props.onOpenOneOffScheduleEdit).toHaveBeenCalledWith(props.sortedOneOffSchedules[0]);
    expect(props.onRequestOneOffScheduleDelete).toHaveBeenCalledWith(
      props.sortedOneOffSchedules[0]
    );
  });

  it('renders loading, error, and reserved fallback states', () => {
    const { rerender } = render(
      <ClassroomScheduleCard
        {...buildProps({
          admin: false,
          loadingSchedules: true,
          sortedOneOffSchedules: [
            buildOneOffSchedule({
              groupId: 'group-hidden',
              groupDisplayName: null,
              canEdit: false,
              teacherName: 'Teacher Dos',
            }),
          ],
        })}
      />
    );

    expect(screen.getByText('Loading schedules...')).toBeInTheDocument();

    rerender(
      <ClassroomScheduleCard
        {...buildProps({
          admin: false,
          scheduleError: 'Unable to load schedules',
          sortedOneOffSchedules: [
            buildOneOffSchedule({
              groupId: 'group-hidden',
              groupDisplayName: null,
              canEdit: false,
              teacherName: 'Teacher Dos',
            }),
          ],
        })}
      />
    );

    expect(screen.getByText('Unable to load schedules')).toBeInTheDocument();
    expect(screen.getByText('Reserved by Teacher Dos')).toBeInTheDocument();
  });

  it('enables desktop-constrained fill mode without changing the mobile defaults', () => {
    const { container, rerender } = render(<ClassroomScheduleCard {...buildProps()} />);

    expect(container.firstElementChild).not.toHaveClass('lg:min-h-0', 'lg:overflow-hidden');
    expect(screen.getByTestId('weekly-calendar')).toHaveAttribute('data-fill-available', 'false');

    rerender(<ClassroomScheduleCard {...buildProps({ fillAvailable: true })} />);

    expect(container.firstElementChild).toHaveClass('lg:min-h-0', 'lg:overflow-hidden');
    expect(container.firstElementChild).not.toHaveClass('min-h-0', 'overflow-hidden');
    expect(screen.getByTestId('weekly-calendar')).toHaveAttribute('data-fill-available', 'true');
    expect(screen.getByText('One-off assignments').closest('div.mt-5')).toHaveClass(
      'lg:overflow-y-auto',
      'lg:max-h-56'
    );
    expect(screen.getByText('One-off assignments').closest('div.mt-5')).not.toHaveClass(
      'max-h-48',
      'overflow-y-auto'
    );
  });
});
