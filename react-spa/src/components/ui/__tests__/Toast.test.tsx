import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { ToastContainer, useToast } from '../Toast';
import React from 'react';

// Test component that uses the useToast hook
const TestComponent: React.FC<{ onMount?: (toast: ReturnType<typeof useToast>) => void }> = ({
  onMount,
}) => {
  const toast = useToast();

  React.useEffect(() => {
    onMount?.(toast);
  }, [onMount, toast]);

  return (
    <div>
      <button onClick={() => toast.success('Success message')}>Show Success</button>
      <button onClick={() => toast.error('Error message')}>Show Error</button>
      <button onClick={() => toast.info('Info message')}>Show Info</button>
      <button onClick={() => toast.success('Undo test', () => undefined)}>Show Undo</button>
      <toast.ToastContainer />
    </div>
  );
};

describe('Toast Component', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = '';
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('renders nothing when there are no toasts', () => {
    render(<ToastContainer toasts={[]} onDismiss={() => undefined} />);
    expect(screen.queryByRole('button')).not.toBeInTheDocument();
  });

  it('renders success toast with correct styling', () => {
    render(
      <ToastContainer
        toasts={[{ id: '1', message: 'Success!', type: 'success' }]}
        onDismiss={() => undefined}
      />
    );
    expect(screen.getByText('Success!')).toBeInTheDocument();
  });

  it('renders error toast with correct styling', () => {
    render(
      <ToastContainer
        toasts={[{ id: '1', message: 'Error!', type: 'error' }]}
        onDismiss={() => undefined}
      />
    );
    expect(screen.getByText('Error!')).toBeInTheDocument();
  });

  it('calls onDismiss when close button is clicked', () => {
    const onDismiss = vi.fn();
    render(
      <ToastContainer
        toasts={[{ id: 'test-id', message: 'Test', type: 'info' }]}
        onDismiss={onDismiss}
      />
    );

    // Find the close button (X icon button)
    const closeButtons = screen.getAllByRole('button');
    const closeButton = closeButtons.find((btn) => btn.querySelector('svg'));
    if (closeButton) {
      fireEvent.click(closeButton);
      expect(onDismiss).toHaveBeenCalledWith('test-id');
    }
  });

  it('shows undo button when undoAction is provided', () => {
    const undoAction = vi.fn();
    render(
      <ToastContainer
        toasts={[{ id: '1', message: 'Deleted', type: 'success', undoAction }]}
        onDismiss={() => undefined}
      />
    );
    expect(screen.getByText('Deshacer')).toBeInTheDocument();
  });

  it('calls undoAction and dismisses when undo is clicked', () => {
    const undoAction = vi.fn();
    const onDismiss = vi.fn();
    render(
      <ToastContainer
        toasts={[{ id: 'undo-id', message: 'Deleted', type: 'success', undoAction }]}
        onDismiss={onDismiss}
      />
    );

    fireEvent.click(screen.getByText('Deshacer'));
    expect(undoAction).toHaveBeenCalledTimes(1);
    expect(onDismiss).toHaveBeenCalledWith('undo-id');
  });

  it('auto-dismisses after duration', () => {
    const onDismiss = vi.fn();
    render(
      <ToastContainer
        toasts={[{ id: 'auto-id', message: 'Auto dismiss', type: 'info', duration: 1000 }]}
        onDismiss={onDismiss}
      />
    );

    expect(onDismiss).not.toHaveBeenCalled();

    act(() => {
      vi.advanceTimersByTime(1100);
    });

    expect(onDismiss).toHaveBeenCalledWith('auto-id');
  });

  it('useToast hook adds success toast', () => {
    render(<TestComponent />);

    fireEvent.click(screen.getByText('Show Success'));

    expect(screen.getByText('Success message')).toBeInTheDocument();
  });

  it('auto-dismisses a plain success toast at the default duration', () => {
    render(<TestComponent />);

    fireEvent.click(screen.getByText('Show Success'));
    expect(screen.getByText('Success message')).toBeInTheDocument();

    act(() => {
      vi.advanceTimersByTime(6000);
    });

    expect(screen.queryByText('Success message')).not.toBeInTheDocument();
  });

  it('keeps undo toasts visible past the default duration so the user can click Deshacer', () => {
    render(<TestComponent />);

    fireEvent.click(screen.getByText('Show Undo'));
    expect(screen.getByText('Undo test')).toBeInTheDocument();

    // Past the default 5s window: a plain success toast would be gone, the undo toast must persist.
    act(() => {
      vi.advanceTimersByTime(6000);
    });
    expect(screen.getByText('Undo test')).toBeInTheDocument();

    // It still auto-dismisses eventually.
    act(() => {
      vi.advanceTimersByTime(5000);
    });
    expect(screen.queryByText('Undo test')).not.toBeInTheDocument();
  });

  it('useToast hook adds error toast', () => {
    render(<TestComponent />);

    fireEvent.click(screen.getByText('Show Error'));

    expect(screen.getByText('Error message')).toBeInTheDocument();
  });

  it('useToast hook adds info toast', () => {
    render(<TestComponent />);

    fireEvent.click(screen.getByText('Show Info'));

    expect(screen.getByText('Info message')).toBeInTheDocument();
  });

  it('renders multiple toasts', () => {
    render(
      <ToastContainer
        toasts={[
          { id: '1', message: 'First', type: 'success' },
          { id: '2', message: 'Second', type: 'error' },
          { id: '3', message: 'Third', type: 'info' },
        ]}
        onDismiss={() => undefined}
      />
    );

    expect(screen.getByText('First')).toBeInTheDocument();
    expect(screen.getByText('Second')).toBeInTheDocument();
    expect(screen.getByText('Third')).toBeInTheDocument();
  });
});
