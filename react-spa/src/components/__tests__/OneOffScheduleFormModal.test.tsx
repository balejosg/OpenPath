import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';

import OneOffScheduleFormModal from '../OneOffScheduleFormModal';
import type { OneOffScheduleWithPermissions } from '../../types';

describe('OneOffScheduleFormModal', () => {
  const groups = [
    { id: 'g1', name: 'grupo-1', displayName: 'Grupo 1' },
    { id: 'g2', name: 'grupo-2', displayName: 'Grupo 2' },
  ];

  it('renders create mode and calls onClose', () => {
    const onClose = vi.fn();

    render(
      <OneOffScheduleFormModal
        schedule={null}
        groups={groups}
        saving={false}
        error=""
        onSave={vi.fn()}
        onClose={onClose}
      />
    );

    expect(screen.getByText('New One-Off Assignment')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /close/i }));
    expect(onClose).toHaveBeenCalled();
  });

  it('calls onSave with ISO dates and groupId', () => {
    const onSave = vi.fn();

    render(
      <OneOffScheduleFormModal
        schedule={null}
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    fireEvent.change(screen.getByLabelText('Start'), { target: { value: '2026-02-23T10:00' } });
    fireEvent.change(screen.getByLabelText('End'), { target: { value: '2026-02-23T11:00' } });

    fireEvent.click(screen.getByRole('button', { name: /create assignment/i }));

    expect(onSave).toHaveBeenCalled();
    const saved = onSave.mock.calls[0]?.[0] as { startAt: string; endAt: string; groupId: string };

    expect(saved.groupId).toBe('g1');
    expect(saved.startAt).toBe(new Date(2026, 1, 23, 10, 0, 0, 0).toISOString());
    expect(saved.endAt).toBe(new Date(2026, 1, 23, 11, 0, 0, 0).toISOString());
  });

  it('renders edit mode with a valid schedule and shows save changes button', () => {
    const schedule: OneOffScheduleWithPermissions = {
      id: 'os1',
      classroomId: 'c1',
      groupId: 'g2',
      startAt: new Date(2026, 3, 10, 9, 0, 0, 0).toISOString(),
      endAt: new Date(2026, 3, 10, 10, 0, 0, 0).toISOString(),
      teacherId: 't1',
      createdAt: new Date().toISOString(),
      updatedAt: undefined,
      isMine: true,
      canEdit: true,
    };
    render(
      <OneOffScheduleFormModal
        schedule={schedule}
        groups={groups}
        saving={false}
        error=""
        onSave={vi.fn()}
        onClose={vi.fn()}
      />
    );

    expect(screen.getByText('Edit One-Off Assignment')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /save changes/i })).toBeInTheDocument();
  });

  it('renders edit mode with invalid startAt/endAt and falls back to defaults', () => {
    const schedule: OneOffScheduleWithPermissions = {
      id: 'os2',
      classroomId: 'c1',
      groupId: 'g1',
      startAt: 'not-a-date',
      endAt: 'also-not-a-date',
      teacherId: 't1',
      createdAt: new Date().toISOString(),
      updatedAt: undefined,
      isMine: true,
      canEdit: true,
    };
    render(
      <OneOffScheduleFormModal
        schedule={schedule}
        groups={groups}
        saving={false}
        error=""
        onSave={vi.fn()}
        onClose={vi.fn()}
      />
    );

    expect(screen.getByText('Edit One-Off Assignment')).toBeInTheDocument();
    // Input values are still rendered (fallback defaults were used)
    expect(screen.getByLabelText('Start')).toBeInTheDocument();
  });

  it('shows error when submitting without a groupId', () => {
    const onSave = vi.fn();
    render(
      <OneOffScheduleFormModal
        schedule={null}
        groups={[]}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    fireEvent.change(screen.getByLabelText('Start'), { target: { value: '2026-02-23T10:00' } });
    fireEvent.change(screen.getByLabelText('End'), { target: { value: '2026-02-23T11:00' } });
    fireEvent.click(screen.getByRole('button', { name: /create assignment/i }));

    expect(onSave).not.toHaveBeenCalled();
    expect(screen.getByText('Select a group')).toBeInTheDocument();
  });

  it('shows error when end time is not after start time', () => {
    const onSave = vi.fn();
    render(
      <OneOffScheduleFormModal
        schedule={null}
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    fireEvent.change(screen.getByLabelText('Start'), { target: { value: '2026-02-23T11:00' } });
    fireEvent.change(screen.getByLabelText('End'), { target: { value: '2026-02-23T10:00' } });
    fireEvent.click(screen.getByRole('button', { name: /create assignment/i }));

    expect(onSave).not.toHaveBeenCalled();
    expect(screen.getByText('End date/time must be after start date/time')).toBeInTheDocument();
  });

  it('shows error when start date is invalid', () => {
    const onSave = vi.fn();
    render(
      <OneOffScheduleFormModal
        schedule={null}
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    // Year < 1970 makes parseDateTimeLocalValue return null
    fireEvent.change(screen.getByLabelText('Start'), { target: { value: '1960-01-01T10:00' } });
    fireEvent.change(screen.getByLabelText('End'), { target: { value: '2026-02-23T11:00' } });
    fireEvent.click(screen.getByRole('button', { name: /create assignment/i }));

    expect(onSave).not.toHaveBeenCalled();
    expect(screen.getByText('Select a start date/time')).toBeInTheDocument();
  });

  it('shows error when end date is invalid', () => {
    const onSave = vi.fn();
    render(
      <OneOffScheduleFormModal
        schedule={null}
        groups={groups}
        saving={false}
        error=""
        onSave={onSave}
        onClose={vi.fn()}
      />
    );

    fireEvent.change(screen.getByLabelText('Start'), { target: { value: '2026-02-23T10:00' } });
    // Year < 1970 makes parseDateTimeLocalValue return null
    fireEvent.change(screen.getByLabelText('End'), { target: { value: '1960-01-01T10:00' } });
    fireEvent.click(screen.getByRole('button', { name: /create assignment/i }));

    expect(onSave).not.toHaveBeenCalled();
    expect(screen.getByText('Select an end date/time')).toBeInTheDocument();
  });

  it('disables close button when saving is true', () => {
    const onClose = vi.fn();
    render(
      <OneOffScheduleFormModal
        schedule={null}
        groups={groups}
        saving
        error=""
        onSave={vi.fn()}
        onClose={onClose}
      />
    );

    const cancelBtn = screen.getByRole('button', { name: /cancel/i });
    expect(cancelBtn).toBeDisabled();
    fireEvent.click(cancelBtn);
    expect(onClose).not.toHaveBeenCalled();
  });
});
