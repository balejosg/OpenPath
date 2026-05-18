import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';

import Register from '../Register';

const { mockRegister, mockReportError } = vi.hoisted(() => ({
  mockRegister: vi.fn(),
  mockReportError: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    auth: {
      register: {
        mutate: mockRegister,
      },
    },
  },
}));

vi.mock('../../lib/reportError', () => ({
  reportError: mockReportError,
}));

describe('Register View', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockRegister.mockResolvedValue({ success: true });
  });

  it('normalizes the registration payload and redirects after success', async () => {
    const onRegister = vi.fn();

    render(<Register onRegister={onRegister} onNavigateToLogin={vi.fn()} />);

    fireEvent.change(screen.getByPlaceholderText('Your full name'), {
      target: { value: '  Ada Lovelace  ' },
    });
    fireEvent.change(screen.getByPlaceholderText('admin@escuela.edu'), {
      target: { value: '  ADMIN@Example.EDU  ' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'SecurePassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('••••••••'), {
      target: { value: 'SecurePassword123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create account/i }));

    await waitFor(() => {
      expect(mockRegister).toHaveBeenCalledWith({
        name: 'Ada Lovelace',
        email: 'admin@example.edu',
        password: 'SecurePassword123!',
      });
    });

    expect(await screen.findByText(/Account created successfully/i)).toBeInTheDocument();

    await waitFor(
      () => {
        expect(onRegister).toHaveBeenCalledTimes(1);
      },
      { timeout: 2000 }
    );
  });

  it('surfaces registration failures, reports them, and lets the user navigate back to login', async () => {
    const onNavigateToLogin = vi.fn();
    mockRegister.mockRejectedValueOnce(new Error('Correo ya registrado'));

    render(<Register onRegister={vi.fn()} onNavigateToLogin={onNavigateToLogin} />);

    fireEvent.change(screen.getByPlaceholderText('Your full name'), {
      target: { value: 'Admin User' },
    });
    fireEvent.change(screen.getByPlaceholderText('admin@escuela.edu'), {
      target: { value: 'admin@example.edu' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'SecurePassword123!' },
    });
    fireEvent.change(screen.getByPlaceholderText('••••••••'), {
      target: { value: 'SecurePassword123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create account/i }));

    expect(await screen.findByText('Correo ya registrado')).toBeInTheDocument();
    expect(mockReportError).toHaveBeenCalledWith('Failed to register user:', expect.any(Error));

    fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
    expect(onNavigateToLogin).toHaveBeenCalledTimes(1);
  });
});
