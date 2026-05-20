import React, { useState } from 'react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { Modal } from '../Modal';

describe('Modal Component', () => {
  const onClose = vi.fn();

  beforeEach(() => {
    onClose.mockClear();
    // Clear document body between tests
    document.body.innerHTML = '';
    document.body.style.overflow = '';
    document.body.style.paddingRight = '';
  });

  it('renders nothing when isOpen is false', () => {
    render(
      <Modal isOpen={false} onClose={onClose}>
        Modal Content
      </Modal>
    );
    expect(screen.queryByText('Modal Content')).not.toBeInTheDocument();
  });

  it('renders content when isOpen is true', () => {
    render(
      <Modal isOpen={true} onClose={onClose} title="Modal Title">
        Modal Content
      </Modal>
    );
    expect(screen.getByText('Modal Title')).toBeInTheDocument();
    expect(screen.getByText('Modal Content')).toBeInTheDocument();
  });

  it('calls onClose when close button is clicked', () => {
    render(
      <Modal isOpen={true} onClose={onClose}>
        Modal Content
      </Modal>
    );
    const closeButton = screen.getByRole('button');
    fireEvent.click(closeButton);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('uses the default close label and default body classes', () => {
    render(
      <Modal isOpen={true} onClose={onClose} title="Default body">
        <div data-testid="modal-child">Modal Content</div>
      </Modal>
    );

    const closeButton = screen.getByRole('button', { name: 'Close' });
    expect(closeButton).toHaveAttribute('title', 'Close');

    const body = screen.getByTestId('modal-child').parentElement;
    expect(body).toHaveClass('min-h-0', 'overflow-y-auto', 'p-6');
  });

  it('uses a custom close label for accessible name and title', () => {
    render(
      <Modal isOpen={true} onClose={onClose} title="Solicitud" closeLabel="Cerrar panel">
        Modal Content
      </Modal>
    );

    const closeButton = screen.getByRole('button', { name: 'Cerrar panel' });
    expect(closeButton).toHaveAttribute('title', 'Cerrar panel');
  });

  it('lets callers own body scrolling with a custom body class name', () => {
    render(
      <Modal
        isOpen={true}
        onClose={onClose}
        title="Custom body"
        bodyClassName="flex flex-1 flex-col overflow-hidden"
      >
        <div data-testid="modal-child">Modal Content</div>
      </Modal>
    );

    const body = screen.getByTestId('modal-child').parentElement;
    expect(body).toHaveClass('min-h-0', 'flex', 'flex-1', 'flex-col', 'overflow-hidden');
    expect(body).not.toHaveClass('overflow-y-auto', 'p-6');
  });

  it('calls onClose when escape key is pressed', () => {
    render(
      <Modal isOpen={true} onClose={onClose}>
        Modal Content
      </Modal>
    );
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('locks body scroll while open and restores previous styles when closed', () => {
    document.body.style.overflow = 'auto';
    document.body.style.paddingRight = '10px';

    const { rerender } = render(
      <Modal isOpen={true} onClose={onClose}>
        Modal Content
      </Modal>
    );

    expect(document.body.style.overflow).toBe('hidden');

    rerender(
      <Modal isOpen={false} onClose={onClose}>
        Modal Content
      </Modal>
    );

    expect(document.body.style.overflow).toBe('auto');
    expect(document.body.style.paddingRight).toBe('10px');
  });

  it('keeps body scroll locked until all modals are closed', () => {
    const onCloseFirst = vi.fn();
    const onCloseSecond = vi.fn();

    const { rerender } = render(
      <>
        <Modal isOpen={true} onClose={onCloseFirst} title="First">
          First content
        </Modal>
        <Modal isOpen={true} onClose={onCloseSecond} title="Second">
          Second content
        </Modal>
      </>
    );

    expect(document.body.style.overflow).toBe('hidden');

    rerender(
      <>
        <Modal isOpen={true} onClose={onCloseFirst} title="First">
          First content
        </Modal>
        <Modal isOpen={false} onClose={onCloseSecond} title="Second">
          Second content
        </Modal>
      </>
    );

    expect(document.body.style.overflow).toBe('hidden');

    rerender(
      <>
        <Modal isOpen={false} onClose={onCloseFirst} title="First">
          First content
        </Modal>
        <Modal isOpen={false} onClose={onCloseSecond} title="Second">
          Second content
        </Modal>
      </>
    );

    expect(document.body.style.overflow).toBe('');
  });

  it('closes only the top-most modal on Escape', () => {
    const onCloseFirst = vi.fn();
    const onCloseSecond = vi.fn();

    render(
      <>
        <Modal isOpen={true} onClose={onCloseFirst} title="First">
          First content
        </Modal>
        <Modal isOpen={true} onClose={onCloseSecond} title="Second">
          Second content
        </Modal>
      </>
    );

    fireEvent.keyDown(window, { key: 'Escape' });

    expect(onCloseSecond).toHaveBeenCalledTimes(1);
    expect(onCloseFirst).toHaveBeenCalledTimes(0);
  });

  it('traps Tab focus within the modal', () => {
    render(
      <Modal isOpen={true} onClose={onClose} title="Trap">
        <button type="button">Inner</button>
      </Modal>
    );

    const closeButton = screen.getByRole('button', { name: 'Close' });
    const innerButton = screen.getByRole('button', { name: 'Inner' });

    expect(document.activeElement).toBe(closeButton);

    fireEvent.keyDown(window, { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(innerButton);

    fireEvent.keyDown(window, { key: 'Tab' });
    expect(document.activeElement).toBe(closeButton);
  });

  it('restores focus to the previously focused element when the modal closes', async () => {
    function Wrapper() {
      const [open, setOpen] = useState(false);

      return (
        <>
          <button type="button" onClick={() => setOpen(true)}>
            Open
          </button>
          <Modal isOpen={open} onClose={() => setOpen(false)} title="Title">
            Modal Content
          </Modal>
        </>
      );
    }

    render(<Wrapper />);

    const openButton = screen.getByRole('button', { name: 'Open' });
    openButton.focus();

    fireEvent.click(openButton);

    expect(screen.getByRole('button', { name: 'Close' })).toBeInTheDocument();

    fireEvent.keyDown(window, { key: 'Escape' });

    await waitFor(() => {
      expect(document.activeElement).toBe(openButton);
    });
  });
});
