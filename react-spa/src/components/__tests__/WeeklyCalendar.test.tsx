import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import WeeklyCalendar from '../WeeklyCalendar';
import type { ScheduleWithPermissions } from '../../types';

describe('WeeklyCalendar Component', () => {
  const groups = [
    { id: 'g1', displayName: 'Grupo 1' },
    { id: 'g2', displayName: 'Grupo 2' },
  ];

  it('renders day headers and time column', () => {
    render(
      <WeeklyCalendar
        schedules={[]}
        groups={groups}
        onAddClick={vi.fn()}
        onEditClick={vi.fn()}
        onDeleteClick={vi.fn()}
      />
    );

    expect(screen.getByText('Time')).toBeInTheDocument();
    expect(screen.getByText('Monday')).toBeInTheDocument();
    expect(screen.getByText('Friday')).toBeInTheDocument();
  });

  it('calls onAddClick when clicking an hour cell', () => {
    const onAddClick = vi.fn();
    render(
      <WeeklyCalendar
        schedules={[]}
        groups={groups}
        onAddClick={onAddClick}
        onEditClick={vi.fn()}
        onDeleteClick={vi.fn()}
      />
    );

    // Click a known hour cell via aria-label
    const cell = screen.getByRole('button', { name: 'Add Monday 07:00' });
    fireEvent.click(cell);

    expect(onAddClick).toHaveBeenCalled();
    const [dayOfWeek, startTime] = onAddClick.mock.calls[0] as unknown as [number, string];
    expect(dayOfWeek).toBe(1);
    expect(startTime).toBe('07:00');
  });

  it('renders a schedule block and calls onEditClick when editable', () => {
    const onEditClick = vi.fn();
    const schedule: ScheduleWithPermissions = {
      id: 's1',
      classroomId: 'c1',
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:00',
      groupId: 'g1',
      teacherId: 't1',
      recurrence: 'weekly',
      createdAt: new Date().toISOString(),
      updatedAt: undefined,
      isMine: true,
      canEdit: true,
    };

    render(
      <WeeklyCalendar
        schedules={[schedule]}
        groups={groups}
        onAddClick={vi.fn()}
        onEditClick={onEditClick}
        onDeleteClick={vi.fn()}
      />
    );

    const block = screen.getByTestId('schedule-block-s1');
    fireEvent.click(block);
    expect(onEditClick).toHaveBeenCalledWith(schedule);
  });

  it('renders a reserved block when schedule is not editable and group is unknown', () => {
    const onEditClick = vi.fn();
    const schedule: ScheduleWithPermissions = {
      id: 's2',
      classroomId: 'c1',
      dayOfWeek: 2,
      startTime: '08:00',
      endTime: '09:00',
      groupId: 'g-unknown',
      teacherId: 't-other',
      recurrence: 'weekly',
      createdAt: new Date().toISOString(),
      updatedAt: undefined,
      isMine: false,
      canEdit: false,
    };

    render(
      <WeeklyCalendar
        schedules={[schedule]}
        groups={groups}
        onAddClick={vi.fn()}
        onEditClick={onEditClick}
        onDeleteClick={vi.fn()}
      />
    );

    const block = screen.getByTestId('schedule-block-s2');
    expect(block).toHaveTextContent('Reserved by another teacher');

    fireEvent.click(block);
    expect(onEditClick).not.toHaveBeenCalled();

    expect(block.querySelectorAll('button')).toHaveLength(0);
  });

  it('renders readable schedule details from API metadata for non-editable blocks', () => {
    const schedule: ScheduleWithPermissions = {
      id: 's3',
      classroomId: 'c1',
      dayOfWeek: 3,
      startTime: '10:00',
      endTime: '11:00',
      groupId: 'g-hidden',
      groupDisplayName: 'Plan Teacher B',
      teacherId: 't-hidden',
      teacherName: 'Teacher B',
      recurrence: 'weekly',
      createdAt: new Date().toISOString(),
      updatedAt: undefined,
      isMine: false,
      canEdit: false,
    };

    render(
      <WeeklyCalendar
        schedules={[schedule]}
        groups={groups}
        onAddClick={vi.fn()}
        onEditClick={vi.fn()}
        onDeleteClick={vi.fn()}
      />
    );

    const block = screen.getByTestId('schedule-block-s3');
    expect(block).toHaveTextContent('Plan Teacher B');
    expect(block).toHaveAttribute('title', expect.stringContaining('Teacher B'));
  });
});
