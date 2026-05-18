import { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import type { GroupVisibility } from '@openpath/shared';
import { trpc } from '../lib/trpc';
import { useAllowedGroups } from './useAllowedGroups';
import type { GroupsActiveView, GroupCardViewModel, LibraryGroup } from './useGroupsViewModel';

export function useGroupsViewModelData(activeView: GroupsActiveView) {
  const {
    groups: allowedGroups,
    groupById: allowedGroupById,
    isLoading,
    error: groupsQueryError,
    refetch: refetchGroups,
  } = useAllowedGroups();

  const libraryQuery = useQuery({
    queryKey: ['groups.libraryList'],
    queryFn: () => trpc.groups.libraryList.query(),
    enabled: activeView === 'library',
  });

  const libraryGroups: LibraryGroup[] = (libraryQuery.data ?? []) as LibraryGroup[];
  const libraryLoading =
    libraryQuery.status === 'pending' || libraryQuery.fetchStatus === 'fetching';
  const libraryError = libraryQuery.error ? 'Unable to load library' : null;
  const visibleGroups = activeView === 'library' ? libraryGroups : allowedGroups;

  const groups = useMemo<GroupCardViewModel[]>(() => {
    return visibleGroups.map((group) => {
      const status: 'Active' | 'Inactive' = group.enabled ? 'Active' : 'Inactive';

      return {
        id: group.id,
        name: group.name,
        displayName: group.displayName || group.name,
        description: group.displayName || group.name,
        domainCount: group.whitelistCount + group.blockedSubdomainCount + group.blockedPathCount,
        status,
        visibility: (group.visibility as GroupVisibility | undefined) ?? 'private',
      };
    });
  }, [visibleGroups]);

  const loading = activeView === 'library' ? libraryLoading : isLoading;
  const error =
    activeView === 'library' ? libraryError : groupsQueryError ? 'Unable to load groups' : null;

  const refetchActiveView = async () => {
    if (activeView === 'library') {
      await libraryQuery.refetch();
      return;
    }

    await refetchGroups();
  };

  return {
    groups,
    loading,
    error,
    refetchActiveView,
    allowedGroups,
    allowedGroupById,
    libraryGroups,
    refetchGroups,
    groupsQueryError,
  };
}
