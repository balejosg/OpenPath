import { useRef, useState } from 'react';
import type { DomainRequest, RequestStatus } from '@openpath/api';
import { STATUS_COLORS } from '../views/domain-requests.constants';
import { useDomainRequestsBulkActions } from './useDomainRequestsBulkActions';
import { useDomainRequestsData } from './useDomainRequestsData';
import { useDomainRequestsDialogs } from './useDomainRequestsDialogs';
import {
  useDomainRequestsState,
  type SortOption,
  type SourceFilter,
} from './useDomainRequestsState';
import { useOpenPathI18n } from '../i18n/product-i18n';

interface UseDomainRequestsViewModelOptions {
  canDeleteRequests: boolean;
}

type EmptyState = 'no-requests' | 'no-filter-results';

interface DialogRequestViewModel {
  domain: string;
  groupName: string;
  machineHostname: string;
}

export interface DomainRequestsRowViewModel {
  id: string;
  domain: string;
  reason: string | null;
  machineHostname: string;
  groupName: string;
  status: RequestStatus;
  statusLabel: string;
  statusClassName: string;
  sourceSummary: string;
  formattedCreatedAt: string;
  selected: boolean;
  selectable: boolean;
  reviewable: boolean;
}

export function useDomainRequestsViewModel({
  canDeleteRequests,
}: UseDomainRequestsViewModelOptions) {
  const { locale, t } = useOpenPathI18n();
  const searchInputRef = useRef<HTMLInputElement>(null);
  const [statusFilter, setStatusFilter] = useState<RequestStatus | 'all'>('all');

  const data = useDomainRequestsData(statusFilter);
  const state = useDomainRequestsState({
    requests: data.requests,
    groups: data.groups,
    statusFilter,
  });

  const bulkActions = useDomainRequestsBulkActions({
    requests: data.requests,
    selectedPendingRequests: state.selectedPendingRequests,
    setSelectedRequestIds: state.setSelectedRequestIds,
    approveRequest: data.approveRequest,
    rejectRequest: data.rejectRequest,
  });

  const dialogs = useDomainRequestsDialogs({
    approveRequest: data.approveRequest,
    rejectRequest: data.rejectRequest,
    deleteRequest: data.deleteRequest,
  });

  const loading = data.loading || data.fetching;

  const formatDate = (dateStr: string) =>
    new Date(dateStr).toLocaleDateString(locale, {
      day: '2-digit',
      month: 'short',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });

  const getRequestById = (requestId: string) =>
    data.requests.find((request) => request.id === requestId) ?? null;

  const getStatusLabel = (status: RequestStatus) => {
    switch (status) {
      case 'pending':
        return t('domainRequests.status.pending');
      case 'approved':
        return t('domainRequests.status.approved');
      case 'rejected':
        return t('domainRequests.status.rejected');
    }
  };

  const toDialogRequest = (request: DomainRequest | null): DialogRequestViewModel | null => {
    if (!request) return null;
    return {
      domain: request.domain,
      groupName: state.getGroupName(request.groupId),
      machineHostname: request.machineHostname ?? t('domainRequests.machine.unknown'),
    };
  };

  const clearSearch = () => {
    state.setSearchTerm('');
    if (searchInputRef.current) {
      searchInputRef.current.value = '';
      searchInputRef.current.focus();
    }
  };

  const clearFilters = () => {
    setStatusFilter('all');
    state.setSourceFilter('all');
    clearSearch();
  };

  const setPage = (updater: number | ((page: number) => number)) => {
    state.setCurrentPage((page) => (typeof updater === 'function' ? updater(page) : updater));
  };

  const rows: DomainRequestsRowViewModel[] = state.paginatedRequests.map((request) => {
    const source = request.source ?? 'manual';
    const sourceSummary =
      source === 'firefox-extension'
        ? `${t('domainRequests.source.firefox')}${request.clientVersion ? ` v${request.clientVersion}` : ''}`
        : t('domainRequests.source.manual');
    const metadata = [
      sourceSummary,
      request.originHost ? t('domainRequests.source.origin', { origin: request.originHost }) : null,
      request.machineHostname
        ? t('domainRequests.source.host', { host: request.machineHostname })
        : null,
      request.errorType ? t('domainRequests.source.error', { error: request.errorType }) : null,
    ].filter(Boolean);

    return {
      id: request.id,
      domain: request.domain,
      reason: request.reason,
      machineHostname: request.machineHostname ?? '—',
      groupName: state.getGroupName(request.groupId),
      status: request.status,
      statusLabel: getStatusLabel(request.status),
      statusClassName: STATUS_COLORS[request.status],
      sourceSummary: metadata.join(' · '),
      formattedCreatedAt: formatDate(request.createdAt),
      selected: state.selectedRequestIds.includes(request.id),
      selectable: request.status === 'pending',
      reviewable: request.status === 'pending',
    };
  });

  const emptyState: EmptyState | null =
    state.filteredRequests.length === 0
      ? state.hasActiveFilters
        ? 'no-filter-results'
        : 'no-requests'
      : null;

  return {
    loading,
    error: data.error,
    pendingCount: state.pendingCount,
    filters: {
      searchInputRef,
      searchTerm: state.searchTerm,
      statusFilter,
      sortBy: state.sortBy,
      sourceFilter: state.sourceFilter,
      pageSize: state.pageSize,
      onSearchChange: state.setSearchTerm,
      onStatusFilterChange: setStatusFilter,
      onSortChange: state.setSortBy,
      onSourceFilterChange: state.setSourceFilter,
      onPageSizeChange: state.setPageSize,
      onClearSearch: clearSearch,
    },
    table: {
      rows,
      emptyState,
      canDeleteRequests,
      onClearFilters: clearFilters,
      bulkSelection: {
        canSelectPage: state.canBulkSelectInPage,
        title: state.bulkSelectTitle,
        allPagePendingSelected:
          state.pendingIdsInPage.length > 0 &&
          state.pendingIdsInPage.every((id) => state.selectedRequestIds.includes(id)),
        onToggleSelectPage: state.toggleSelectAllInPage,
        onToggleRequest: state.toggleRequestSelection,
      },
      pagination: {
        currentPage: state.currentPage,
        pageSize: state.pageSize,
        totalPages: state.totalPages,
        totalItems: state.sortedRequests.length,
        visibleStart: (state.currentPage - 1) * state.pageSize + 1,
        visibleEnd: Math.min(state.currentPage * state.pageSize, state.sortedRequests.length),
        onChangePage: setPage,
      },
      onOpenApprove: (requestId: string) => {
        dialogs.setApproveModal({ open: true, request: getRequestById(requestId) });
      },
      onOpenReject: (requestId: string) => {
        dialogs.setRejectModal({ open: true, request: getRequestById(requestId) });
      },
      onOpenDelete: (requestId: string) => {
        dialogs.setDeleteModal({ open: true, request: getRequestById(requestId) });
      },
    },
    bulkActions: {
      selectedCount: state.selectedPendingRequests.length,
      rejectReason: bulkActions.bulkRejectReason,
      loading: bulkActions.bulkLoading,
      progress: bulkActions.bulkProgress,
      failedIds: bulkActions.bulkFailedIds,
      failedCount: bulkActions.bulkFailedIds.length,
      message: bulkActions.bulkMessage,
      onRejectReasonChange: bulkActions.setBulkRejectReason,
      onApproveSelected: bulkActions.openBulkApproveConfirm,
      onRejectSelected: bulkActions.openBulkRejectConfirm,
      onClearSelection: bulkActions.clearBulkSelection,
      onSelectFailed: () => state.setSelectedRequestIds(bulkActions.bulkFailedIds),
      onRetryFailed: bulkActions.handleRetryFailed,
    },
    dialogs: {
      bulkConfirm: bulkActions.bulkConfirm,
      approveModal: {
        open: dialogs.approveModal.open,
        request: toDialogRequest(dialogs.approveModal.request),
      },
      rejectModal: {
        open: dialogs.rejectModal.open,
        request: toDialogRequest(dialogs.rejectModal.request),
      },
      deleteModal: {
        open: dialogs.deleteModal.open,
        request: toDialogRequest(dialogs.deleteModal.request),
      },
      rejectionReason: dialogs.rejectionReason,
      actionsLoading: data.actionsLoading || bulkActions.bulkLoading,
      onBulkConfirmClose: () => bulkActions.setBulkConfirm(null),
      onBulkApproveConfirm: async (requestIds: string[]) => {
        bulkActions.setBulkConfirm(null);
        await bulkActions.runBulkApprove(requestIds);
      },
      onBulkRejectConfirm: async (requestIds: string[], reason?: string) => {
        bulkActions.setBulkConfirm(null);
        await bulkActions.runBulkReject(requestIds, reason);
      },
      onApproveClose: () => dialogs.setApproveModal({ open: false, request: null }),
      onApproveConfirm: dialogs.handleApprove,
      onRejectClose: () => {
        dialogs.setRejectModal({ open: false, request: null });
        dialogs.setRejectionReason('');
      },
      onRejectConfirm: dialogs.handleReject,
      onRejectReasonChange: dialogs.setRejectionReason,
      onDeleteClose: () => dialogs.setDeleteModal({ open: false, request: null }),
      onDeleteConfirm: dialogs.handleDelete,
    },
  };
}

export type DomainRequestsViewModel = ReturnType<typeof useDomainRequestsViewModel>;
export type DomainRequestsFilterModel = DomainRequestsViewModel['filters'];
export type DomainRequestsTableModel = DomainRequestsViewModel['table'];
export type DomainRequestsBulkActionsModel = DomainRequestsViewModel['bulkActions'];
export type DomainRequestsDialogsModel = DomainRequestsViewModel['dialogs'];
export type DomainRequestsSortOption = SortOption;
export type DomainRequestsSourceFilter = SourceFilter;
