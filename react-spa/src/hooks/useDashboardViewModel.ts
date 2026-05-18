import { useEffect, useMemo, useState, useCallback } from 'react';
import { trpc } from '../lib/trpc';
import { reportError } from '../lib/reportError';
import { selectActiveClassroomRowsFromModels } from '../lib/classroom-selectors';
import { useClassroomListModelsQuery } from './useClassroomsList';
import { useIntervalRefetch, useRefetchOnFocus } from './useLiveRefetch';

interface StatsData {
  groupCount: number;
  whitelistCount: number;
  blockedCount: number;
  pendingRequests: number;
}

interface SystemStatus {
  totalGroups: number;
  activeGroups: number;
  pausedGroups: number;
  lastChecked: Date;
}

export interface DashboardGroup {
  id: string;
  name: string;
  displayName: string;
  enabled: boolean;
  whitelistCount: number;
  blockedSubdomainCount: number;
  blockedPathCount: number;
  createdAt?: string;
  updatedAt?: string | null;
}

export type DashboardSortOption = 'name' | 'rules' | 'recent';

export const DASHBOARD_SORT_OPTIONS: { value: DashboardSortOption; label: string }[] = [
  { value: 'name', label: 'Nombre (A-Z)' },
  { value: 'rules', label: 'Most rules' },
  { value: 'recent', label: 'Recientes' },
];

const MAX_QUICK_ACCESS_GROUPS = 6;

export function useDashboardViewModel() {
  const [stats, setStats] = useState<StatsData | null>(null);
  const [systemStatus, setSystemStatus] = useState<SystemStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [groups, setGroups] = useState<DashboardGroup[]>([]);
  const [groupsLoading, setGroupsLoading] = useState(true);
  const [groupsError, setGroupsError] = useState<string | null>(null);
  const [sortBy, setSortBy] = useState<DashboardSortOption>('name');
  const [showSortDropdown, setShowSortDropdown] = useState(false);

  const fetchStats = useCallback(async () => {
    try {
      setLoading(true);
      const [groupStats, requestStats, sysStatus] = await Promise.all([
        trpc.groups.stats.query(),
        trpc.requests.stats.query(),
        trpc.groups.systemStatus.query(),
      ]);

      setStats({
        groupCount: groupStats.groupCount,
        whitelistCount: groupStats.whitelistCount,
        blockedCount: groupStats.blockedCount,
        pendingRequests: requestStats.pending,
      });
      setSystemStatus({
        totalGroups: sysStatus.totalGroups,
        activeGroups: sysStatus.activeGroups,
        pausedGroups: sysStatus.pausedGroups,
        lastChecked: new Date(),
      });
      setError(null);
    } catch (err) {
      reportError('Failed to fetch dashboard stats:', err);
      setError('Unable to load statistics');
    } finally {
      setLoading(false);
    }
  }, []);

  const shouldPoll = import.meta.env.MODE !== 'test';
  const {
    data: classrooms,
    loading: classroomsLoading,
    error: classroomsError,
    refetchClassrooms,
  } = useClassroomListModelsQuery({
    refetchIntervalMs: shouldPoll ? 30000 : false,
    refetchOnWindowFocus: shouldPoll,
  });

  useEffect(() => {
    void fetchStats();
  }, [fetchStats]);

  const refetchDashboard = useCallback(() => {
    void fetchStats();
    void refetchClassrooms();
  }, [fetchStats, refetchClassrooms]);

  useIntervalRefetch(fetchStats, 10000, { enabled: shouldPoll });
  useRefetchOnFocus(refetchDashboard);

  useEffect(() => {
    const fetchGroups = async () => {
      try {
        setGroupsLoading(true);
        const apiGroups = await trpc.groups.list.query();
        setGroups(apiGroups);
        setGroupsError(null);
      } catch (err) {
        reportError('Failed to fetch groups:', err);
        setGroupsError('Unable to load groups');
      } finally {
        setGroupsLoading(false);
      }
    };

    void fetchGroups();
  }, []);

  const sortedGroups = useMemo(() => {
    const sorted = [...groups].sort((a, b) => {
      switch (sortBy) {
        case 'name':
          return a.displayName.localeCompare(b.displayName);
        case 'rules': {
          const aTotal = a.whitelistCount + a.blockedSubdomainCount + a.blockedPathCount;
          const bTotal = b.whitelistCount + b.blockedSubdomainCount + b.blockedPathCount;
          return bTotal - aTotal;
        }
        case 'recent': {
          const aDate = a.updatedAt ?? a.createdAt ?? '';
          const bDate = b.updatedAt ?? b.createdAt ?? '';
          return bDate.localeCompare(aDate);
        }
        default:
          return 0;
      }
    });

    return sorted.slice(0, MAX_QUICK_ACCESS_GROUPS);
  }, [groups, sortBy]);

  const hasMoreGroups = groups.length > MAX_QUICK_ACCESS_GROUPS;

  const groupById = useMemo(() => {
    return new Map(groups.map((group) => [group.id, group] as const));
  }, [groups]);

  const activeGroupsByClassroom = useMemo(() => {
    return selectActiveClassroomRowsFromModels(classrooms, groupById);
  }, [classrooms, groupById]);

  useEffect(() => {
    const handleClickOutside = () => setShowSortDropdown(false);
    if (showSortDropdown) {
      document.addEventListener('click', handleClickOutside);
      return () => document.removeEventListener('click', handleClickOutside);
    }
  }, [showSortDropdown]);

  return {
    loading,
    error,
    stats,
    systemStatus,
    classrooms,
    classroomsLoading,
    classroomsError,
    groups,
    groupsLoading,
    groupsError,
    sortBy,
    setSortBy,
    showSortDropdown,
    setShowSortDropdown,
    sortedGroups,
    hasMoreGroups,
    activeGroupsByClassroom,
    shouldPoll,
  };
}
