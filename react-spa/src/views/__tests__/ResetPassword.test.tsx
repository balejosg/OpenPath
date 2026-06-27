import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';

import ResetPassword from '../ResetPassword';

const { mockResetPassword } = vi.hoisted(() => ({
  mockResetPassword: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    auth: {
      resetPassword: {
        mutate: mockResetPassword,
      },
    },
  },
}));

/** Fill out all four form fields to a valid state. */
function fillValidForm(): void {
  fireEvent.change(screen.getByPlaceholderText('you@example.com'), {
    target: { value: 'user@example.com' },
  });
  fireEvent.change(screen.getByPlaceholderText('Paste your token here'), {
    target: { value: 'tok-abc123' },
  });
  // Password that satisfies all requirements
  fireEvent.change(screen.getAllByPlaceholderText('••••••••')[0], {
    target: { value: 'Secure1pass' },
  });
  fireEvent.change(screen.getAllByPlaceholderText('••••••••')[1], {
    target: { value: 'Secure1pass' },
  });
}

describe('ResetPassword View', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockResetPassword.mockResolvedValue(undefined);
  });

  it('renders the form fields', () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    expect(screen.getByPlaceholderText('you@example.com')).toBeInTheDocument();
    expect(screen.getByPlaceholderText('Paste your token here')).toBeInTheDocument();
    expect(screen.getAllByPlaceholderText('••••••••')).toHaveLength(2);
  });

  it('submit button is disabled when form is empty', () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    expect(screen.getByRole('button', { name: 'Reset password' })).toBeDisabled();
  });

  it('submit button stays disabled until all requirements are met', () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    // Email and token filled, but password empty → still disabled
    fireEvent.change(screen.getByPlaceholderText('you@example.com'), {
      target: { value: 'user@example.com' },
    });
    fireEvent.change(screen.getByPlaceholderText('Paste your token here'), {
      target: { value: 'tok-abc' },
    });

    expect(screen.getByRole('button', { name: 'Reset password' })).toBeDisabled();
  });

  it('submit button is enabled once all fields are valid and passwords match', () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    fillValidForm();

    expect(screen.getByRole('button', { name: 'Reset password' })).not.toBeDisabled();
  });

  it('shows a password-mismatch error when passwords differ', () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    fireEvent.change(screen.getAllByPlaceholderText('••••••••')[0], {
      target: { value: 'Secure1pass' },
    });
    fireEvent.change(screen.getAllByPlaceholderText('••••••••')[1], {
      target: { value: 'Different1X' },
    });

    expect(screen.getByText('Passwords do not match')).toBeInTheDocument();
  });

  it('calls trpc.auth.resetPassword.mutate with correct payload on submit', async () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    fillValidForm();
    fireEvent.click(screen.getByRole('button', { name: 'Reset password' }));

    await waitFor(() => {
      expect(mockResetPassword).toHaveBeenCalledWith({
        email: 'user@example.com',
        token: 'tok-abc123',
        newPassword: 'Secure1pass',
      });
    });
  });

  it('shows the success screen after a successful reset', async () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    fillValidForm();
    fireEvent.click(screen.getByRole('button', { name: 'Reset password' }));

    expect(await screen.findByText('Password reset')).toBeInTheDocument();
    expect(
      screen.getByText('Your password has been updated. You can now sign in.')
    ).toBeInTheDocument();
  });

  it('shows an API error message when reset fails with a known error', async () => {
    mockResetPassword.mockRejectedValueOnce(new Error('Token expired'));

    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    fillValidForm();
    fireEvent.click(screen.getByRole('button', { name: 'Reset password' }));

    expect(await screen.findByText('Token expired')).toBeInTheDocument();
  });

  it('shows a generic error message when the thrown value is not an Error instance', async () => {
    mockResetPassword.mockRejectedValueOnce('unexpected');

    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    fillValidForm();
    fireEvent.click(screen.getByRole('button', { name: 'Reset password' }));

    expect(
      await screen.findByText('Unable to reset the password. Check the token.')
    ).toBeInTheDocument();
  });

  it('toggles password field visibility when the eye icon is clicked', () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    const passwordInputs = screen.getAllByPlaceholderText('••••••••');
    const passwordInput = passwordInputs[0];

    // Initial type is password
    expect(passwordInput).toHaveAttribute('type', 'password');

    // Click the toggle button — the first button after the new-password label area
    const toggleButtons = screen.getAllByRole('button', { name: '' });
    fireEvent.click(toggleButtons[0]);

    expect(passwordInput).toHaveAttribute('type', 'text');
  });

  it('toggles confirm-password field visibility when its eye icon is clicked', () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    const passwordInputs = screen.getAllByPlaceholderText('••••••••');
    const confirmInput = passwordInputs[1];

    expect(confirmInput).toHaveAttribute('type', 'password');

    const toggleButtons = screen.getAllByRole('button', { name: '' });
    fireEvent.click(toggleButtons[1]);

    expect(confirmInput).toHaveAttribute('type', 'text');
  });

  it('calls onNavigateToForgot when the back button is clicked', () => {
    const onNavigateToForgot = vi.fn();
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={onNavigateToForgot} />);

    fireEvent.click(screen.getByRole('button', { name: /back/i }));

    expect(onNavigateToForgot).toHaveBeenCalledTimes(1);
  });

  it('calls onNavigateToLogin from the success screen', async () => {
    const onNavigateToLogin = vi.fn();
    render(<ResetPassword onNavigateToLogin={onNavigateToLogin} onNavigateToForgot={vi.fn()} />);

    fillValidForm();
    fireEvent.click(screen.getByRole('button', { name: 'Reset password' }));

    // Wait for success screen
    await screen.findByText('Password reset');

    fireEvent.click(screen.getByRole('button', { name: /sign in/i }));

    expect(onNavigateToLogin).toHaveBeenCalledTimes(1);
  });

  it('displays all four password requirements', () => {
    render(<ResetPassword onNavigateToLogin={vi.fn()} onNavigateToForgot={vi.fn()} />);

    expect(screen.getByText('At least 8 characters')).toBeInTheDocument();
    expect(screen.getByText('One uppercase letter')).toBeInTheDocument();
    expect(screen.getByText('One lowercase letter')).toBeInTheDocument();
    expect(screen.getByText('One number')).toBeInTheDocument();
  });
});
