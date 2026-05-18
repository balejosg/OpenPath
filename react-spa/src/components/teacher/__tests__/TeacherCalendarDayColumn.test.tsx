import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../../types';
import type { TeacherScheduleEntry } from '../teacher-schedule-model';
import { TeacherCalendarDayColumn } from '../TeacherCalendarDayColumn';

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

describe('TeacherCalendarDayColumn', () => {
  it('renders selectable weekly and one-off blocks with accessible detail labels', () => {
    const onSelectEntry = vi.fn();
    const weeklyEntry = makeEntry();
    const oneOffEntry = makeEntry({
      id: 'entry-one-off',
      kind: 'one_off',
      schedule: makeOneOffSchedule(),
      startTime: '10:15',
      endTime: '11:00',
      startMinutes: 10 * 60 + 15,
      endMinutes: 11 * 60,
      label: 'Group Two - Lab B',
      classroomId: 'classroom-2',
      classroomName: 'Lab B',
      colorKey: 'classroom-2',
    });

    render(
      <TeacherCalendarDayColumn
        entries={[weeklyEntry, oneOffEntry]}
        rowHeight={56}
        colorMap={
          new Map([
            ['classroom-1', 0],
            ['classroom-2', 1],
          ])
        }
        onSelectEntry={onSelectEntry}
      />
    );

    expect(screen.getByText('Group One - Lab A')).toBeInTheDocument();
    const oneOffButton = screen.getByRole('button', {
      name: 'View details Group Two - Lab B 10:15-11:00',
    });
    expect(oneOffButton).toHaveAttribute('data-kind', 'one_off');

    fireEvent.click(oneOffButton);

    expect(onSelectEntry).toHaveBeenCalledWith(oneOffEntry);
  });

  it('clips off-screen entries and lays overlapping lanes side by side', () => {
    const firstEntry = makeEntry({
      id: 'entry-first',
      startMinutes: 6 * 60 + 30,
      endMinutes: 7 * 60 + 30,
      startTime: '06:30',
      endTime: '07:30',
      laneIndex: 0,
      laneCount: 2,
    });
    const secondEntry = makeEntry({
      id: 'entry-second',
      label: 'Group Two - Lab B',
      startMinutes: 8 * 60,
      endMinutes: 9 * 60,
      startTime: '08:00',
      endTime: '09:00',
      laneIndex: 1,
      laneCount: 2,
    });

    render(
      <TeacherCalendarDayColumn
        entries={[firstEntry, secondEntry]}
        rowHeight={60}
        colorMap={new Map([['classroom-1', 0]])}
        onSelectEntry={vi.fn()}
      />
    );

    const firstButton = screen.getByRole('button', {
      name: 'View details Group One - Lab A 06:30-07:30',
    });
    const secondButton = screen.getByRole('button', {
      name: 'View details Group Two - Lab B 08:00-09:00',
    });

    expect(firstButton).toHaveStyle({ top: '0px', height: '30px' });
    expect(firstButton).toHaveStyle({ left: 'calc(0% + 0.125rem)' });
    expect(secondButton).toHaveStyle({ left: 'calc(50% + 0.125rem)' });
    expect(secondButton).toHaveStyle({ width: 'calc(50% - 0.25rem)' });
  });
});
