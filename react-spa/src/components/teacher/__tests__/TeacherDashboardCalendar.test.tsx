import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../../types';
import type { TeacherScheduleEntry } from '../teacher-schedule-model';
import { TeacherDashboardCalendar } from '../TeacherDashboardCalendar';

function makeSchedule(overrides: Partial<ScheduleWithPermissions> = {}): ScheduleWithPermissions {
  return {
    id: 'schedule-1',
    classroomId: 'classroom-1',
    dayOfWeek: 1,
    startTime: '09:00',
    endTime: '10:00',
    groupId: 'group-1',
    groupDisplayName: 'Group One',
    teacherId: 'teacher-1',
    teacherName: 'Ada',
    recurrence: 'weekly',
    createdAt: '2026-04-01T00:00:00',
    updatedAt: '2026-04-01T00:00:00',
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
    startAt: '2026-04-30T10:15:00',
    endAt: '2026-04-30T11:00:00',
    groupId: 'group-2',
    groupDisplayName: 'Group Two',
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

function makeEntry(overrides: Partial<TeacherScheduleEntry> = {}): TeacherScheduleEntry {
  const kind = overrides.kind ?? 'weekly';
  const schedule =
    overrides.schedule ?? (kind === 'one_off' ? makeOneOffSchedule() : makeSchedule());

  return {
    kind,
    id: 'entry-1',
    schedule,
    dayOfWeek: 1,
    startAt: new Date(2026, 3, 27, 9, 0, 0, 0),
    endAt: new Date(2026, 3, 27, 10, 0, 0, 0),
    startTime: '09:00',
    endTime: '10:00',
    startMinutes: 9 * 60,
    endMinutes: 10 * 60,
    classroomId: 'classroom-1',
    colorKey: 'classroom-1',
    label: 'Group One - Lab A',
    groupName: 'Group One',
    classroomName: 'Lab A',
    canEdit: true,
    laneIndex: 0,
    laneCount: 1,
    ...overrides,
  };
}

function buildProps(
  overrides: Partial<React.ComponentProps<typeof TeacherDashboardCalendar>> = {}
) {
  return {
    entries: [
      makeEntry(),
      makeEntry({
        id: 'entry-one-off',
        kind: 'one_off',
        schedule: makeOneOffSchedule(),
        dayOfWeek: 4,
        startAt: new Date(2026, 3, 30, 10, 15, 0, 0),
        endAt: new Date(2026, 3, 30, 11, 0, 0, 0),
        startTime: '10:15',
        endTime: '11:00',
        startMinutes: 10 * 60 + 15,
        endMinutes: 11 * 60,
        classroomId: 'classroom-2',
        colorKey: 'classroom-2',
        label: 'Group Two - Lab B',
        groupName: 'Group Two',
        classroomName: 'Lab B',
      }),
    ],
    loading: false,
    error: null,
    weekMonday: new Date(2026, 3, 27, 0, 0, 0, 0),
    onPrevWeek: vi.fn(),
    onNextWeek: vi.fn(),
    onToday: vi.fn(),
    onRetry: vi.fn(),
    onSelectEntry: vi.fn(),
    ...overrides,
  };
}

describe('TeacherDashboardCalendar', () => {
  it('renders weekly and one-off labels, marks one-offs, and handles selection and today navigation', () => {
    const props = buildProps();

    render(<TeacherDashboardCalendar {...props} />);

    expect(screen.getByRole('heading', { name: 'Week' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Previous week' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Today' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Next week' })).toBeInTheDocument();
    expect(screen.getAllByText('Group One - Lab A').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Group Two - Lab B').length).toBeGreaterThan(0);
    expect(screen.getAllByText('One-off').length).toBeGreaterThan(0);

    const oneOffBlock = screen.getByRole('button', {
      name: 'View details Group Two - Lab B 10:15-11:00',
    });
    expect(oneOffBlock).toHaveAttribute('data-kind', 'one_off');

    fireEvent.click(screen.getByRole('button', { name: 'Today' }));
    expect(props.onToday).toHaveBeenCalledTimes(1);

    fireEvent.click(oneOffBlock);
    expect(props.onSelectEntry).toHaveBeenCalledWith(props.entries[1]);
  });

  it('excludes entries outside the selected week and never renders inline edit or delete buttons inside blocks', () => {
    const outsideWeekEntry = makeEntry({
      id: 'entry-outside-week',
      kind: 'one_off',
      schedule: makeOneOffSchedule({
        id: 'one-off-outside-week',
        startAt: '2026-05-06T10:15:00',
        endAt: '2026-05-06T11:00:00',
      }),
      dayOfWeek: 3,
      startAt: new Date(2026, 4, 6, 10, 15, 0, 0),
      endAt: new Date(2026, 4, 6, 11, 0, 0, 0),
      startTime: '10:15',
      endTime: '11:00',
      startMinutes: 10 * 60 + 15,
      endMinutes: 11 * 60,
      label: 'Outside Week - Lab Z',
      groupName: 'Outside Week',
      classroomId: 'classroom-z',
      classroomName: 'Lab Z',
      colorKey: 'classroom-z',
    });

    render(
      <TeacherDashboardCalendar
        {...buildProps({
          entries: [makeEntry(), outsideWeekEntry],
        })}
      />
    );

    expect(screen.queryByText('Outside Week - Lab Z')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^Edit/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^Delete/ })).not.toBeInTheDocument();
  });

  it('renders loading, error, and empty states with the expected copy', () => {
    const loadingProps = buildProps({ loading: true });
    const { rerender } = render(<TeacherDashboardCalendar {...loadingProps} />);

    expect(screen.getByText('Loading your schedule...')).toBeInTheDocument();

    const errorProps = buildProps({ error: 'Unable to load your schedules' });
    rerender(<TeacherDashboardCalendar {...errorProps} />);

    expect(screen.getByText('Unable to load your schedules')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    expect(errorProps.onRetry).toHaveBeenCalledTimes(1);

    rerender(<TeacherDashboardCalendar {...buildProps({ entries: [] })} />);

    expect(
      screen.getByText(
        'You have no schedules assigned this week. Manage schedules from each classroom.'
      )
    ).toBeInTheDocument();
  });
});
