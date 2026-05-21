import React, { useEffect, useState } from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import App from './App';

const testDoubles = vi.hoisted(() => ({
  classroomPropsSpy: vi.fn(),
  isAdmin: vi.fn(),
  isAuthenticated: vi.fn(),
  logout: vi.fn(),
  onAuthChange: vi.fn(),
}));

vi.mock('./lib/auth', () => ({
  isAdmin: (): unknown => testDoubles.isAdmin(),
  isAuthenticated: (): unknown => testDoubles.isAuthenticated(),
  logout: (): unknown => testDoubles.logout(),
  onAuthChange: (listener: () => void): unknown => testDoubles.onAuthChange(listener),
}));

vi.mock('./components/Header', () => ({
  default: ({ title, onMenuClick }: { title: string; onMenuClick: () => void }) => (
    <div>
      <h1>{title}</h1>
      <button onClick={onMenuClick}>Abrir menu</button>
    </div>
  ),
}));

vi.mock('./components/Sidebar', () => ({
  default: ({ setActiveTab }: { setActiveTab: (tab: string) => void }) => (
    <nav>
      <button onClick={() => setActiveTab('dashboard')}>Ir dashboard</button>
      <button onClick={() => setActiveTab('classrooms')}>Ir aulas</button>
      <button onClick={() => setActiveTab('groups')}>Ir grupos</button>
      <button onClick={() => setActiveTab('users')}>Ir usuarios</button>
      <button onClick={() => setActiveTab('domains')}>Ir dominios</button>
      <button onClick={() => setActiveTab('settings')}>Ir configuracion</button>
    </nav>
  ),
}));

vi.mock('./views/Dashboard', () => ({
  default: ({
    onNavigateToClassroom,
  }: {
    onNavigateToClassroom?: (classroom: { id: string; name: string }) => void;
  }) => (
    <button
      onClick={() =>
        onNavigateToClassroom?.({
          id: 'classroom-3',
          name: 'Informatica 3',
        })
      }
    >
      Abrir Informatica 3
    </button>
  ),
}));

vi.mock('./views/Classrooms', () => ({
  default: ({
    initialSelectedClassroomId = null,
    onInitialSelectedClassroomIdConsumed,
  }: {
    initialSelectedClassroomId?: string | null;
    onInitialSelectedClassroomIdConsumed?: () => void;
  }) => {
    const [mountedSelection] = useState(initialSelectedClassroomId);

    useEffect(() => {
      if (initialSelectedClassroomId !== null) {
        onInitialSelectedClassroomIdConsumed?.();
      }
    }, [initialSelectedClassroomId, onInitialSelectedClassroomIdConsumed]);

    testDoubles.classroomPropsSpy({
      initialSelectedClassroomId,
    });

    return <div>Classrooms {mountedSelection ?? 'none'}</div>;
  },
}));

vi.mock('./views/TeacherDashboard', () => ({
  default: () => <div>Teacher dashboard</div>,
}));

vi.mock('./views/Groups', () => ({
  default: ({
    onNavigateToRules,
  }: {
    onNavigateToRules?: (group: { id: string; name: string }) => void;
  }) => (
    <div>
      <div>Groups</div>
      <button
        onClick={() =>
          onNavigateToRules?.({
            id: 'group-1',
            name: 'Grupo 1',
          })
        }
      >
        Abrir reglas grupo 1
      </button>
    </div>
  ),
}));

vi.mock('./views/Users', () => ({
  default: () => <div>Users</div>,
}));

vi.mock('./views/Login', () => ({
  default: ({
    onLogin,
    onNavigateToRegister,
    onNavigateToForgot,
  }: {
    onLogin?: () => void;
    onNavigateToRegister?: () => void;
    onNavigateToForgot?: () => void;
  }) => (
    <div>
      <div>Login</div>
      <button onClick={() => onLogin?.()}>Completar login</button>
      <button onClick={() => onNavigateToRegister?.()}>A registro</button>
      <button onClick={() => onNavigateToForgot?.()}>A recuperar</button>
    </div>
  ),
}));

vi.mock('./views/Register', () => ({
  default: ({
    onRegister,
    onNavigateToLogin,
  }: {
    onRegister?: () => void;
    onNavigateToLogin?: () => void;
  }) => (
    <div>
      <div>Register</div>
      <button onClick={() => onRegister?.()}>Completar registro</button>
      <button onClick={() => onNavigateToLogin?.()}>A login</button>
    </div>
  ),
}));

vi.mock('./views/ForgotPassword', () => ({
  default: ({
    onNavigateToLogin,
    onNavigateToReset,
  }: {
    onNavigateToLogin?: () => void;
    onNavigateToReset?: () => void;
  }) => (
    <div>
      <div>ForgotPassword</div>
      <button onClick={() => onNavigateToLogin?.()}>Recuperar a login</button>
      <button onClick={() => onNavigateToReset?.()}>A reset</button>
    </div>
  ),
}));

vi.mock('./views/ResetPassword', () => ({
  default: ({
    onNavigateToLogin,
    onNavigateToForgot,
  }: {
    onNavigateToLogin?: () => void;
    onNavigateToForgot?: () => void;
  }) => (
    <div>
      <div>ResetPassword</div>
      <button onClick={() => onNavigateToLogin?.()}>Reset a login</button>
      <button onClick={() => onNavigateToForgot?.()}>Reset a forgot</button>
    </div>
  ),
}));

vi.mock('./views/Settings', () => ({
  default: () => <div>Settings view</div>,
}));

vi.mock('./views/DomainRequests', () => ({
  default: () => <div>DomainRequests</div>,
}));

vi.mock('./views/RulesManager', () => ({
  default: () => <div>RulesManager</div>,
}));

describe('App', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.history.pushState(null, '', '/');
    testDoubles.isAdmin.mockReturnValue(true);
    testDoubles.isAuthenticated.mockReturnValue(true);
    testDoubles.onAuthChange.mockReturnValue(() => undefined);
  });

  it('opens the classrooms view with the classroom selected from the dashboard and updates the route', async () => {
    render(<App />);

    fireEvent.click(screen.getByText('Abrir Informatica 3'));

    await waitFor(() => {
      expect(screen.getByText('Classroom Management')).toBeInTheDocument();
      expect(screen.getByText('Classrooms classroom-3')).toBeInTheDocument();
      expect(window.location.pathname).toBe('/classrooms');
    });

    expect(testDoubles.classroomPropsSpy).toHaveBeenCalledWith({
      initialSelectedClassroomId: 'classroom-3',
    });
  });

  it('clears the one-shot classroom selection after it is consumed', async () => {
    render(<App />);

    fireEvent.click(screen.getByText('Abrir Informatica 3'));

    await waitFor(() => {
      expect(screen.getByText('Classrooms classroom-3')).toBeInTheDocument();
    });

    fireEvent.click(screen.getByText('Ir dashboard'));

    await waitFor(() => {
      expect(screen.getByText('Abrir Informatica 3')).toBeInTheDocument();
      expect(window.location.pathname).toBe('/');
    });

    fireEvent.click(screen.getByText('Ir aulas'));

    await waitFor(() => {
      expect(screen.getByText('Classrooms none')).toBeInTheDocument();
      expect(window.location.pathname).toBe('/classrooms');
    });
  });

  it('applies desktop viewport containment only to the classrooms shell', async () => {
    render(<App />);

    fireEvent.click(screen.getByText('Ir aulas'));

    await waitFor(() => {
      expect(screen.getByText('Classrooms none')).toBeInTheDocument();
    });

    expect(screen.getByTestId('openpath-shell-root')).toHaveClass('lg:h-screen');
    expect(screen.getByTestId('openpath-shell-root')).toHaveClass('lg:overflow-hidden');
    expect(screen.getByTestId('openpath-shell-content')).toHaveClass('lg:h-full');
    expect(screen.getByTestId('openpath-shell-content')).toHaveClass('lg:min-h-0');
    expect(screen.getByTestId('openpath-shell-content')).toHaveClass('lg:overflow-hidden');
    expect(screen.getByTestId('openpath-shell-main')).toHaveClass('overflow-y-auto');
    expect(screen.getByTestId('openpath-shell-main')).toHaveClass('lg:min-h-0');
    expect(screen.getByTestId('openpath-shell-main')).toHaveClass('lg:overflow-hidden');
    expect(screen.getByTestId('openpath-shell-content-wrapper')).toHaveClass('lg:h-full');
    expect(screen.getByTestId('openpath-shell-content-wrapper')).toHaveClass('lg:min-h-0');

    fireEvent.click(screen.getByText('Ir configuracion'));

    await waitFor(() => {
      expect(screen.getByText('Settings view')).toBeInTheDocument();
    });

    expect(screen.getByTestId('openpath-shell-root')).not.toHaveClass('lg:h-screen');
    expect(screen.getByTestId('openpath-shell-root')).not.toHaveClass('lg:overflow-hidden');
    expect(screen.getByTestId('openpath-shell-content')).not.toHaveClass('lg:h-screen');
    expect(screen.getByTestId('openpath-shell-content')).not.toHaveClass('lg:overflow-hidden');
    expect(screen.getByTestId('openpath-shell-main')).toHaveClass('overflow-y-auto');
  });

  it('renders auth views from unauthenticated routes and allows moving between them', () => {
    testDoubles.isAuthenticated.mockReturnValue(false);
    window.history.pushState(null, '', '/register');

    render(<App />);

    expect(screen.getByText('Register')).toBeInTheDocument();

    fireEvent.click(screen.getByText('A login'));
    expect(screen.getByText('Login')).toBeInTheDocument();

    fireEvent.click(screen.getByText('A recuperar'));
    expect(screen.getByText('ForgotPassword')).toBeInTheDocument();

    fireEvent.click(screen.getByText('A reset'));
    expect(screen.getByText('ResetPassword')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Reset a login'));
    expect(screen.getByText('Login')).toBeInTheDocument();
  });

  it('enters the authenticated app after completing login or registration', async () => {
    testDoubles.isAuthenticated.mockReturnValue(false);
    window.history.pushState(null, '', '/login');

    const { unmount } = render(<App />);

    fireEvent.click(screen.getByText('Completar login'));

    await waitFor(() => {
      expect(screen.getByText('Overview')).toBeInTheDocument();
      expect(window.location.pathname).toBe('/');
    });

    unmount();

    testDoubles.isAuthenticated.mockReturnValue(false);
    window.history.pushState(null, '', '/register');

    render(<App />);
    fireEvent.click(screen.getByText('Completar registro'));

    await waitFor(() => {
      expect(screen.getByText('Overview')).toBeInTheDocument();
      expect(window.location.pathname).toBe('/');
    });
  });

  it('updates titles for admin sections, rules manager, and settings', () => {
    render(<App />);

    fireEvent.click(screen.getByText('Ir grupos'));
    expect(screen.getByText('Groups and Policies')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Abrir reglas grupo 1'));
    expect(screen.getByText('Rules: Grupo 1')).toBeInTheDocument();
    expect(screen.getByText('RulesManager')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Ir usuarios'));
    expect(screen.getByText('User Administration')).toBeInTheDocument();
    expect(screen.getByText('Users')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Ir dominios'));
    expect(screen.getByText('Access Requests')).toBeInTheDocument();
    expect(screen.getByText('DomainRequests')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Ir configuracion'));
    expect(screen.getByRole('heading', { name: 'Settings' })).toBeInTheDocument();
    expect(screen.getByText('Settings view')).toBeInTheDocument();
  });

  it('falls back to teacher views for protected admin tabs and toggles the mobile overlay', async () => {
    testDoubles.isAdmin.mockReturnValue(false);
    const { container } = render(<App />);

    expect(screen.getByText('My Dashboard')).toBeInTheDocument();
    expect(screen.getByText('Teacher dashboard')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Ir usuarios'));
    expect(screen.getByText('My Dashboard')).toBeInTheDocument();
    expect(screen.getByText('Teacher dashboard')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Ir dominios'));
    expect(screen.getByText('My Dashboard')).toBeInTheDocument();
    expect(screen.getByText('Teacher dashboard')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Abrir menu'));
    const overlay = container.querySelector('div.fixed.inset-0.bg-slate-900\\/50');
    expect(overlay).not.toBeNull();
    if (!overlay) {
      throw new Error('Expected mobile overlay to be rendered');
    }

    fireEvent.click(overlay);

    await waitFor(() => {
      expect(container.querySelector('div.fixed.inset-0.bg-slate-900\\/50')).toBeNull();
    });
  });
});
