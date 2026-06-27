import { describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/react';

import ForgotPassword from '../ForgotPassword';

describe('ForgotPassword View', () => {
  it('renders the OpenPath title', () => {
    render(<ForgotPassword onNavigateToLogin={vi.fn()} onNavigateToReset={vi.fn()} />);
    expect(screen.getByRole('heading', { name: 'OpenPath' })).toBeInTheDocument();
  });

  it('renders the subtitle', () => {
    render(<ForgotPassword onNavigateToLogin={vi.fn()} onNavigateToReset={vi.fn()} />);
    expect(screen.getByText('Recover password')).toBeInTheDocument();
  });

  it('renders the recovery information panel', () => {
    render(<ForgotPassword onNavigateToLogin={vi.fn()} onNavigateToReset={vi.fn()} />);
    expect(screen.getByText('Recovery process')).toBeInTheDocument();
    expect(
      screen.getByText('Request a recovery token from your administrator')
    ).toBeInTheDocument();
  });

  it('renders the "I have a token" button', () => {
    render(<ForgotPassword onNavigateToLogin={vi.fn()} onNavigateToReset={vi.fn()} />);
    expect(screen.getByRole('button', { name: 'I have a token' })).toBeInTheDocument();
  });

  it('calls onNavigateToReset when "I have a token" is clicked', () => {
    const onNavigateToReset = vi.fn();
    render(<ForgotPassword onNavigateToLogin={vi.fn()} onNavigateToReset={onNavigateToReset} />);

    fireEvent.click(screen.getByRole('button', { name: 'I have a token' }));

    expect(onNavigateToReset).toHaveBeenCalledTimes(1);
  });

  it('calls onNavigateToLogin when the back-to-sign-in button is clicked', () => {
    const onNavigateToLogin = vi.fn();
    render(<ForgotPassword onNavigateToLogin={onNavigateToLogin} onNavigateToReset={vi.fn()} />);

    fireEvent.click(screen.getByRole('button', { name: /back to sign in/i }));

    expect(onNavigateToLogin).toHaveBeenCalledTimes(1);
  });

  it('calls onNavigateToLogin when the Cancel button is clicked', () => {
    const onNavigateToLogin = vi.fn();
    render(<ForgotPassword onNavigateToLogin={onNavigateToLogin} onNavigateToReset={vi.fn()} />);

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(onNavigateToLogin).toHaveBeenCalledTimes(1);
  });

  it('does not call onNavigateToReset when Cancel is clicked', () => {
    const onNavigateToReset = vi.fn();
    render(<ForgotPassword onNavigateToLogin={vi.fn()} onNavigateToReset={onNavigateToReset} />);

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(onNavigateToReset).not.toHaveBeenCalled();
  });

  it('does not call onNavigateToLogin when "I have a token" is clicked', () => {
    const onNavigateToLogin = vi.fn();
    render(<ForgotPassword onNavigateToLogin={onNavigateToLogin} onNavigateToReset={vi.fn()} />);

    fireEvent.click(screen.getByRole('button', { name: 'I have a token' }));

    expect(onNavigateToLogin).not.toHaveBeenCalled();
  });
});
