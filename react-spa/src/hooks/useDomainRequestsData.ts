import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { DomainRequest, RequestStatus } from '@openpath/api';
import { trpc } from '../lib/trpc';

export interface DomainRequestGroup {
  id: string;
  name: string;
  path: string;
}

const EMPTY_REQUESTS: DomainRequest[] = [];
const EMPTY_GROUPS: DomainRequestGroup[] = [];

export function useDomainRequestsData(statusFilter: RequestStatus | 'all') {
  const queryClient = useQueryClient();

  // Avoid keeping Node test processes alive via refetch intervals.
  const shouldPoll = import.meta.env.MODE !== 'test';

  const requestsQuery = useQuery({
    queryKey: ['domain-requests', 'requests', statusFilter],
    queryFn: () => trpc.requests.list.query(statusFilter === 'all' ? {} : { status: statusFilter }),
    refetchInterval: shouldPoll ? 10000 : false,
    refetchOnWindowFocus: 'always',
  });

  const groupsQuery = useQuery({
    queryKey: ['domain-requests', 'groups'],
    queryFn: () => trpc.requests.listGroups.query(),
    staleTime: 60 * 1000,
    refetchOnWindowFocus: 'always',
  });

  const invalidateRequests = () =>
    queryClient.invalidateQueries({ queryKey: ['domain-requests', 'requests'] });

  const approveMutation = useMutation({
    mutationFn: async (id: string) => {
      return await trpc.requests.approve.mutate({ id });
    },
    onSuccess: () => {
      void invalidateRequests();
    },
  });

  const rejectMutation = useMutation({
    mutationFn: async (input: { id: string; reason?: string }) => {
      return await trpc.requests.reject.mutate(input);
    },
    onSuccess: () => {
      void invalidateRequests();
    },
  });

  const deleteMutation = useMutation({
    mutationFn: async (id: string) => {
      return await trpc.requests.delete.mutate({ id });
    },
    onSuccess: () => {
      void invalidateRequests();
    },
  });

  const loading = requestsQuery.status === 'pending' || groupsQuery.status === 'pending';
  const fetching =
    requestsQuery.fetchStatus === 'fetching' || groupsQuery.fetchStatus === 'fetching';
  const hasError = requestsQuery.status === 'error' || groupsQuery.status === 'error';

  return {
    requests: requestsQuery.data ?? EMPTY_REQUESTS,
    groups: groupsQuery.data ?? EMPTY_GROUPS,
    loading,
    fetching,
    error: hasError ? 'Unable to load requests' : null,
    invalidateRequests,
    approveRequest: approveMutation.mutateAsync,
    rejectRequest: rejectMutation.mutateAsync,
    deleteRequest: deleteMutation.mutateAsync,
    actionsLoading:
      approveMutation.status === 'pending' ||
      rejectMutation.status === 'pending' ||
      deleteMutation.status === 'pending',
  };
}
