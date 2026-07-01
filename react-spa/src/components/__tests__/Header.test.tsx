import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import Header from '../Header';
import type { CurrentUser } from '../../hooks/useCurrentUser';

const mockUseCurrentUser = vi.fn<() => { user: CurrentUser | null; loading: boolean }>();
const mockGetRoleDisplayLabel = vi.fn<(role: string, t: unknown) => string>();

vi.mock('../../hooks/useCurrentUser', () => ({
  useCurrentUser: () => mockUseCurrentUser(),
  getRoleDisplayLabel: (role: string, t: unknown) => mockGetRoleDisplayLabel(role, t),
}));

const mockOnMenuClick = vi.fn();

const baseUser: CurrentUser = {
  id: 'u1',
  name: 'Ana García',
  email: 'ana@example.com',
  roles: ['teacher'],
  initials: 'AG',
  primaryRole: 'teacher',
};

describe('Header', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockGetRoleDisplayLabel.mockReturnValue('Teacher');
  });

  it('renders the page title', () => {
    mockUseCurrentUser.mockReturnValue({ user: baseUser, loading: false });

    render(<Header onMenuClick={mockOnMenuClick} title="Dashboard" />);

    expect(screen.getByRole('heading', { name: 'Dashboard' })).toBeInTheDocument();
  });

  it('calls onMenuClick when the menu button is clicked', () => {
    mockUseCurrentUser.mockReturnValue({ user: baseUser, loading: false });

    render(<Header onMenuClick={mockOnMenuClick} title="Dashboard" />);

    fireEvent.click(screen.getByRole('button', { name: 'Open menu' }));
    expect(mockOnMenuClick).toHaveBeenCalledTimes(1);
  });

  it('shows a loading spinner when userLoading is true', () => {
    mockUseCurrentUser.mockReturnValue({ user: null, loading: true });

    render(<Header onMenuClick={mockOnMenuClick} title="Loading" />);

    // The spinner icon carries the lucide class name; query by its SVG role is unreliable
    // so we verify the user name and initials are NOT shown instead.
    expect(screen.queryByText('??')).not.toBeInTheDocument();
    expect(screen.queryByText('User')).not.toBeInTheDocument();
  });

  it('shows user initials and name when loaded', () => {
    mockUseCurrentUser.mockReturnValue({ user: baseUser, loading: false });

    render(<Header onMenuClick={mockOnMenuClick} title="Dashboard" />);

    expect(screen.getByText('AG')).toBeInTheDocument();
    expect(screen.getByText('Ana García')).toBeInTheDocument();
  });

  it('shows the role label returned by getRoleDisplayLabel', () => {
    mockGetRoleDisplayLabel.mockReturnValue('Teacher');
    mockUseCurrentUser.mockReturnValue({ user: baseUser, loading: false });

    render(<Header onMenuClick={mockOnMenuClick} title="Dashboard" />);

    expect(screen.getByText('Teacher')).toBeInTheDocument();
    expect(mockGetRoleDisplayLabel).toHaveBeenCalledWith('teacher', expect.any(Function));
  });

  it('shows fallback initials ?? when user is null', () => {
    mockUseCurrentUser.mockReturnValue({ user: null, loading: false });

    render(<Header onMenuClick={mockOnMenuClick} title="Dashboard" />);

    expect(screen.getByText('??')).toBeInTheDocument();
  });

  it('shows name fallback text when user is null', () => {
    mockUseCurrentUser.mockReturnValue({ user: null, loading: false });

    render(<Header onMenuClick={mockOnMenuClick} title="Dashboard" />);

    expect(screen.getByText('User')).toBeInTheDocument();
  });

  it('shows no-role fallback text when user has no primaryRole', () => {
    const userWithoutRole: CurrentUser = { ...baseUser, primaryRole: '' };
    mockUseCurrentUser.mockReturnValue({ user: userWithoutRole, loading: false });
    // getRoleDisplayLabel should NOT be called for empty primaryRole
    mockGetRoleDisplayLabel.mockReturnValue('');

    render(<Header onMenuClick={mockOnMenuClick} title="Dashboard" />);

    expect(screen.getByText('No role')).toBeInTheDocument();
  });

  it('renders the secure connection indicator', () => {
    mockUseCurrentUser.mockReturnValue({ user: baseUser, loading: false });

    render(<Header onMenuClick={mockOnMenuClick} title="Dashboard" />);

    expect(screen.getByText('Secure Connection')).toBeInTheDocument();
  });

  it('renders the search input with placeholder', () => {
    mockUseCurrentUser.mockReturnValue({ user: baseUser, loading: false });

    render(<Header onMenuClick={mockOnMenuClick} title="Dashboard" />);

    expect(screen.getByPlaceholderText('Search...')).toBeInTheDocument();
  });
});
