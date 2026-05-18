import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { CreateGroupModal } from '../CreateGroupModal';

describe('CreateGroupModal', () => {
  it('forwards field changes and create action', () => {
    const onNameChange = vi.fn();
    const onDescriptionChange = vi.fn();
    const onCreate = vi.fn();

    render(
      <CreateGroupModal
        isOpen
        saving={false}
        name=""
        description=""
        error="El nombre es obligatorio"
        onClose={vi.fn()}
        onNameChange={onNameChange}
        onDescriptionChange={onDescriptionChange}
        onCreate={onCreate}
      />
    );

    fireEvent.change(screen.getByPlaceholderText('E.g. elementary-group'), {
      target: { value: 'grupo-aula' },
    });
    fireEvent.change(screen.getByPlaceholderText('Group description...'), {
      target: { value: 'Grupo Aula' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Create Group' }));

    expect(onNameChange).toHaveBeenCalledWith('grupo-aula');
    expect(onDescriptionChange).toHaveBeenCalledWith('Grupo Aula');
    expect(onCreate).toHaveBeenCalled();
    expect(screen.getByText('El nombre es obligatorio')).toBeInTheDocument();
  });
});
