import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { CloneGroupModal } from '../CloneGroupModal';

describe('CloneGroupModal', () => {
  it('renders the selected source and forwards edits and clone action', () => {
    const onNameChange = vi.fn();
    const onDisplayNameChange = vi.fn();
    const onClone = vi.fn();

    render(
      <CloneGroupModal
        isOpen
        cloneSource={{
          id: 'library-1',
          name: 'biblioteca',
          displayName: 'Biblioteca',
          createdAt: '2026-04-01T10:00:00.000Z',
          updatedAt: null,
          ownerUserId: null,
          whitelistCount: 1,
          blockedSubdomainCount: 0,
          blockedPathCount: 0,
          enabled: true,
          visibility: 'instance_public',
        }}
        saving={false}
        name="biblioteca-copia"
        displayName="Biblioteca Copia"
        error=""
        onClose={vi.fn()}
        onNameChange={onNameChange}
        onDisplayNameChange={onDisplayNameChange}
        onClone={onClone}
      />
    );

    fireEvent.change(screen.getByPlaceholderText('E.g. primary-policy'), {
      target: { value: 'biblioteca-aula' },
    });
    fireEvent.change(screen.getByPlaceholderText('Policy description...'), {
      target: { value: 'Biblioteca Aula' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Clone' }));

    expect(onNameChange).toHaveBeenCalledWith('biblioteca-aula');
    expect(onDisplayNameChange).toHaveBeenCalledWith('Biblioteca Aula');
    expect(onClone).toHaveBeenCalled();
  });
});
