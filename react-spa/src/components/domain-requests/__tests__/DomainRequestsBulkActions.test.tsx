import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { DomainRequestsBulkActions } from '../DomainRequestsBulkActions';

describe('DomainRequestsBulkActions', () => {
  it('renders bulk controls and forwards button/input actions', () => {
    const onBulkRejectReasonChange = vi.fn();
    const onApproveSelected = vi.fn();
    const onRejectSelected = vi.fn();
    const onClearSelection = vi.fn();
    const onSelectFailed = vi.fn();
    const onRetryFailed = vi.fn();

    render(
      <DomainRequestsBulkActions
        selectedCount={2}
        bulkRejectReason=""
        bulkLoading={false}
        bulkProgress={{ mode: 'approve', done: 1, total: 2 }}
        bulkFailedIds={['req-2']}
        bulkMessage="Aprobadas 1. Fallaron 1."
        onBulkRejectReasonChange={onBulkRejectReasonChange}
        onApproveSelected={onApproveSelected}
        onRejectSelected={onRejectSelected}
        onClearSelection={onClearSelection}
        onSelectFailed={onSelectFailed}
        onRetryFailed={onRetryFailed}
      />
    );

    fireEvent.change(screen.getByPlaceholderText('Bulk rejection reason (optional)'), {
      target: { value: 'No procede' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Approve selected' }));
    fireEvent.click(screen.getByRole('button', { name: 'Reject selected' }));
    fireEvent.click(screen.getByRole('button', { name: 'Clear selection' }));
    fireEvent.click(screen.getByRole('button', { name: 'Select failed' }));
    fireEvent.click(screen.getByRole('button', { name: 'Retry failed' }));

    expect(onBulkRejectReasonChange).toHaveBeenCalledWith('No procede');
    expect(onApproveSelected).toHaveBeenCalled();
    expect(onRejectSelected).toHaveBeenCalled();
    expect(onClearSelection).toHaveBeenCalled();
    expect(onSelectFailed).toHaveBeenCalled();
    expect(onRetryFailed).toHaveBeenCalled();
    expect(screen.getByText('Aprobadas 1. Fallaron 1.')).toBeInTheDocument();
  });

  it('renders reject progress and API failure messages', () => {
    render(
      <DomainRequestsBulkActions
        selectedCount={3}
        bulkRejectReason=""
        bulkLoading
        bulkProgress={{ mode: 'reject', done: 2, total: 3 }}
        bulkFailedIds={['req-2']}
        bulkFailures={[
          { id: 'req-2', message: 'This domain is explicitly blocked by rule *.google.com' },
        ]}
        bulkMessage={null}
        onBulkRejectReasonChange={vi.fn()}
        onApproveSelected={vi.fn()}
        onRejectSelected={vi.fn()}
        onClearSelection={vi.fn()}
        onSelectFailed={vi.fn()}
        onRetryFailed={vi.fn()}
      />
    );

    expect(screen.getByText('Bulk rejection in progress...')).toBeInTheDocument();
    expect(
      screen.getByText('This domain is explicitly blocked by rule *.google.com')
    ).toBeInTheDocument();
  });
});
