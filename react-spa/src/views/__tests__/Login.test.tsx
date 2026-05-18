import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';

import Login from '../Login';

const { mockLogin, mockLoginWithGoogle, mockReportError } = vi.hoisted(() => ({
  mockLogin: vi.fn(),
  mockLoginWithGoogle: vi.fn(),
  mockReportError: vi.fn(),
}));

vi.mock('../../lib/auth', () => ({
  login: mockLogin,
  loginWithGoogle: mockLoginWithGoogle,
}));

vi.mock('../../lib/reportError', () => ({
  reportError: mockReportError,
}));

vi.mock('../../components/GoogleLoginButton', () => ({
  default: ({
    disabled,
    onSuccess,
  }: {
    disabled?: boolean;
    onSuccess: (token: string) => void;
  }) => (
    <button disabled={disabled} onClick={() => onSuccess('google-id-token')} type="button">
      Continuar con Google
    </button>
  ),
}));

describe('Login View', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockLogin.mockResolvedValue({
      id: 'user-1',
      email: 'admin@example.edu',
      name: 'Admin User',
      roles: [{ role: 'admin' }],
    });
    mockLoginWithGoogle.mockResolvedValue({
      id: 'user-google',
      email: 'google@example.edu',
      name: 'Google Admin',
      roles: [{ role: 'admin' }],
    });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('submits credentials and calls onLogin after a successful email/password login', async () => {
    const onLogin = vi.fn();

    render(<Login onLogin={onLogin} onNavigateToForgot={vi.fn()} onNavigateToRegister={vi.fn()} />);

    fireEvent.change(screen.getByPlaceholderText('admin@institucion.edu'), {
      target: { value: 'admin@example.edu' },
    });
    fireEvent.change(screen.getByPlaceholderText('••••••••'), {
      target: { value: 'SecurePassword123!' },
    });
    fireEvent.click(screen.getByRole('button', { name: /sign in/i }));

    await waitFor(() => {
      expect(mockLogin).toHaveBeenCalledWith('admin@example.edu', 'SecurePassword123!');
    });
    expect(onLogin).toHaveBeenCalledTimes(1);
  });

  it('shows the login error state and reports failures', async () => {
    mockLogin.mockRejectedValueOnce(new Error('invalid credentials'));

    render(<Login onLogin={vi.fn()} onNavigateToForgot={vi.fn()} onNavigateToRegister={vi.fn()} />);

    fireEvent.change(screen.getByPlaceholderText('admin@institucion.edu'), {
      target: { value: 'admin@example.edu' },
    });
    fireEvent.change(screen.getByPlaceholderText('••••••••'), {
      target: { value: 'WrongPassword123!' },
    });
    fireEvent.click(screen.getByRole('button', { name: /sign in/i }));

    expect(await screen.findByText('Invalid credentials or connection error')).toBeInTheDocument();
    expect(mockReportError).toHaveBeenCalledWith('Failed to login:', expect.any(Error));
  });

  it('routes auxiliary actions through the provided callbacks and handles Google login failures', async () => {
    const onNavigateToForgot = vi.fn();
    const onNavigateToRegister = vi.fn();
    mockLoginWithGoogle.mockRejectedValueOnce(new Error('Cuenta no aprobada'));

    render(
      <Login
        onLogin={vi.fn()}
        onNavigateToForgot={onNavigateToForgot}
        onNavigateToRegister={onNavigateToRegister}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: 'Recover password' }));
    fireEvent.click(screen.getByRole('button', { name: 'Request access' }));

    expect(onNavigateToForgot).toHaveBeenCalledTimes(1);
    expect(onNavigateToRegister).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: 'Continuar con Google' }));

    expect(await screen.findByText('Cuenta no aprobada')).toBeInTheDocument();
    expect(mockReportError).toHaveBeenCalledWith('Failed to login with Google:', expect.any(Error));
  });
});
