import { getRootDomain } from '@openpath/shared/domain';
import type { DomainRequestsDialogsModel } from '../../hooks/useDomainRequestsViewModel';
import { useT } from '../../i18n/product-i18n';
import { ConfirmDialog, DangerConfirmDialog } from '../ui/ConfirmDialog';

interface DomainRequestsDialogsProps {
  model: DomainRequestsDialogsModel;
}

export function DomainRequestsDialogs({ model }: DomainRequestsDialogsProps) {
  const t = useT();
  const approveRequest = model.approveModal.request;
  const blockCause = approveRequest?.blockCause;
  const blockedRule = blockCause?.kind === 'blocked_by_rule' ? blockCause.matchedRule : null;
  const alreadyAllowedRule = blockCause?.kind === 'already_allowed' ? blockCause.matchedRule : null;
  const approvalRoot = approveRequest ? getRootDomain(approveRequest.domain) : '';
  const disableApprove = blockedRule !== null && !model.approveUnblock;

  return (
    <>
      {model.bulkConfirm ? (
        model.bulkConfirm.mode === 'approve' ? (
          <ConfirmDialog
            isOpen
            title={t('domainRequests.dialogs.approveRequestsTitle')}
            confirmLabel={t('common.confirm')}
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
            confirmLabel={t('common.confirm')}
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

      {model.approveModal.open && approveRequest && (
        <ConfirmDialog
          isOpen
          title={t('domainRequests.dialogs.approveRequestTitle')}
          confirmLabel={t('common.confirm')}
          cancelLabel={t('common.cancel')}
          isLoading={model.actionsLoading}
          disableConfirm={disableApprove}
          onClose={model.onApproveClose}
          onConfirm={model.onApproveConfirm}
        >
          <p className="text-sm text-slate-600">
            {t('domainRequests.dialogs.approveAccess', {
              domain: approveRequest.domain,
              machine: approveRequest.machineHostname,
            })}
          </p>
          <p className="text-sm text-slate-600">
            {t('domainRequests.dialogs.originalGroup', {
              group: approveRequest.groupName,
            })}
          </p>

          <fieldset className="space-y-2">
            <legend className="text-sm font-medium text-slate-700">
              {t('domainRequests.dialogs.approvalScope')}
            </legend>
            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input
                type="radio"
                name="approval-scope"
                checked={model.approveScope === 'host'}
                onChange={() => model.onApproveScopeChange('host')}
              />
              <span>{t('domainRequests.dialogs.scopeHost', { host: approveRequest.domain })}</span>
            </label>
            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input
                type="radio"
                name="approval-scope"
                checked={model.approveScope === 'family'}
                onChange={() => model.onApproveScopeChange('family')}
              />
              <span>{t('domainRequests.dialogs.scopeFamily', { root: approvalRoot })}</span>
            </label>
          </fieldset>

          {blockedRule ? (
            <div className="space-y-2">
              <p className="text-sm text-red-700">
                {t('domainRequests.dialogs.blockedByRuleWarning', { rule: blockedRule })}
              </p>
              <label className="flex items-center gap-2 text-sm text-red-700">
                <input
                  type="checkbox"
                  checked={model.approveUnblock}
                  onChange={(event) => model.onApproveUnblockChange(event.target.checked)}
                />
                <span>
                  {t('domainRequests.dialogs.blockedByRuleUnblock', {
                    rule: blockedRule,
                  })}
                </span>
              </label>
            </div>
          ) : null}

          {alreadyAllowedRule ? (
            <p className="text-sm text-amber-700">
              {t('domainRequests.dialogs.alreadyAllowedWarning', {
                rule: alreadyAllowedRule,
              })}
            </p>
          ) : null}
        </ConfirmDialog>
      )}

      {model.rejectModal.open && model.rejectModal.request && (
        <DangerConfirmDialog
          isOpen
          title={t('domainRequests.dialogs.rejectRequestTitle')}
          confirmLabel={t('common.confirm')}
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
