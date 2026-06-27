import { beforeEach, describe, expect, it, vi, type MockedFunction } from 'vitest';
import { render, screen, act } from '@testing-library/react';

import GoogleLoginButton from '../GoogleLoginButton';
import type { GoogleCredentialResponse } from '../../hooks/useGoogleAuth';

const { mockInitGoogleAuth, mockUseGoogleAuth } = vi.hoisted(() => ({
  mockInitGoogleAuth: vi.fn<(cb: (r: GoogleCredentialResponse) => void) => void>(),
  mockUseGoogleAuth:
    vi.fn<
      () => {
        isLoaded: boolean;
        initGoogleAuth: (cb: (r: GoogleCredentialResponse) => void) => void;
      }
    >(),
}));

vi.mock('../../hooks/useGoogleAuth', () => ({
  useGoogleAuth: () => mockUseGoogleAuth(),
}));

// Stub the side-effect-only import so it doesn't fail in jsdom
vi.mock('../../types/google.d', () => ({}));

describe('GoogleLoginButton', () => {
  const mockRenderButton = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();

    // Default: Google SDK not yet loaded
    mockUseGoogleAuth.mockReturnValue({ isLoaded: false, initGoogleAuth: mockInitGoogleAuth });

    // Install a minimal window.google stub
    Object.defineProperty(window, 'google', {
      value: {
        accounts: {
          id: {
            initialize: vi.fn(),
            renderButton: mockRenderButton,
          },
        },
      },
      configurable: true,
      writable: true,
    });
  });

  it('renders the container element', () => {
    render(<GoogleLoginButton onSuccess={vi.fn()} />);
    expect(screen.getByTestId('google-login-container')).toBeInTheDocument();
  });

  it('shows the loading skeleton while Google SDK is not yet loaded', () => {
    render(<GoogleLoginButton onSuccess={vi.fn()} />);
    expect(screen.getByLabelText('Loading Google button...')).toBeInTheDocument();
  });

  it('hides the skeleton and exposes the button div once loaded', () => {
    mockUseGoogleAuth.mockReturnValue({ isLoaded: true, initGoogleAuth: mockInitGoogleAuth });

    render(<GoogleLoginButton onSuccess={vi.fn()} />);

    expect(screen.queryByLabelText('Loading Google button...')).not.toBeInTheDocument();
    const btn = screen.getByTestId('google-signin-btn');
    expect(btn.className).not.toContain('hidden');
  });

  it('calls initGoogleAuth with a callback that forwards the credential', () => {
    mockUseGoogleAuth.mockReturnValue({ isLoaded: true, initGoogleAuth: mockInitGoogleAuth });

    const onSuccess = vi.fn();
    render(<GoogleLoginButton onSuccess={onSuccess} />);

    expect(mockInitGoogleAuth).toHaveBeenCalledTimes(1);

    // Simulate the Google SDK firing the callback
    const callback = (
      mockInitGoogleAuth as MockedFunction<(cb: (r: GoogleCredentialResponse) => void) => void>
    ).mock.calls[0][0];
    act(() => {
      callback({ credential: 'test-id-token' });
    });

    expect(onSuccess).toHaveBeenCalledWith('test-id-token');
  });

  it('calls window.google.accounts.id.renderButton on the ref element when loaded', () => {
    mockUseGoogleAuth.mockReturnValue({ isLoaded: true, initGoogleAuth: mockInitGoogleAuth });

    render(<GoogleLoginButton onSuccess={vi.fn()} />);

    expect(mockRenderButton).toHaveBeenCalledTimes(1);
    expect(mockRenderButton).toHaveBeenCalledWith(
      expect.any(HTMLDivElement),
      expect.objectContaining({ theme: 'outline', size: 'large' })
    );
  });

  it('does not call initGoogleAuth or renderButton when disabled', () => {
    mockUseGoogleAuth.mockReturnValue({ isLoaded: true, initGoogleAuth: mockInitGoogleAuth });

    render(<GoogleLoginButton onSuccess={vi.fn()} disabled />);

    expect(mockInitGoogleAuth).not.toHaveBeenCalled();
    expect(mockRenderButton).not.toHaveBeenCalled();
  });

  it('applies opacity styling on the wrapper when disabled', () => {
    mockUseGoogleAuth.mockReturnValue({ isLoaded: true, initGoogleAuth: mockInitGoogleAuth });

    render(<GoogleLoginButton onSuccess={vi.fn()} disabled />);

    const container = screen.getByTestId('google-login-container');
    expect(container.innerHTML).toContain('opacity-50');
  });

  it('hides the loading skeleton when disabled even if the SDK is not loaded', () => {
    // isLoaded: false, disabled: true → skeleton must not appear
    render(<GoogleLoginButton onSuccess={vi.fn()} disabled />);
    expect(screen.queryByLabelText('Loading Google button...')).not.toBeInTheDocument();
  });

  it('does not reinitialize after a re-render', () => {
    mockUseGoogleAuth.mockReturnValue({ isLoaded: true, initGoogleAuth: mockInitGoogleAuth });

    const { rerender } = render(<GoogleLoginButton onSuccess={vi.fn()} />);
    rerender(<GoogleLoginButton onSuccess={vi.fn()} />);

    // initializedRef prevents a second call on re-render
    expect(mockInitGoogleAuth).toHaveBeenCalledTimes(1);
  });
});
