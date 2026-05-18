import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import Settings from '../Settings';
import Register from '../Register';

const { mockChangePassword, mockRegister, mockReportError } = vi.hoisted(() => ({
  mockChangePassword: vi.fn(),
  mockRegister: vi.fn(),
  mockReportError: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    auth: {
      changePassword: {
        mutate: mockChangePassword,
      },
      register: {
        mutate: mockRegister,
      },
    },
  },
}));

vi.mock('../../lib/reportError', () => ({
  reportError: mockReportError,
}));

describe('Settings View - Change Password', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.localStorage.clear();
    mockChangePassword.mockResolvedValue({ success: true });
    mockRegister.mockResolvedValue({ success: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('does not render deprecated operational or API token sections', () => {
    render(<Settings />);

    expect(screen.queryByText('API Keys')).not.toBeInTheDocument();
    expect(screen.queryByText('Database')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Create token' })).not.toBeInTheDocument();
    expect(screen.queryByText(/OpenPath v/i)).not.toBeInTheDocument();
  });

  it('blocks submit when required fields are missing', async () => {
    render(<Settings />);

    fireEvent.click(screen.getByRole('button', { name: 'Change password' }));
    fireEvent.click(screen.getByRole('button', { name: 'Change Password' }));

    expect(await screen.findByText('All fields are required')).toBeInTheDocument();
    expect(mockChangePassword).not.toHaveBeenCalled();
  });

  it('shows API error when change password fails', async () => {
    mockChangePassword.mockRejectedValueOnce(new Error('invalid current password'));

    render(<Settings />);

    fireEvent.click(screen.getByRole('button', { name: 'Change password' }));
    fireEvent.change(screen.getByPlaceholderText('Enter your current password'), {
      target: { value: 'wrong-password' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'NewPassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('Repeat the new password'), {
      target: { value: 'NewPassword123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Change Password' }));

    expect(
      await screen.findByText('Unable to change password. Check your current password.')
    ).toBeInTheDocument();
  });

  it('calls API and shows success message', async () => {
    render(<Settings />);

    fireEvent.click(screen.getByRole('button', { name: 'Change password' }));
    fireEvent.change(screen.getByPlaceholderText('Enter your current password'), {
      target: { value: 'CurrentPassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'NewPassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('Repeat the new password'), {
      target: { value: 'NewPassword123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Change Password' }));

    await waitFor(() => {
      expect(mockChangePassword).toHaveBeenCalledWith({
        currentPassword: 'CurrentPassword123!',
        newPassword: 'NewPassword123!',
      });
    });

    expect(await screen.findByText('Password updated successfully!')).toBeInTheDocument();
  });

  it('validates password length and confirmation before calling the API', async () => {
    render(<Settings />);

    fireEvent.click(screen.getByRole('button', { name: 'Change password' }));
    fireEvent.change(screen.getByPlaceholderText('Enter your current password'), {
      target: { value: 'CurrentPassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'short' },
    });
    fireEvent.change(screen.getByPlaceholderText('Repeat the new password'), {
      target: { value: 'short' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Change Password' }));
    expect(
      await screen.findByText('New password must be at least 8 characters')
    ).toBeInTheDocument();
    expect(mockChangePassword).not.toHaveBeenCalled();

    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'NewPassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('Repeat the new password'), {
      target: { value: 'MismatchPassword123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Change Password' }));
    expect(await screen.findByText('Passwords do not match')).toBeInTheDocument();
    expect(mockChangePassword).not.toHaveBeenCalled();
  });

  it('closes and resets the modal after a successful password change', async () => {
    render(<Settings />);

    fireEvent.click(screen.getByRole('button', { name: 'Change password' }));
    fireEvent.change(screen.getByPlaceholderText('Enter your current password'), {
      target: { value: 'CurrentPassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'NewPassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('Repeat the new password'), {
      target: { value: 'NewPassword123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Change Password' }));

    expect(await screen.findByText('Password updated successfully!')).toBeInTheDocument();

    await waitFor(
      () => {
        expect(screen.queryByText('Password updated successfully!')).not.toBeInTheDocument();
      },
      { timeout: 2500 }
    );

    fireEvent.click(screen.getByRole('button', { name: 'Change password' }));
    expect(screen.getByPlaceholderText('Enter your current password')).toHaveValue('');
    expect(screen.getByPlaceholderText('Minimum 8 characters')).toHaveValue('');
    expect(screen.getByPlaceholderText('Repeat the new password')).toHaveValue('');
  });

  it('closes the modal and clears previous validation state when cancelled', async () => {
    render(<Settings />);

    fireEvent.click(screen.getByRole('button', { name: 'Change password' }));
    fireEvent.change(screen.getByPlaceholderText('Enter your current password'), {
      target: { value: 'CurrentPassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'MismatchPassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('Repeat the new password'), {
      target: { value: 'OtherPassword123!' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Change Password' }));

    expect(await screen.findByText('Passwords do not match')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    await waitFor(() => {
      expect(screen.queryByText('Passwords do not match')).not.toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: 'Change password' }));
    expect(screen.queryByText('Passwords do not match')).not.toBeInTheDocument();
    expect(screen.getByPlaceholderText('Enter your current password')).toHaveValue('');
  });

  it('persists notification toggles across remounts', async () => {
    const { unmount } = render(<Settings />);

    const securityAlertsCheckbox = await screen.findByRole('checkbox', {
      name: 'Security alerts',
    });
    const domainRequestsCheckbox = await screen.findByRole('checkbox', {
      name: 'New domain requests',
    });
    const weeklyReportsCheckbox = await screen.findByRole('checkbox', {
      name: 'Weekly reports',
    });
    expect(securityAlertsCheckbox).toBeChecked();
    expect(domainRequestsCheckbox).toBeChecked();
    expect(weeklyReportsCheckbox).not.toBeChecked();

    fireEvent.click(securityAlertsCheckbox);
    fireEvent.click(domainRequestsCheckbox);
    fireEvent.click(weeklyReportsCheckbox);
    expect(securityAlertsCheckbox).not.toBeChecked();
    expect(domainRequestsCheckbox).not.toBeChecked();
    expect(weeklyReportsCheckbox).toBeChecked();

    unmount();
    render(<Settings />);

    expect(await screen.findByRole('checkbox', { name: 'Security alerts' })).not.toBeChecked();
    expect(await screen.findByRole('checkbox', { name: 'New domain requests' })).not.toBeChecked();
    expect(await screen.findByRole('checkbox', { name: 'Weekly reports' })).toBeChecked();
  });
});

describe('Register View', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockRegister.mockResolvedValue({ success: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('does not expose Google signup affordances', () => {
    const onRegister = vi.fn();
    const onNavigateToLogin = vi.fn();

    render(<Register onRegister={onRegister} onNavigateToLogin={onNavigateToLogin} />);

    expect(screen.getByText('Institution Registration')).toBeInTheDocument();
    expect(screen.queryByText(/google/i)).not.toBeInTheDocument();
    expect(screen.queryByText('Or continue with')).not.toBeInTheDocument();
  });

  it('shows short-password validation and blocks submission', async () => {
    const onRegister = vi.fn();

    render(<Register onRegister={onRegister} onNavigateToLogin={vi.fn()} />);

    fireEvent.change(screen.getByPlaceholderText('Your full name'), {
      target: { value: 'Admin User' },
    });
    fireEvent.change(screen.getByPlaceholderText('admin@escuela.edu'), {
      target: { value: 'admin@example.edu' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'short' },
    });
    fireEvent.change(screen.getByPlaceholderText('••••••••'), {
      target: { value: 'short' },
    });

    const form = screen.getByRole('button', { name: /create account/i }).closest('form');
    if (!(form instanceof HTMLFormElement)) {
      throw new Error('Expected register form to be rendered');
    }
    fireEvent.submit(form);

    expect(await screen.findByText('Password must be at least 8 characters')).toBeInTheDocument();
    expect(screen.getByText('Minimum 8 characters')).toBeInTheDocument();
    expect(mockRegister).not.toHaveBeenCalled();
  });

  it('shows mismatch validation and prevents submission', async () => {
    render(<Register onRegister={vi.fn()} onNavigateToLogin={vi.fn()} />);

    fireEvent.change(screen.getByPlaceholderText('Your full name'), {
      target: { value: 'Admin User' },
    });
    fireEvent.change(screen.getByPlaceholderText('admin@escuela.edu'), {
      target: { value: 'admin@example.edu' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'Password123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('••••••••'), {
      target: { value: 'Mismatch123!' },
    });

    const form = screen.getByRole('button', { name: /create account/i }).closest('form');
    if (!(form instanceof HTMLFormElement)) {
      throw new Error('Expected register form to be rendered');
    }
    fireEvent.submit(form);

    expect(await screen.findAllByText('Passwords do not match')).toHaveLength(2);
    expect(mockRegister).not.toHaveBeenCalled();
  });

  it('submits a normalized payload and redirects after success', async () => {
    const onRegister = vi.fn();

    render(<Register onRegister={onRegister} onNavigateToLogin={vi.fn()} />);

    fireEvent.change(screen.getByPlaceholderText('Your full name'), {
      target: { value: '  Ada Lovelace  ' },
    });
    fireEvent.change(screen.getByPlaceholderText('admin@escuela.edu'), {
      target: { value: '  ADMIN@Example.EDU  ' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'systems_admin' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'Password123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('••••••••'), {
      target: { value: 'Password123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create account/i }));

    await waitFor(() => {
      expect(mockRegister).toHaveBeenCalledWith({
        name: 'Ada Lovelace',
        email: 'admin@example.edu',
        password: 'Password123!',
      });
    });
    expect(
      await screen.findByText(/Account created successfully\. Redirecting to Dashboard\.\.\./i)
    ).toBeInTheDocument();

    await waitFor(
      () => {
        expect(onRegister).toHaveBeenCalledTimes(1);
      },
      { timeout: 2000 }
    );
  });

  it('surfaces registration API failures and reports them', async () => {
    const onRegister = vi.fn();
    mockRegister.mockRejectedValueOnce(new Error('Correo ya registrado'));

    render(<Register onRegister={onRegister} onNavigateToLogin={vi.fn()} />);

    fireEvent.change(screen.getByPlaceholderText('Your full name'), {
      target: { value: 'Admin User' },
    });
    fireEvent.change(screen.getByPlaceholderText('admin@escuela.edu'), {
      target: { value: 'admin@example.edu' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'Password123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('••••••••'), {
      target: { value: 'Password123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create account/i }));

    expect(await screen.findByText(/Correo ya registrado/i)).toBeInTheDocument();
    expect(mockReportError).toHaveBeenCalledWith('Failed to register user:', expect.any(Error));
    expect(onRegister).not.toHaveBeenCalled();
  });

  it('navigates back to the login screen when requested', () => {
    const onNavigateToLogin = vi.fn();

    render(<Register onRegister={vi.fn()} onNavigateToLogin={onNavigateToLogin} />);

    fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));

    expect(onNavigateToLogin).toHaveBeenCalledTimes(1);
  });
});
