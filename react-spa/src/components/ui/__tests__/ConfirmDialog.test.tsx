import { describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/react';

import { ConfirmDialog } from '../ConfirmDialog';

describe('ConfirmDialog', () => {
  it('renders title and body and calls handlers', () => {
    const onClose = vi.fn();
    const onConfirm = vi.fn();

    render(
      <ConfirmDialog isOpen title="Delete" onClose={onClose} onConfirm={onConfirm}>
        <p>Seguro?</p>
      </ConfirmDialog>
    );

    expect(screen.getByText('Delete')).toBeInTheDocument();
    expect(screen.getByText('Seguro?')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(onClose).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: 'Confirm' }));
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });

  it('shows an error message when provided', () => {
    render(
      <ConfirmDialog
        isOpen
        title="Delete"
        onClose={() => undefined}
        onConfirm={() => undefined}
        errorMessage="Fallo"
      />
    );

    expect(screen.getByRole('alert')).toHaveTextContent('Fallo');
  });

  it('prevents closing while loading', () => {
    const onClose = vi.fn();
    render(
      <ConfirmDialog isOpen title="Delete" onClose={onClose} onConfirm={() => undefined} isLoading>
        <p>Seguro?</p>
      </ConfirmDialog>
    );

    fireEvent.keyDown(window, { key: 'Escape' });
    expect(onClose).not.toHaveBeenCalled();

    const cancel = screen.getByRole('button', { name: 'Cancel' });
    expect(cancel).toBeDisabled();
  });
});
