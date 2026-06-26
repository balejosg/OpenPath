import { CheckCircle } from 'lucide-react';
import { useT } from '../../i18n/product-i18n';

interface BulkProgress {
  mode: 'approve' | 'reject';
  done: number;
  total: number;
}

interface DomainRequestsBulkActionsProps {
  selectedCount: number;
  bulkRejectReason: string;
  bulkLoading: boolean;
  bulkProgress: BulkProgress | null;
  bulkFailedIds: string[];
  bulkMessage: string | null;
  onBulkRejectReasonChange: (value: string) => void;
  onApproveSelected: () => void;
  onRejectSelected: () => void;
  onClearSelection: () => void;
  onSelectFailed: () => void;
  onRetryFailed: () => void;
}

export function DomainRequestsBulkActions({
  selectedCount,
  bulkRejectReason,
  bulkLoading,
  bulkProgress,
  bulkFailedIds,
  bulkMessage,
  onBulkRejectReasonChange,
  onApproveSelected,
  onRejectSelected,
  onClearSelection,
  onSelectFailed,
  onRetryFailed,
}: DomainRequestsBulkActionsProps) {
  const t = useT();
  return (
    <>
      {selectedCount > 0 && (
        <div className="bg-blue-50 border border-blue-200 rounded-lg p-4 space-y-3">
          <div className="text-sm text-blue-900 font-medium">
            {t('domainRequests.bulk.selectedCount', { count: selectedCount })}
          </div>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            <input
              type="text"
              value={bulkRejectReason}
              onChange={(event) => onBulkRejectReasonChange(event.target.value)}
              placeholder={t('domainRequests.bulk.rejectReasonPlaceholder')}
              className="px-3 py-2 border border-blue-200 rounded-lg bg-white focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div className="flex items-center gap-2">
            <button
              onClick={onApproveSelected}
              disabled={bulkLoading}
              className="px-3 py-2 bg-green-600 hover:bg-green-700 text-white text-sm rounded-lg disabled:opacity-50"
            >
              {bulkLoading ? t('common.processing') : t('domainRequests.bulk.approveSelected')}
            </button>
            <button
              onClick={onRejectSelected}
              disabled={bulkLoading}
              className="px-3 py-2 bg-red-600 hover:bg-red-700 text-white text-sm rounded-lg disabled:opacity-50"
            >
              {bulkLoading ? t('common.processing') : t('domainRequests.bulk.rejectSelected')}
            </button>
            <button
              onClick={onClearSelection}
              disabled={bulkLoading}
              className="px-3 py-2 bg-white border border-slate-300 text-slate-700 text-sm rounded-lg disabled:opacity-50"
            >
              {t('domainRequests.bulk.clearSelection')}
            </button>
          </div>
          {bulkProgress && (
            <div className="space-y-1">
              <div className="flex items-center justify-between text-xs text-blue-900">
                <span>
                  {bulkProgress.mode === 'approve'
                    ? t('domainRequests.bulk.approvalInProgress')
                    : t('domainRequests.bulk.rejectionInProgress')}
                </span>
                <span>
                  {bulkProgress.done}/{bulkProgress.total}
                </span>
              </div>
              <div className="w-full h-2 bg-blue-100 rounded-full overflow-hidden">
                <div
                  className="h-full bg-blue-600"
                  style={{
                    width: `${Math.round((bulkProgress.done / Math.max(1, bulkProgress.total)) * 100)}%`,
                  }}
                />
              </div>
            </div>
          )}
          {bulkFailedIds.length > 0 && (
            <div className="flex items-center gap-2 text-xs">
              <span className="text-red-700">
                {t('domainRequests.bulk.failedCount', { count: bulkFailedIds.length })}
              </span>
              <button
                onClick={onSelectFailed}
                disabled={bulkLoading}
                className="px-2 py-1 bg-white border border-red-300 text-red-700 rounded disabled:opacity-50"
              >
                {t('domainRequests.bulk.selectFailed')}
              </button>
              <button
                onClick={onRetryFailed}
                disabled={bulkLoading}
                className="px-2 py-1 bg-red-600 hover:bg-red-700 text-white rounded disabled:opacity-50"
              >
                {t('domainRequests.bulk.retryFailed')}
              </button>
            </div>
          )}
        </div>
      )}

      {bulkMessage && (
        <div className="bg-green-50 border border-green-200 rounded-lg p-4 flex items-center gap-3">
          <CheckCircle className="text-green-600" size={20} />
          <span className="text-green-800 text-sm">{bulkMessage}</span>
        </div>
      )}
    </>
  );
}
