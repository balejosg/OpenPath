import { useCallback, useEffect, useRef, useState } from 'react';

import { getRootDomain } from '@openpath/shared/domain';

import { trpc } from '../lib/trpc';
import { createLatestGuard } from '../lib/latest';
import { reportError } from '../lib/reportError';
import type { DomainGroup } from '../lib/rule-groups';
import type { Rule } from '../lib/rules';
import type { FilterType } from './useGroupedRulesManager';

const PAGE_SIZE = 20;

interface UseGroupedRulesDataOptions {
  filter: FilterType;
  groupId: string;
  page: number;
  search: string;
}

export interface UseGroupedRulesDataResult {
  counts: { all: number; allowed: number; blocked: number; disabled: number };
  domainGroups: DomainGroup[];
  error: string | null;
  loading: boolean;
  totalGroups: number;
  totalPages: number;
  totalRules: number;
  refetch: () => Promise<void>;
}

export function useGroupedRulesData({
  filter,
  groupId,
  page,
  search,
}: UseGroupedRulesDataOptions): UseGroupedRulesDataResult {
  const [domainGroups, setDomainGroups] = useState<DomainGroup[]>([]);
  const [totalGroups, setTotalGroups] = useState(0);
  const [totalRules, setTotalRules] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [counts, setCounts] = useState({
    all: 0,
    allowed: 0,
    blocked: 0,
    disabled: 0,
  });

  const fetchSeqRef = useRef(createLatestGuard());

  const fetchRules = useCallback(async () => {
    if (!groupId) return;

    const seq = fetchSeqRef.current.next();

    try {
      setLoading(true);
      setError(null);

      let filteredGroups: DomainGroup[];

      if (filter === 'blocked') {
        const [subdomains, paths] = await Promise.all([
          trpc.groups.listRules.query({ groupId, type: 'blocked_subdomain', enabled: true }),
          trpc.groups.listRules.query({ groupId, type: 'blocked_path', enabled: true }),
        ]);

        let blockedRules = [...subdomains, ...paths] as Rule[];

        if (search.trim()) {
          const searchLower = search.toLowerCase().trim();
          blockedRules = blockedRules.filter((rule) =>
            rule.value.toLowerCase().includes(searchLower)
          );
        }

        const groupedMap = new Map<string, Rule[]>();
        for (const rule of blockedRules) {
          const root = getRootDomain(rule.value);
          const existing = groupedMap.get(root) ?? [];
          existing.push(rule);
          groupedMap.set(root, existing);
        }

        const sortedRoots = Array.from(groupedMap.keys()).sort((left, right) =>
          left.localeCompare(right)
        );

        const allBlockedGroups: DomainGroup[] = sortedRoots.map((root) => {
          const groupRules = groupedMap.get(root) ?? [];
          groupRules.sort((left, right) => left.value.localeCompare(right.value));
          return { root, rules: groupRules, status: 'blocked' as const };
        });

        if (fetchSeqRef.current.isLatest(seq)) {
          setTotalGroups(allBlockedGroups.length);
          setTotalRules(blockedRules.length);
        }

        const start = (page - 1) * PAGE_SIZE;
        filteredGroups = allBlockedGroups.slice(start, start + PAGE_SIZE);
      } else {
        const result = await trpc.groups.listRulesGrouped.query({
          groupId,
          type: filter === 'allowed' ? 'whitelist' : undefined,
          enabled: filter === 'disabled' ? false : filter === 'all' ? undefined : true,
          limit: PAGE_SIZE,
          offset: (page - 1) * PAGE_SIZE,
          search: search.trim() || undefined,
        });

        filteredGroups = result.groups as DomainGroup[];
        if (fetchSeqRef.current.isLatest(seq)) {
          setTotalGroups(result.totalGroups);
          setTotalRules(result.totalRules);
        }
      }

      if (fetchSeqRef.current.isLatest(seq)) {
        setDomainGroups(filteredGroups);
      }
    } catch (err) {
      if (!fetchSeqRef.current.isLatest(seq)) return;
      reportError('Failed to fetch grouped rules:', err);
      setError('Unable to load rules');
    } finally {
      if (fetchSeqRef.current.isLatest(seq)) {
        setLoading(false);
      }
    }
  }, [filter, groupId, page, search]);

  const fetchCounts = useCallback(async () => {
    if (!groupId) return;

    try {
      const [whitelist, subdomains, paths, disabledRules] = await Promise.all([
        trpc.groups.listRules.query({ groupId, type: 'whitelist', enabled: true }),
        trpc.groups.listRules.query({ groupId, type: 'blocked_subdomain', enabled: true }),
        trpc.groups.listRules.query({ groupId, type: 'blocked_path', enabled: true }),
        trpc.groups.listRules.query({ groupId, enabled: false }),
      ]);

      const allowed = whitelist.length;
      const blocked = subdomains.length + paths.length;
      const disabled = disabledRules.length;

      setCounts({
        all: allowed + blocked + disabled,
        allowed,
        blocked,
        disabled,
      });
    } catch (err) {
      reportError('Failed to fetch counts:', err);
    }
  }, [groupId]);

  useEffect(() => {
    void fetchRules();
  }, [fetchRules]);

  useEffect(() => {
    void fetchCounts();
  }, [fetchCounts]);

  return {
    counts,
    domainGroups,
    error,
    loading,
    totalGroups,
    totalPages: Math.ceil(totalGroups / PAGE_SIZE),
    totalRules,
    refetch: async () => {
      await Promise.all([fetchRules(), fetchCounts()]);
    },
  };
}
