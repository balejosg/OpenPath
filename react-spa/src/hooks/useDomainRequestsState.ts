import { useEffect, useMemo, useState } from 'react';
import type { DomainRequest, RequestStatus } from '@openpath/api';
import { normalizeSearchTerm, useNormalizedSearch } from './useNormalizedSearch';
import type { DomainRequestGroup } from './useDomainRequestsData';

export type SortOption = 'pending' | 'newest' | 'oldest';
export type SourceFilter = 'all' | 'firefox-extension' | 'manual';

interface UseDomainRequestsStateOptions {
  requests: DomainRequest[];
  groups: DomainRequestGroup[];
  statusFilter: RequestStatus | 'all';
}

export function useDomainRequestsState({
  requests,
  groups,
  statusFilter,
}: UseDomainRequestsStateOptions) {
  const [searchTerm, setSearchTerm] = useState('');
  const normalizedSearchTerm = useNormalizedSearch(searchTerm);
  const [sourceFilter, setSourceFilter] = useState<SourceFilter>('all');
  const [sortBy, setSortBy] = useState<SortOption>('pending');
  const [currentPage, setCurrentPage] = useState(1);
  const [pageSize, setPageSize] = useState(20);
  const [selectedRequestIds, setSelectedRequestIds] = useState<string[]>([]);

  const filteredRequests = useMemo(
    () =>
      requests.filter((req) => {
        const matchesSearch =
          !normalizedSearchTerm ||
          normalizeSearchTerm(req.domain).includes(normalizedSearchTerm) ||
          normalizeSearchTerm(req.machineHostname ?? '').includes(normalizedSearchTerm);

        if (!matchesSearch) return false;
        if (statusFilter !== 'all' && req.status !== statusFilter) return false;
        if (sourceFilter === 'all') return true;
        if (sourceFilter === 'firefox-extension') return req.source === 'firefox-extension';
        return (req.source ?? 'manual') !== 'firefox-extension';
      }),
    [requests, normalizedSearchTerm, sourceFilter, statusFilter]
  );

  const sortedRequests = useMemo(() => {
    const sorted = [...filteredRequests];

    sorted.sort((a, b) => {
      switch (sortBy) {
        case 'newest':
          return new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime();
        case 'oldest':
          return new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime();
        case 'pending':
        default: {
          if (a.status === 'pending' && b.status !== 'pending') return -1;
          if (a.status !== 'pending' && b.status === 'pending') return 1;

          if (a.status === 'pending' && b.status === 'pending') {
            return new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime();
          }

          return new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime();
        }
      }
    });

    return sorted;
  }, [filteredRequests, sortBy]);

  const totalPages = Math.max(1, Math.ceil(sortedRequests.length / pageSize));

  const paginatedRequests = useMemo(() => {
    const start = (currentPage - 1) * pageSize;
    return sortedRequests.slice(start, start + pageSize);
  }, [sortedRequests, currentPage, pageSize]);

  const pendingIdsInPage = useMemo(
    () =>
      paginatedRequests
        .filter((request) => request.status === 'pending')
        .map((request) => request.id),
    [paginatedRequests]
  );

  const selectedPendingRequests = useMemo(
    () =>
      requests.filter(
        (request) => request.status === 'pending' && selectedRequestIds.includes(request.id)
      ),
    [requests, selectedRequestIds]
  );

  const groupNameByPath = useMemo(() => {
    const map = new Map<string, string>();
    for (const group of groups) {
      map.set(group.path, group.name);
    }
    return map;
  }, [groups]);

  const pendingCount = useMemo(() => {
    return filteredRequests.reduce(
      (count, request) => (request.status === 'pending' ? count + 1 : count),
      0
    );
  }, [filteredRequests]);

  const hasActiveFilters =
    normalizedSearchTerm.length > 0 || statusFilter !== 'all' || sourceFilter !== 'all';
  const canBulkSelectInPage = pendingIdsInPage.length > 0;
  const bulkSelectTitle = canBulkSelectInPage
    ? 'Select pending items on this page'
    : statusFilter === 'approved' || statusFilter === 'rejected'
      ? 'Bulk selection is not available for this filter'
      : 'No selectable pending items on this page';

  useEffect(() => {
    setCurrentPage(1);
  }, [searchTerm, statusFilter, sourceFilter, sortBy, pageSize]);

  useEffect(() => {
    setSelectedRequestIds((prev) => {
      const next = prev.filter((id) => sortedRequests.some((request) => request.id === id));
      if (next.length === prev.length && next.every((id, idx) => id === prev[idx])) {
        return prev;
      }
      return next;
    });
  }, [sortedRequests]);

  const toggleRequestSelection = (requestId: string) => {
    setSelectedRequestIds((prev) =>
      prev.includes(requestId) ? prev.filter((id) => id !== requestId) : [...prev, requestId]
    );
  };

  const toggleSelectAllInPage = () => {
    const allSelected =
      pendingIdsInPage.length > 0 &&
      pendingIdsInPage.every((id) => selectedRequestIds.includes(id));

    if (allSelected) {
      setSelectedRequestIds((prev) => prev.filter((id) => !pendingIdsInPage.includes(id)));
      return;
    }

    setSelectedRequestIds((prev) => Array.from(new Set([...prev, ...pendingIdsInPage])));
  };

  const getGroupName = (groupId: string) => groupNameByPath.get(groupId) ?? groupId;

  return {
    searchTerm,
    setSearchTerm,
    sourceFilter,
    setSourceFilter,
    sortBy,
    setSortBy,
    currentPage,
    setCurrentPage,
    pageSize,
    setPageSize,
    selectedRequestIds,
    setSelectedRequestIds,
    filteredRequests,
    sortedRequests,
    paginatedRequests,
    pendingIdsInPage,
    selectedPendingRequests,
    pendingCount,
    hasActiveFilters,
    canBulkSelectInPage,
    bulkSelectTitle,
    totalPages,
    getGroupName,
    toggleRequestSelection,
    toggleSelectAllInPage,
  };
}
