import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { TeacherScheduleEntry, TeacherScheduleFocus } from '../teacher-schedule-model';
import { TeacherTodayFocusPanel } from '../TeacherTodayFocusPanel';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../../types';

function makeSchedule(overrides: Partial<ScheduleWithPermissions> = {}): ScheduleWithPermissions {
  return {
    id: 'schedule-1',
    classroomId: 'classroom-1',
    dayOfWeek: 1,
    startTime: '08:00',
    endTime: '09:00',
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
    classroomId: 'classroom-1',
    startAt: '2026-04-29T09:00:00',
    endAt: '2026-04-29T10:00:00',
    groupId: 'group-1',
    groupDisplayName: 'Group One',
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
    dayOfWeek: 3,
    startAt: new Date(2026, 3, 29, 9, 0, 0, 0),
    endAt: new Date(2026, 3, 29, 10, 0, 0, 0),
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
  overrides: Partial<{ focus: TeacherScheduleFocus; loading: boolean; error: string | null }> = {}
) {
  const currentEntry = makeEntry({
    id: 'entry-current',
    kind: 'one_off',
    schedule: makeOneOffSchedule(),
  });
  const laterEntry = makeEntry({
    id: 'entry-later',
    startAt: new Date(2026, 3, 29, 12, 0, 0, 0),
    endAt: new Date(2026, 3, 29, 13, 0, 0, 0),
    startTime: '12:00',
    endTime: '13:00',
    label: 'Group Two - Lab B',
    groupName: 'Group Two',
    classroomId: 'classroom-2',
    classroomName: 'Lab B',
    colorKey: 'classroom-2',
    schedule: makeSchedule({
      id: 'schedule-2',
      classroomId: 'classroom-2',
      groupId: 'group-2',
      groupDisplayName: 'Group Two',
      startTime: '12:00',
      endTime: '13:00',
    }),
  });

  return {
    focus: {
      currentEntry,
      nextEntry: null,
      todayEntries: [currentEntry, laterEntry],
    },
    loading: false,
    error: null,
    onRetry: vi.fn(),
    onOpenClassroom: vi.fn(),
    onOpenRules: vi.fn(),
    onTakeControl: vi.fn(),
    onReleaseClassroom: vi.fn(),
    onSelectEntry: vi.fn(),
    ...overrides,
  };
}

describe('TeacherTodayFocusPanel', () => {
  it('renders the current class headline, focus details, one-off badge, and today agenda', () => {
    const props = buildProps();

    render(<TeacherTodayFocusPanel {...props} />);

    expect(screen.getByText('Current class')).toBeInTheDocument();
    expect(screen.getByText('Group One - Lab A')).toBeInTheDocument();
    expect(screen.getByText('09:00-10:00')).toBeInTheDocument();
    expect(screen.getByText('One-off')).toBeInTheDocument();
    expect(screen.getByText('Today')).toBeInTheDocument();
    expect(screen.getByText('12:00-13:00')).toBeInTheDocument();
    expect(screen.getByText('Group Two - Lab B')).toBeInTheDocument();
  });

  it('calls the visible classroom and detail actions with the focused entry', () => {
    const props = buildProps();

    render(<TeacherTodayFocusPanel {...props} />);

    fireEvent.click(screen.getByRole('button', { name: 'Go to classroom' }));
    fireEvent.click(screen.getByRole('button', { name: 'View rules' }));
    fireEvent.click(screen.getByRole('button', { name: 'Take control' }));
    fireEvent.click(screen.getByRole('button', { name: 'Release classroom' }));
    fireEvent.click(screen.getByRole('button', { name: 'View details' }));

    expect(props.onOpenClassroom).toHaveBeenCalledWith(props.focus.currentEntry);
    expect(props.onOpenRules).toHaveBeenCalledWith(props.focus.currentEntry);
    expect(props.onTakeControl).toHaveBeenCalledWith(props.focus.currentEntry);
    expect(props.onReleaseClassroom).toHaveBeenCalledWith(props.focus.currentEntry);
    expect(props.onSelectEntry).toHaveBeenCalledWith(props.focus.currentEntry);
  });

  it('renders the next class headline when there is no current class', () => {
    const nextEntry = makeEntry({
      id: 'entry-next',
      startAt: new Date(2026, 3, 29, 11, 0, 0, 0),
      endAt: new Date(2026, 3, 29, 12, 0, 0, 0),
      startTime: '11:00',
      endTime: '12:00',
      label: 'Group Three - Lab C',
      groupName: 'Group Three',
      classroomId: 'classroom-3',
      classroomName: 'Lab C',
      colorKey: 'classroom-3',
      schedule: makeSchedule({
        id: 'schedule-3',
        classroomId: 'classroom-3',
        groupId: 'group-3',
        groupDisplayName: 'Group Three',
        startTime: '11:00',
        endTime: '12:00',
      }),
    });
    const props = buildProps({
      focus: {
        currentEntry: null,
        nextEntry,
        todayEntries: [nextEntry],
      },
    });

    render(<TeacherTodayFocusPanel {...props} />);

    expect(screen.getByText('Next class')).toBeInTheDocument();
    expect(screen.getByText('Group Three - Lab C')).toBeInTheDocument();
    expect(screen.getByText('11:00-12:00')).toBeInTheDocument();
  });

  it('renders loading and error states with retry support', () => {
    const loadingProps = buildProps({ loading: true });
    const { rerender } = render(<TeacherTodayFocusPanel {...loadingProps} />);

    expect(screen.getByText('Loading your schedule...')).toBeInTheDocument();

    const errorProps = buildProps({ error: 'Unable to load your schedules' });
    rerender(<TeacherTodayFocusPanel {...errorProps} />);

    expect(screen.getByText('Unable to load your schedules')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    expect(errorProps.onRetry).toHaveBeenCalledTimes(1);
  });

  it('shows the no-more-classes message and never renders schedule edit or delete buttons', () => {
    const props = buildProps({
      focus: {
        currentEntry: null,
        nextEntry: null,
        todayEntries: [],
      },
    });

    render(<TeacherTodayFocusPanel {...props} />);

    expect(screen.getByText('No more classes scheduled today.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Edit schedule' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Delete schedule' })).not.toBeInTheDocument();
  });
});
