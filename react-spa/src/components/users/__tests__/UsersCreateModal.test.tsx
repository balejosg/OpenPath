import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { UsersCreateModal } from '../UsersCreateModal';
import type { CreateUserRole } from '../../../lib/roles';

function renderModal(overrides: Partial<Parameters<typeof UsersCreateModal>[0]> = {}) {
  const defaults = {
    showNewModal: true,
    closeNewModal: vi.fn(),
    createError: '',
    createUser: vi.fn(() => Promise.resolve()),
    newEmail: '',
    newName: '',
    newPassword: '',
    newRole: 'teacher' as CreateUserRole,
    resetNewUserForm: vi.fn(),
    saving: false,
    setCreateError: vi.fn(),
    setNewEmail: vi.fn(),
    setNewName: vi.fn(),
    setNewPassword: vi.fn(),
    setNewRole: vi.fn(),
  };
  return render(<UsersCreateModal {...defaults} {...overrides} />);
}

describe('UsersCreateModal', () => {
  it('renders nothing when showNewModal is false', () => {
    const { container } = renderModal({ showNewModal: false });
    expect(container).toBeEmptyDOMElement();
  });

  it('renders the modal with all fields when showNewModal is true', () => {
    renderModal();
    expect(screen.getByText('New User')).toBeInTheDocument();
    expect(screen.getByPlaceholderText('Full name')).toBeInTheDocument();
    expect(screen.getByPlaceholderText('user@example.com')).toBeInTheDocument();
    expect(screen.getByPlaceholderText('Minimum 8 characters')).toBeInTheDocument();
    expect(screen.getByRole('combobox')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Create User' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
  });

  it('calls setNewName when name input changes', () => {
    const setNewName = vi.fn();
    renderModal({ setNewName });
    fireEvent.change(screen.getByPlaceholderText('Full name'), { target: { value: 'Alice' } });
    expect(setNewName).toHaveBeenCalledWith('Alice');
  });

  it('calls setCreateError with empty string when name changes and createError is set', () => {
    const setCreateError = vi.fn();
    renderModal({ createError: 'Name is required', setCreateError });
    fireEvent.change(screen.getByPlaceholderText('Full name'), {
      target: { value: 'Bob' },
    });
    expect(setCreateError).toHaveBeenCalledWith('');
  });

  it('does NOT call setCreateError when name changes and createError is empty', () => {
    const setCreateError = vi.fn();
    renderModal({ createError: '', setCreateError });
    fireEvent.change(screen.getByPlaceholderText('Full name'), {
      target: { value: 'Bob' },
    });
    expect(setCreateError).not.toHaveBeenCalled();
  });

  it('calls setNewEmail when email input changes', () => {
    const setNewEmail = vi.fn();
    renderModal({ setNewEmail });
    fireEvent.change(screen.getByPlaceholderText('user@example.com'), {
      target: { value: 'alice@example.com' },
    });
    expect(setNewEmail).toHaveBeenCalledWith('alice@example.com');
  });

  it('calls setCreateError with empty string when email changes and createError is set', () => {
    const setCreateError = vi.fn();
    renderModal({ createError: 'Email is required', setCreateError });
    fireEvent.change(screen.getByPlaceholderText('user@example.com'), {
      target: { value: 'alice@example.com' },
    });
    expect(setCreateError).toHaveBeenCalledWith('');
  });

  it('calls setNewPassword when password input changes', () => {
    const setNewPassword = vi.fn();
    renderModal({ setNewPassword });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'secure123' },
    });
    expect(setNewPassword).toHaveBeenCalledWith('secure123');
  });

  it('calls setCreateError with empty string when password changes and createError is set', () => {
    const setCreateError = vi.fn();
    renderModal({ createError: 'Password too short', setCreateError });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'secure123' },
    });
    expect(setCreateError).toHaveBeenCalledWith('');
  });

  it('calls setNewRole when role select changes', () => {
    const setNewRole = vi.fn();
    renderModal({ setNewRole });
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'admin' } });
    expect(setNewRole).toHaveBeenCalledWith('admin');
  });

  it('calls setCreateError with empty string when role changes and createError is set', () => {
    const setCreateError = vi.fn();
    renderModal({ createError: 'Some error', setCreateError });
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'admin' } });
    expect(setCreateError).toHaveBeenCalledWith('');
  });

  it('displays createError message when createError is non-empty', () => {
    renderModal({ createError: 'A user with that email already exists' });
    expect(screen.getByText('A user with that email already exists')).toBeInTheDocument();
  });

  it('does not display error paragraph when createError is empty', () => {
    renderModal({ createError: '' });
    expect(screen.queryByText('A user with that email already exists')).not.toBeInTheDocument();
  });

  it('calls createUser when Create User button is clicked', () => {
    const createUser = vi.fn(() => Promise.resolve());
    renderModal({ createUser });
    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));
    expect(createUser).toHaveBeenCalled();
  });

  it('calls closeNewModal and resetNewUserForm when Cancel is clicked', () => {
    const closeNewModal = vi.fn();
    const resetNewUserForm = vi.fn();
    renderModal({ closeNewModal, resetNewUserForm });
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(closeNewModal).toHaveBeenCalled();
    expect(resetNewUserForm).toHaveBeenCalled();
  });

  it('disables Cancel and Create buttons while saving', () => {
    renderModal({ saving: true });
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Create User' })).toBeDisabled();
  });

  it('shows spinner icon while saving', () => {
    renderModal({ saving: true });
    const createBtn = screen.getByRole('button', { name: 'Create User' });
    // Loader2 renders an svg inside the button when saving
    expect(createBtn.querySelector('svg')).toBeInTheDocument();
  });

  it('does not show spinner when not saving', () => {
    renderModal({ saving: false });
    const createBtn = screen.getByRole('button', { name: 'Create User' });
    expect(createBtn.querySelector('svg')).toBeNull();
  });

  it('reflects pre-filled field values', () => {
    renderModal({ newName: 'Alice', newEmail: 'alice@example.com', newPassword: 'secure123' });
    expect(screen.getByPlaceholderText('Full name')).toHaveValue('Alice');
    expect(screen.getByPlaceholderText('user@example.com')).toHaveValue('alice@example.com');
    expect(screen.getByPlaceholderText('Minimum 8 characters')).toHaveValue('secure123');
  });
});
