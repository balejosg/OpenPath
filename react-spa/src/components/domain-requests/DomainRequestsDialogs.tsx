import type { DomainRequestsDialogsModel } from '../../hooks/useDomainRequestsViewModel';
import { ConfirmDialog, DangerConfirmDialog } from '../ui/ConfirmDialog';

interface DomainRequestsDialogsProps {
  model: DomainRequestsDialogsModel;
}

export function DomainRequestsDialogs({ model }: DomainRequestsDialogsProps) {
  return (
    <>
      {model.bulkConfirm ? (
        model.bulkConfirm.mode === 'approve' ? (
          <ConfirmDialog
            isOpen
            title="Approve requests"
            confirmLabel="Approve"
            cancelLabel="Cancel"
            disableConfirm={model.bulkConfirm.requestIds.length === 0}
            onClose={model.onBulkConfirmClose}
            onConfirm={() => {
              void model.onBulkApproveConfirm(model.bulkConfirm?.requestIds ?? []);
            }}
          >
            <p className="text-sm text-slate-600">
              Approve {model.bulkConfirm.requestIds.length} selected requests?
            </p>
            <p className="text-xs text-slate-500">
              Requests will be approved in their original groups.
            </p>
          </ConfirmDialog>
        ) : (
          <DangerConfirmDialog
            isOpen
            title="Reject requests"
            confirmLabel="Reject"
            cancelLabel="Cancel"
            disableConfirm={model.bulkConfirm.requestIds.length === 0}
            onClose={model.onBulkConfirmClose}
            onConfirm={() => {
              void model.onBulkRejectConfirm(
                model.bulkConfirm?.requestIds ?? [],
                model.bulkConfirm?.rejectReason
              );
            }}
          >
            <p className="text-sm text-slate-600">
              Reject {model.bulkConfirm.requestIds.length} selected requests?
            </p>
            {model.bulkConfirm.rejectReason ? (
              <p className="text-xs text-slate-500 break-words">
                Reason (optional):{' '}
                <span className="font-medium">{model.bulkConfirm.rejectReason}</span>
              </p>
            ) : (
              <p className="text-xs text-slate-500">Reason (optional): (no reason)</p>
            )}
          </DangerConfirmDialog>
        )
      ) : null}

      {model.approveModal.open && model.approveModal.request && (
        <ConfirmDialog
          isOpen
          title="Approve Request"
          confirmLabel="Approve"
          cancelLabel="Cancel"
          isLoading={model.actionsLoading}
          onClose={model.onApproveClose}
          onConfirm={model.onApproveConfirm}
        >
          <p className="text-sm text-slate-600">
            Approve access to <strong>{model.approveModal.request.domain}</strong> requested by{' '}
            <strong>{model.approveModal.request.machineHostname}</strong>
          </p>
          <p className="text-sm text-slate-600">
            The request will be approved in the original group:{' '}
            <strong>{model.approveModal.request.groupName}</strong>
          </p>
        </ConfirmDialog>
      )}

      {model.rejectModal.open && model.rejectModal.request && (
        <DangerConfirmDialog
          isOpen
          title="Reject Request"
          confirmLabel="Reject"
          cancelLabel="Cancel"
          isLoading={model.actionsLoading}
          onClose={model.onRejectClose}
          onConfirm={model.onRejectConfirm}
        >
          <p className="text-sm text-slate-600">
            Reject access to <strong>{model.rejectModal.request.domain}</strong> requested by{' '}
            <strong>{model.rejectModal.request.machineHostname}</strong>
          </p>

          <div>
            <label className="block text-sm font-medium text-slate-700 mb-1">
              Rejection reason (optional)
            </label>
            <textarea
              value={model.rejectionReason}
              onChange={(event) => model.onRejectReasonChange(event.target.value)}
              placeholder="Explain why this request is rejected..."
              rows={3}
              className="w-full px-3 py-2 border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-none"
            />
          </div>
        </DangerConfirmDialog>
      )}

      {model.deleteModal.open && model.deleteModal.request && (
        <DangerConfirmDialog
          isOpen
          title="Delete Request"
          confirmLabel="Delete"
          cancelLabel="Cancel"
          isLoading={model.actionsLoading}
          onClose={model.onDeleteClose}
          onConfirm={model.onDeleteConfirm}
        >
          <p className="text-sm text-slate-600">
            Delete the access request for <strong>{model.deleteModal.request.domain}</strong>?
          </p>
          <p className="text-xs text-slate-500">This action cannot be undone.</p>
        </DangerConfirmDialog>
      )}
    </>
  );
}
