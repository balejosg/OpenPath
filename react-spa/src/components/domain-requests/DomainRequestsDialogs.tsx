import type { DomainRequestsDialogsModel } from '../../hooks/useDomainRequestsViewModel';
import { useT } from '../../i18n/product-i18n';
import { ConfirmDialog, DangerConfirmDialog } from '../ui/ConfirmDialog';

interface DomainRequestsDialogsProps {
  model: DomainRequestsDialogsModel;
}

export function DomainRequestsDialogs({ model }: DomainRequestsDialogsProps) {
  const t = useT();

  return (
    <>
      {model.bulkConfirm ? (
        model.bulkConfirm.mode === 'approve' ? (
          <ConfirmDialog
            isOpen
            title={t('domainRequests.dialogs.approveRequestsTitle')}
            confirmLabel={t('domainRequests.table.approve')}
            cancelLabel={t('common.cancel')}
            disableConfirm={model.bulkConfirm.requestIds.length === 0}
            onClose={model.onBulkConfirmClose}
            onConfirm={() => {
              void model.onBulkApproveConfirm(model.bulkConfirm?.requestIds ?? []);
            }}
          >
            <p className="text-sm text-slate-600">
              {t('domainRequests.dialogs.approveSelected', {
                count: model.bulkConfirm.requestIds.length,
              })}
            </p>
            <p className="text-xs text-slate-500">
              {t('domainRequests.dialogs.approveOriginalGroups')}
            </p>
          </ConfirmDialog>
        ) : (
          <DangerConfirmDialog
            isOpen
            title={t('domainRequests.dialogs.rejectRequestsTitle')}
            confirmLabel={t('domainRequests.table.reject')}
            cancelLabel={t('common.cancel')}
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
              {t('domainRequests.dialogs.rejectSelected', {
                count: model.bulkConfirm.requestIds.length,
              })}
            </p>
            {model.bulkConfirm.rejectReason ? (
              <p className="text-xs text-slate-500 break-words">
                {t('domainRequests.dialogs.rejectReason')}{' '}
                <span className="font-medium">{model.bulkConfirm.rejectReason}</span>
              </p>
            ) : (
              <p className="text-xs text-slate-500">
                {t('domainRequests.dialogs.rejectReason')} {t('domainRequests.dialogs.noReason')}
              </p>
            )}
          </DangerConfirmDialog>
        )
      ) : null}

      {model.approveModal.open && model.approveModal.request && (
        <ConfirmDialog
          isOpen
          title={t('domainRequests.dialogs.approveRequestTitle')}
          confirmLabel={t('domainRequests.table.approve')}
          cancelLabel={t('common.cancel')}
          isLoading={model.actionsLoading}
          onClose={model.onApproveClose}
          onConfirm={model.onApproveConfirm}
        >
          <p className="text-sm text-slate-600">
            {t('domainRequests.dialogs.approveAccess', {
              domain: model.approveModal.request.domain,
              machine: model.approveModal.request.machineHostname,
            })}
          </p>
          <p className="text-sm text-slate-600">
            {t('domainRequests.dialogs.originalGroup', {
              group: model.approveModal.request.groupName,
            })}
          </p>
        </ConfirmDialog>
      )}

      {model.rejectModal.open && model.rejectModal.request && (
        <DangerConfirmDialog
          isOpen
          title={t('domainRequests.dialogs.rejectRequestTitle')}
          confirmLabel={t('domainRequests.table.reject')}
          cancelLabel={t('common.cancel')}
          isLoading={model.actionsLoading}
          onClose={model.onRejectClose}
          onConfirm={model.onRejectConfirm}
        >
          <p className="text-sm text-slate-600">
            {t('domainRequests.dialogs.rejectAccess', {
              domain: model.rejectModal.request.domain,
              machine: model.rejectModal.request.machineHostname,
            })}
          </p>

          <div>
            <label className="block text-sm font-medium text-slate-700 mb-1">
              {t('domainRequests.dialogs.rejectionReasonLabel')}
            </label>
            <textarea
              value={model.rejectionReason}
              onChange={(event) => model.onRejectReasonChange(event.target.value)}
              placeholder={t('domainRequests.dialogs.rejectionReasonPlaceholder')}
              rows={3}
              className="w-full px-3 py-2 border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-none"
            />
          </div>
        </DangerConfirmDialog>
      )}

      {model.deleteModal.open && model.deleteModal.request && (
        <DangerConfirmDialog
          isOpen
          title={t('domainRequests.dialogs.deleteRequestTitle')}
          confirmLabel={t('domainRequests.table.delete')}
          cancelLabel={t('common.cancel')}
          isLoading={model.actionsLoading}
          onClose={model.onDeleteClose}
          onConfirm={model.onDeleteConfirm}
        >
          <p className="text-sm text-slate-600">
            {t('domainRequests.dialogs.deleteAccess', {
              domain: model.deleteModal.request.domain,
            })}
          </p>
          <p className="text-xs text-slate-500">
            {t('common.dialog.destructiveActionCannotBeUndone')}
          </p>
        </DangerConfirmDialog>
      )}
    </>
  );
}
