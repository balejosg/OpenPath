import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';

import OneOffScheduleFormModal from '../OneOffScheduleFormModal';

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
});
