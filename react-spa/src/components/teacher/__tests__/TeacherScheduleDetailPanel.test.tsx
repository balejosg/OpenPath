import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../../types';
import type { TeacherScheduleEntry } from '../teacher-schedule-model';
import { TeacherScheduleDetailPanel } from '../TeacherScheduleDetailPanel';

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
  overrides: Partial<React.ComponentProps<typeof TeacherScheduleDetailPanel>> = {}
) {
  return {
    entry: makeEntry(),
    isSaving: false,
    error: '',
    onClose: vi.fn(),
    onOpenClassroom: vi.fn(),
    onOpenRules: vi.fn(),
    onTakeControl: vi.fn(),
    onReleaseClassroom: vi.fn(),
    onEditSchedule: vi.fn(),
    onDeleteSchedule: vi.fn(),
    ...overrides,
  };
}

describe('TeacherScheduleDetailPanel', () => {
  it('renders weekly details and calls all primary and secondary callbacks with the selected entry', () => {
    const props = buildProps();

    render(<TeacherScheduleDetailPanel {...props} />);

    expect(screen.getByText('Schedule details')).toBeInTheDocument();
    expect(screen.getByText('Group One - Lab A')).toBeInTheDocument();
    expect(screen.getByText('Group One')).toBeInTheDocument();
    expect(screen.getByText('Lab A')).toBeInTheDocument();
    expect(screen.getByText('Weekly')).toBeInTheDocument();
    expect(screen.getByText('09:00-10:00')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Go to classroom' }));
    fireEvent.click(screen.getByRole('button', { name: 'View rules' }));
    fireEvent.click(screen.getByRole('button', { name: 'Take control' }));
    fireEvent.click(screen.getByRole('button', { name: 'Release classroom' }));
    fireEvent.click(screen.getByRole('button', { name: 'Edit schedule' }));
    fireEvent.click(screen.getByRole('button', { name: 'Delete schedule' }));

    expect(props.onOpenClassroom).toHaveBeenCalledWith(props.entry);
    expect(props.onOpenRules).toHaveBeenCalledWith(props.entry);
    expect(props.onTakeControl).toHaveBeenCalledWith(props.entry);
    expect(props.onReleaseClassroom).toHaveBeenCalledWith(props.entry);
    expect(props.onEditSchedule).toHaveBeenCalledWith(props.entry);
    expect(props.onDeleteSchedule).toHaveBeenCalledWith(props.entry);
  });

  it('renders one-off entries as puntual and disables actions while saving', () => {
    const props = buildProps({
      entry: makeEntry({
        kind: 'one_off',
        schedule: makeOneOffSchedule(),
      }),
      isSaving: true,
    });

    render(<TeacherScheduleDetailPanel {...props} />);

    expect(screen.getByText('One-off')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Go to classroom' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Edit schedule' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Delete schedule' })).toBeDisabled();
  });

  it('renders nothing when there is no selected entry', () => {
    render(<TeacherScheduleDetailPanel {...buildProps({ entry: null })} />);

    expect(screen.queryByText('Schedule details')).not.toBeInTheDocument();
  });
});
