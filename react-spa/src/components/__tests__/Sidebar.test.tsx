import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import Sidebar from '../Sidebar';
import { logout } from '../../lib/auth';

const mockIsAdmin = vi.fn<() => boolean>();

vi.mock('../../lib/auth', () => ({
  logout: vi.fn(),
  isAdmin: () => mockIsAdmin(),
}));

describe('Sidebar', () => {
  const setActiveTab = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    mockIsAdmin.mockReturnValue(true);
  });

  it('marks selected navigation item as current page', () => {
    render(<Sidebar activeTab="dashboard" setActiveTab={setActiveTab} isOpen />);

    expect(screen.getByRole('button', { name: 'Dashboard' })).toHaveAttribute(
      'aria-current',
      'page'
    );
  });

  it('maps rules view to group navigation active state', () => {
    render(<Sidebar activeTab="rules" setActiveTab={setActiveTab} isOpen />);

    expect(screen.getByRole('button', { name: 'Group Policies' })).toHaveAttribute(
      'aria-current',
      'page'
    );
  });

  it('marks settings button as current page when active', () => {
    render(<Sidebar activeTab="settings" setActiveTab={setActiveTab} isOpen />);

    expect(screen.getByRole('button', { name: 'Settings' })).toHaveAttribute(
      'aria-current',
      'page'
    );
  });

  it('calls setActiveTab for navigation buttons', () => {
    render(<Sidebar activeTab="dashboard" setActiveTab={setActiveTab} isOpen />);

    fireEvent.click(screen.getByRole('button', { name: 'Secure Classrooms' }));
    expect(setActiveTab).toHaveBeenCalledWith('classrooms');
  });

  it('calls logout when close session is clicked', () => {
    render(<Sidebar activeTab="dashboard" setActiveTab={setActiveTab} isOpen />);

    fireEvent.click(screen.getByRole('button', { name: 'Sign Out' }));
    expect(logout).toHaveBeenCalledTimes(1);
  });

  it('keeps domain requests hidden for non-admin users by default', () => {
    mockIsAdmin.mockReturnValue(false);

    render(<Sidebar activeTab="dashboard" setActiveTab={setActiveTab} isOpen />);

    expect(screen.queryByRole('button', { name: 'Domain Control' })).not.toBeInTheDocument();
  });

  it('can expose domain requests to non-admin users through an explicit prop', () => {
    mockIsAdmin.mockReturnValue(false);

    render(
      <Sidebar
        activeTab="domains"
        setActiveTab={setActiveTab}
        isOpen
        allowDomainRequestsForNonAdmins
      />
    );

    const domainsButton = screen.getByRole('button', { name: 'Domain Control' });
    expect(domainsButton).toHaveAttribute('aria-current', 'page');

    fireEvent.click(domainsButton);
    expect(setActiveTab).toHaveBeenCalledWith('domains');
  });

  it('renders expanded by default with full-width desktop classes', () => {
    render(<Sidebar activeTab="dashboard" setActiveTab={setActiveTab} isOpen />);

    const aside = screen.getByRole('complementary');
    expect(aside.className).toContain('md:w-64');
    expect(aside.className).not.toContain('md:w-16');

    expect(screen.getByRole('button', { name: 'Collapse menu' })).toHaveAttribute(
      'aria-expanded',
      'true'
    );
    expect(screen.getByRole('button', { name: 'Dashboard' })).not.toHaveAttribute('title');
  });

  it('renders an icon rail when collapsed', () => {
    render(<Sidebar activeTab="dashboard" setActiveTab={setActiveTab} isOpen collapsed />);

    const aside = screen.getByRole('complementary');
    expect(aside.className).toContain('md:w-16');

    const toggle = screen.getByRole('button', { name: 'Expand menu' });
    expect(toggle).toHaveAttribute('aria-expanded', 'false');

    expect(screen.getByRole('button', { name: 'Dashboard' })).toHaveAttribute('title', 'Dashboard');
  });

  it('invokes onToggleCollapse when the collapse control is clicked', () => {
    const onToggleCollapse = vi.fn();
    render(
      <Sidebar
        activeTab="dashboard"
        setActiveTab={setActiveTab}
        isOpen
        onToggleCollapse={onToggleCollapse}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: 'Collapse menu' }));
    expect(onToggleCollapse).toHaveBeenCalledTimes(1);
  });
});
