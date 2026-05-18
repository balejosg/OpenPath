import { fireEvent, render, screen, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { DomainRequestsDialogsModel } from '../../../hooks/useDomainRequestsViewModel';
import { DomainRequestsDialogs } from '../DomainRequestsDialogs';

const request = {
  domain: 'example.com',
  machineHostname: 'host-1',
  groupName: 'Grupo 1',
} as const;

function buildModel(
  overrides: Partial<DomainRequestsDialogsModel> = {}
): DomainRequestsDialogsModel {
  return {
    bulkConfirm: null,
    approveModal: { open: false, request: null },
    rejectModal: { open: false, request: null },
    deleteModal: { open: false, request: null },
    rejectionReason: '',
    actionsLoading: false,
    onBulkConfirmClose: vi.fn(),
    onBulkApproveConfirm: vi.fn(),
    onBulkRejectConfirm: vi.fn(),
    onApproveClose: vi.fn(),
    onApproveConfirm: vi.fn(),
    onRejectClose: vi.fn(),
    onRejectConfirm: vi.fn(),
    onRejectReasonChange: vi.fn(),
    onDeleteClose: vi.fn(),
    onDeleteConfirm: vi.fn(),
    ...overrides,
  };
}

describe('DomainRequestsDialogs', () => {
  it('confirms bulk approvals and propagates single-request rejection input', () => {
    const onBulkApproveConfirm = vi.fn();
    const onRejectReasonChange = vi.fn();

    render(
      <DomainRequestsDialogs
        model={buildModel({
          bulkConfirm: { mode: 'approve', requestIds: ['req-1', 'req-2'] },
          rejectModal: { open: true, request },
          onBulkApproveConfirm,
          onRejectReasonChange,
        })}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: 'Approve' }));
    fireEvent.change(screen.getByPlaceholderText('Explain why this request is rejected...'), {
      target: { value: 'No aplica' },
    });

    expect(onBulkApproveConfirm).toHaveBeenCalledWith(['req-1', 'req-2']);
    expect(onRejectReasonChange).toHaveBeenCalledWith('No aplica');
  });

  it('disables empty bulk approvals and closes the confirmation dialog', () => {
    const onBulkApproveConfirm = vi.fn();
    const onBulkConfirmClose = vi.fn();

    render(
      <DomainRequestsDialogs
        model={buildModel({
          bulkConfirm: { mode: 'approve', requestIds: [] },
          onBulkApproveConfirm,
          onBulkConfirmClose,
        })}
      />
    );

    const dialog = screen.getByRole('dialog', { name: 'Approve requests' });
    expect(within(dialog).getByRole('button', { name: 'Approve' })).toBeDisabled();

    fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }));

    expect(onBulkApproveConfirm).not.toHaveBeenCalled();
    expect(onBulkConfirmClose).toHaveBeenCalled();
  });

  it('confirms bulk rejections with and without a reason', () => {
    const onBulkRejectConfirm = vi.fn();
    const { rerender } = render(
      <DomainRequestsDialogs
        model={buildModel({
          bulkConfirm: {
            mode: 'reject',
            requestIds: ['req-1', 'req-2'],
            rejectReason: 'Duplicado',
          },
          onBulkRejectConfirm,
        })}
      />
    );

    let dialog = screen.getByRole('dialog', { name: 'Reject requests' });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Reject' }));

    expect(screen.getByText('Duplicado')).toBeInTheDocument();
    expect(onBulkRejectConfirm).toHaveBeenCalledWith(['req-1', 'req-2'], 'Duplicado');

    rerender(
      <DomainRequestsDialogs
        model={buildModel({
          bulkConfirm: { mode: 'reject', requestIds: ['req-3'] },
          onBulkRejectConfirm,
        })}
      />
    );

    dialog = screen.getByRole('dialog', { name: 'Reject requests' });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Reject' }));

    expect(screen.getByText('Reason (optional): (no reason)')).toBeInTheDocument();
    expect(onBulkRejectConfirm).toHaveBeenLastCalledWith(['req-3'], undefined);
  });

  it('confirms single approve and delete dialogs', () => {
    const onApproveConfirm = vi.fn();
    const onDeleteConfirm = vi.fn();
    const onDeleteClose = vi.fn();

    render(
      <DomainRequestsDialogs
        model={buildModel({
          approveModal: { open: true, request },
          deleteModal: { open: true, request },
          onApproveConfirm,
          onDeleteConfirm,
          onDeleteClose,
        })}
      />
    );

    fireEvent.click(
      within(screen.getByRole('dialog', { name: 'Approve Request' })).getByRole('button', {
        name: 'Approve',
      })
    );
    fireEvent.click(
      within(screen.getByRole('dialog', { name: 'Delete Request' })).getByRole('button', {
        name: 'Delete',
      })
    );
    fireEvent.click(
      within(screen.getByRole('dialog', { name: 'Delete Request' })).getByRole('button', {
        name: 'Cancel',
      })
    );

    expect(screen.getByText('This action cannot be undone.')).toBeInTheDocument();
    expect(onApproveConfirm).toHaveBeenCalled();
    expect(onDeleteConfirm).toHaveBeenCalled();
    expect(onDeleteClose).toHaveBeenCalled();
  });
});
