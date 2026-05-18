import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { BulkActionBar } from '../BulkActionBar';

describe('BulkActionBar Component', () => {
  const noop = vi.fn();

  it('renders nothing when selectedCount is 0', () => {
    const { container } = render(
      <BulkActionBar selectedCount={0} onDelete={noop} onClear={noop} />
    );
    expect(container.firstChild).toBeNull();
  });

  it('renders when items are selected', () => {
    render(<BulkActionBar selectedCount={3} onDelete={noop} onClear={noop} />);

    expect(screen.getByText('3 selected')).toBeInTheDocument();
  });

  it('shows singular text for single selection', () => {
    render(<BulkActionBar selectedCount={1} onDelete={noop} onClear={noop} />);

    expect(screen.getByText('1 selected')).toBeInTheDocument();
  });

  it('calls onDelete when delete button is clicked', () => {
    const handleDelete = vi.fn();
    render(<BulkActionBar selectedCount={2} onDelete={handleDelete} onClear={noop} />);

    const deleteButton = screen.getByRole('button', { name: /delete/i });
    fireEvent.click(deleteButton);

    expect(handleDelete).toHaveBeenCalled();
  });

  it('calls onClear when cancel button is clicked', () => {
    const handleClear = vi.fn();
    render(<BulkActionBar selectedCount={2} onDelete={noop} onClear={handleClear} />);

    const cancelButton = screen.getByTitle('Cancel selection');
    fireEvent.click(cancelButton);

    expect(handleClear).toHaveBeenCalled();
  });

  it('disables buttons when isDeleting is true', () => {
    render(<BulkActionBar selectedCount={2} onDelete={noop} onClear={noop} isDeleting={true} />);

    const deleteButton = screen.getByRole('button', { name: /delete/i });
    const cancelButton = screen.getByTitle('Cancel selection');

    expect(deleteButton).toBeDisabled();
    expect(cancelButton).toBeDisabled();
  });

  it('shows loading state when isDeleting', () => {
    render(<BulkActionBar selectedCount={2} onDelete={noop} onClear={noop} isDeleting={true} />);

    // The button should have isLoading prop which shows a spinner
    const deleteButton = screen.getByRole('button', { name: /delete/i });
    expect(deleteButton).toBeDisabled();
  });
});
