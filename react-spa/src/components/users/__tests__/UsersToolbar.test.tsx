import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { UsersToolbar } from '../UsersToolbar';

function renderToolbar(overrides: Partial<Parameters<typeof UsersToolbar>[0]> = {}) {
  const defaults = {
    exportMessage: null,
    onExportUsers: vi.fn(),
    onOpenNewUser: vi.fn(),
    searchQuery: '',
    setSearchQuery: vi.fn(),
  };
  return render(<UsersToolbar {...defaults} {...overrides} />);
}

describe('UsersToolbar', () => {
  it('renders the title and subtitle', () => {
    renderToolbar();
    expect(screen.getByText('User Management')).toBeInTheDocument();
    expect(screen.getByText('Manage platform access and roles.')).toBeInTheDocument();
  });

  it('renders the New User button', () => {
    renderToolbar();
    expect(screen.getByRole('button', { name: '+ New User' })).toBeInTheDocument();
  });

  it('calls onOpenNewUser when New User button is clicked', () => {
    const onOpenNewUser = vi.fn();
    renderToolbar({ onOpenNewUser });
    fireEvent.click(screen.getByRole('button', { name: '+ New User' }));
    expect(onOpenNewUser).toHaveBeenCalled();
  });

  it('renders the search input with placeholder', () => {
    renderToolbar();
    expect(screen.getByPlaceholderText('Search by name or email...')).toBeInTheDocument();
  });

  it('reflects searchQuery value in the search input', () => {
    renderToolbar({ searchQuery: 'alice' });
    expect(screen.getByPlaceholderText('Search by name or email...')).toHaveValue('alice');
  });

  it('calls setSearchQuery when search input changes', () => {
    const setSearchQuery = vi.fn();
    renderToolbar({ setSearchQuery });
    fireEvent.change(screen.getByPlaceholderText('Search by name or email...'), {
      target: { value: 'bob' },
    });
    expect(setSearchQuery).toHaveBeenCalledWith('bob');
  });

  it('renders a disabled Filters button', () => {
    renderToolbar();
    const filtersBtn = screen.getByRole('button', { name: /filters/i });
    expect(filtersBtn).toBeDisabled();
  });

  it('renders the Export button', () => {
    renderToolbar();
    expect(screen.getByRole('button', { name: 'Export' })).toBeInTheDocument();
  });

  it('calls onExportUsers when Export button is clicked', () => {
    const onExportUsers = vi.fn();
    renderToolbar({ onExportUsers });
    fireEvent.click(screen.getByRole('button', { name: 'Export' }));
    expect(onExportUsers).toHaveBeenCalled();
  });

  it('does not render export message when exportMessage is null', () => {
    renderToolbar({ exportMessage: null });
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('renders the export message when exportMessage is set', () => {
    renderToolbar({ exportMessage: 'Export complete.' });
    expect(screen.getByRole('status')).toBeInTheDocument();
    expect(screen.getByText('Export complete.')).toBeInTheDocument();
  });

  it('renders empty export message string', () => {
    // An empty string is falsy — the element should not appear
    renderToolbar({ exportMessage: '' });
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });
});
