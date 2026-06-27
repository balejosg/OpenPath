import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import ScheduleFormModal from '../ScheduleFormModal';
import type { ScheduleWithPermissions } from '../../types';

describe('ScheduleFormModal Component', () => {
  const groups = [
    { id: 'g1', name: 'grupo-1', displayName: 'Grupo 1' },
    { id: 'g2', name: 'grupo-2', displayName: 'Grupo 2' },
  ];

  it('renders create mode by default and calls onClose', () => {
    const onClose = vi.fn();
    render(
      <ScheduleFormModal
        schedule={null}
        groups={groups}
        saving={false}
        error=""
        onSave={vi.fn()}
        onClose={onClose}
      />
    );

    expect(screen.getByText('New Schedule')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /close/i }));
    expect(onClose).toHaveBeenCalled();
  });

  it('prefills day and start time when provided, and calls onSave with data', () => {
    const onSave = vi.fn();
    render(
      <ScheduleFormModal
        schedule={null}
        defaultDay={3}
        defaultStartTime="10:00"
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    // Day buttons show first 3 letters
    const dayBtn = screen.getByRole('button', { name: 'Wed' });
    expect(dayBtn).toBeInTheDocument();

    // Change end time to ensure > start
    fireEvent.change(screen.getByLabelText('End Time'), { target: { value: '11:00' } });
    fireEvent.click(screen.getByRole('button', { name: /create schedule/i }));

    expect(onSave).toHaveBeenCalled();
    const saved = onSave.mock.calls[0]?.[0] as {
      dayOfWeek: number;
      startTime: string;
      endTime: string;
      groupId: string;
    };
    expect(saved.dayOfWeek).toBe(3);
    expect(saved.startTime).toBe('10:00');
    expect(saved.endTime).toBe('11:00');
    expect(saved.groupId).toBe('g1');
  });

  it('requires selecting a day when creating without a default day', () => {
    const onSave = vi.fn();
    render(
      <ScheduleFormModal
        schedule={null}
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: /create schedule/i }));
    expect(onSave).not.toHaveBeenCalled();
    expect(screen.getByText('Select a day')).toBeInTheDocument();
  });

  it('accepts numeric dayOfWeek even if returned as a string', () => {
    const onSave = vi.fn();
    const schedule = {
      id: 's1',
      classroomId: 'c1',
      dayOfWeek: '2',
      startTime: '08:00',
      endTime: '09:00',
      groupId: 'g2',
      teacherId: 't1',
      recurrence: 'weekly',
      createdAt: new Date().toISOString(),
      updatedAt: undefined,
      isMine: true,
      canEdit: true,
    } as unknown as ScheduleWithPermissions;

    render(
      <ScheduleFormModal
        schedule={schedule}
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));
    expect(onSave).toHaveBeenCalled();
    const saved = onSave.mock.calls[0]?.[0] as { dayOfWeek: number };
    expect(saved.dayOfWeek).toBe(2);
  });

  it('renders edit mode when schedule is provided', () => {
    const schedule: ScheduleWithPermissions = {
      id: 's1',
      classroomId: 'c1',
      dayOfWeek: 2,
      startTime: '08:00',
      endTime: '09:00',
      groupId: 'g2',
      teacherId: 't1',
      recurrence: 'weekly',
      createdAt: new Date().toISOString(),
      updatedAt: undefined,
      isMine: true,
      canEdit: true,
    };

    render(
      <ScheduleFormModal
        schedule={schedule}
        groups={groups}
        saving={false}
        error=""
        onSave={vi.fn()}
        onClose={vi.fn()}
      />
    );

    expect(screen.getByText('Edit Schedule')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Tue' })).toHaveClass('bg-blue-600');
    expect(screen.getByRole('button', { name: /save changes/i })).toBeInTheDocument();
  });

  it('clicking a day button updates the selected day', () => {
    const onSave = vi.fn();
    render(
      <ScheduleFormModal
        schedule={null}
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    // Click Monday to select a day
    fireEvent.click(screen.getByRole('button', { name: 'Mon' }));
    // Now change end time and submit to confirm day was set
    fireEvent.change(screen.getByLabelText('End Time'), { target: { value: '10:00' } });
    fireEvent.click(screen.getByRole('button', { name: /create schedule/i }));

    expect(onSave).toHaveBeenCalled();
    const saved = onSave.mock.calls[0]?.[0] as { dayOfWeek: number };
    expect(saved.dayOfWeek).toBe(1);
  });

  it('changing start time select updates state', () => {
    const onSave = vi.fn();
    render(
      <ScheduleFormModal
        schedule={null}
        defaultDay={2}
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    fireEvent.change(screen.getByLabelText('Start Time'), { target: { value: '09:00' } });
    fireEvent.change(screen.getByLabelText('End Time'), { target: { value: '10:00' } });
    fireEvent.click(screen.getByRole('button', { name: /create schedule/i }));

    expect(onSave).toHaveBeenCalled();
    const saved = onSave.mock.calls[0]?.[0] as { startTime: string };
    expect(saved.startTime).toBe('09:00');
  });

  it('shows error when start time is not before end time', () => {
    const onSave = vi.fn();
    render(
      <ScheduleFormModal
        schedule={null}
        defaultDay={2}
        defaultStartTime="10:00"
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    // Set end time equal to start time — compareTimeOfDay returns 0, which is >= 0
    fireEvent.change(screen.getByLabelText('End Time'), { target: { value: '10:00' } });
    fireEvent.click(screen.getByRole('button', { name: /create schedule/i }));

    expect(onSave).not.toHaveBeenCalled();
    expect(screen.getByText('End time must be after start time')).toBeInTheDocument();
  });

  it('shows spinner and disables buttons when saving is true', () => {
    const onClose = vi.fn();
    const schedule: ScheduleWithPermissions = {
      id: 's2',
      classroomId: 'c1',
      dayOfWeek: 3,
      startTime: '09:00',
      endTime: '10:00',
      groupId: 'g1',
      teacherId: 't1',
      recurrence: 'weekly',
      createdAt: new Date().toISOString(),
      updatedAt: undefined,
      isMine: true,
      canEdit: true,
    };

    render(
      <ScheduleFormModal
        schedule={schedule}
        groups={groups}
        saving
        error=""
        onSave={vi.fn()}
        onClose={onClose}
      />
    );

    const cancelBtn = screen.getByRole('button', { name: /cancel/i });
    const saveBtn = screen.getByRole('button', { name: /save changes/i });
    expect(cancelBtn).toBeDisabled();
    expect(saveBtn).toBeDisabled();

    fireEvent.click(cancelBtn);
    expect(onClose).not.toHaveBeenCalled();
  });

  it('shows error when group is missing', () => {
    const onSave = vi.fn();
    render(
      <ScheduleFormModal
        schedule={null}
        defaultDay={1}
        groups={[]}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: /create schedule/i }));
    expect(onSave).not.toHaveBeenCalled();
    expect(screen.getByText('Select a group')).toBeInTheDocument();
  });
});
