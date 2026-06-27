import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { UsersEditModal } from '../UsersEditModal';
import { UserRole } from '../../../types';
import type { User } from '../../../types';

const baseUser: User = {
  id: 'user-1',
  name: 'Alice Smith',
  email: 'alice@example.com',
  roles: [UserRole.TEACHER],
  status: 'Active',
};

function renderModal(overrides: Partial<Parameters<typeof UsersEditModal>[0]> = {}) {
  const defaults = {
    showEditModal: true,
    closeEditModal: vi.fn(),
    editEmail: 'alice@example.com',
    editName: 'Alice Smith',
    saving: false,
    saveEdit: vi.fn(() => Promise.resolve()),
    selectedUser: baseUser,
    setEditEmail: vi.fn(),
    setEditName: vi.fn(),
  };
  return render(<UsersEditModal {...defaults} {...overrides} />);
}

describe('UsersEditModal', () => {
  it('renders nothing when showEditModal is false', () => {
    const { container } = renderModal({ showEditModal: false });
    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when selectedUser is null', () => {
    const { container } = renderModal({ selectedUser: null });
    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when both showEditModal is false and selectedUser is null', () => {
    const { container } = renderModal({ showEditModal: false, selectedUser: null });
    expect(container).toBeEmptyDOMElement();
  });

  it('renders the modal with user fields when open and selectedUser is set', () => {
    renderModal();
    expect(screen.getByText('Edit User')).toBeInTheDocument();
    expect(screen.getByDisplayValue('Alice Smith')).toBeInTheDocument();
    expect(screen.getByDisplayValue('alice@example.com')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save Changes' })).toBeInTheDocument();
  });

  it('calls setEditName when name input changes', () => {
    const setEditName = vi.fn();
    renderModal({ setEditName });
    fireEvent.change(screen.getByDisplayValue('Alice Smith'), {
      target: { value: 'Alice Johnson' },
    });
    expect(setEditName).toHaveBeenCalledWith('Alice Johnson');
  });

  it('calls setEditEmail when email input changes', () => {
    const setEditEmail = vi.fn();
    renderModal({ setEditEmail });
    fireEvent.change(screen.getByDisplayValue('alice@example.com'), {
      target: { value: 'alice.j@example.com' },
    });
    expect(setEditEmail).toHaveBeenCalledWith('alice.j@example.com');
  });

  it('displays user roles as badges', () => {
    renderModal({
      selectedUser: { ...baseUser, roles: [UserRole.TEACHER, UserRole.ADMIN] },
    });
    expect(screen.getByText('Teacher')).toBeInTheDocument();
    expect(screen.getByText('Admin')).toBeInTheDocument();
  });

  it('displays "No roles assigned" when user has no roles', () => {
    renderModal({ selectedUser: { ...baseUser, roles: [] } });
    expect(screen.getByText('No roles assigned')).toBeInTheDocument();
  });

  it('displays role management hint', () => {
    renderModal();
    expect(
      screen.getByText('Role management is handled in the permissions flow.')
    ).toBeInTheDocument();
  });

  it('calls saveEdit when Save Changes button is clicked', () => {
    const saveEdit = vi.fn(() => Promise.resolve());
    renderModal({ saveEdit });
    fireEvent.click(screen.getByRole('button', { name: 'Save Changes' }));
    expect(saveEdit).toHaveBeenCalled();
  });

  it('calls closeEditModal when Cancel button is clicked', () => {
    const closeEditModal = vi.fn();
    renderModal({ closeEditModal });
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(closeEditModal).toHaveBeenCalled();
  });

  it('disables buttons while saving', () => {
    renderModal({ saving: true });
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Save Changes' })).toBeDisabled();
  });

  it('shows spinner while saving', () => {
    renderModal({ saving: true });
    const saveBtn = screen.getByRole('button', { name: 'Save Changes' });
    expect(saveBtn.querySelector('svg')).toBeInTheDocument();
  });

  it('does not show spinner when not saving', () => {
    renderModal({ saving: false });
    const saveBtn = screen.getByRole('button', { name: 'Save Changes' });
    expect(saveBtn.querySelector('svg')).toBeNull();
  });

  it('reflects updated editName and editEmail values', () => {
    renderModal({ editName: 'Bob', editEmail: 'bob@example.com' });
    expect(screen.getByDisplayValue('Bob')).toBeInTheDocument();
    expect(screen.getByDisplayValue('bob@example.com')).toBeInTheDocument();
  });
});
