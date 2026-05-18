import { AlertTriangle } from 'lucide-react';
import { DomainRequestsBulkActions } from '../components/domain-requests/DomainRequestsBulkActions';
import { DomainRequestsDialogs } from '../components/domain-requests/DomainRequestsDialogs';
import { DomainRequestsFilters } from '../components/domain-requests/DomainRequestsFilters';
import { DomainRequestsTable } from '../components/domain-requests/DomainRequestsTable';
import { useDomainRequestsViewModel } from '../hooks/useDomainRequestsViewModel';

interface DomainRequestsProps {
  canDeleteRequests?: boolean;
}

export default function DomainRequests({ canDeleteRequests = true }: DomainRequestsProps) {
  const viewModel = useDomainRequestsViewModel({ canDeleteRequests });

  return (
    <div className="space-y-6">
      <p className="text-slate-500 text-sm">Manage access requests for blocked domains</p>

      <DomainRequestsFilters
        searchInputRef={viewModel.filters.searchInputRef}
        searchTerm={viewModel.filters.searchTerm}
        statusFilter={viewModel.filters.statusFilter}
        sortBy={viewModel.filters.sortBy}
        sourceFilter={viewModel.filters.sourceFilter}
        pageSize={viewModel.filters.pageSize}
        onSearchChange={viewModel.filters.onSearchChange}
        onStatusFilterChange={viewModel.filters.onStatusFilterChange}
        onSortChange={viewModel.filters.onSortChange}
        onSourceFilterChange={viewModel.filters.onSourceFilterChange}
        onPageSizeChange={viewModel.filters.onPageSizeChange}
        onClearSearch={viewModel.filters.onClearSearch}
      />

      {!viewModel.loading && viewModel.pendingCount > 0 && (
        <div className="bg-white border border-slate-200 rounded-lg p-4 shadow-sm">
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <span className="font-medium text-slate-700">Pendientes: {viewModel.pendingCount}</span>
          </div>
        </div>
      )}

      <DomainRequestsBulkActions
        selectedCount={viewModel.bulkActions.selectedCount}
        bulkRejectReason={viewModel.bulkActions.rejectReason}
        bulkLoading={viewModel.bulkActions.loading}
        bulkProgress={viewModel.bulkActions.progress}
        bulkFailedIds={viewModel.bulkActions.failedIds}
        bulkMessage={viewModel.bulkActions.message}
        onBulkRejectReasonChange={viewModel.bulkActions.onRejectReasonChange}
        onApproveSelected={viewModel.bulkActions.onApproveSelected}
        onRejectSelected={viewModel.bulkActions.onRejectSelected}
        onClearSelection={viewModel.bulkActions.onClearSelection}
        onSelectFailed={viewModel.bulkActions.onSelectFailed}
        onRetryFailed={viewModel.bulkActions.onRetryFailed}
      />

      {viewModel.error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 flex items-center gap-3">
          <AlertTriangle className="text-red-500" size={20} />
          <span className="text-red-700">{viewModel.error}</span>
        </div>
      )}

      {viewModel.loading && (
        <div className="bg-white border border-slate-200 rounded-lg p-8 shadow-sm flex justify-center">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
        </div>
      )}

      {!viewModel.loading && !viewModel.error && <DomainRequestsTable model={viewModel.table} />}

      <DomainRequestsDialogs model={viewModel.dialogs} />
    </div>
  );
}
