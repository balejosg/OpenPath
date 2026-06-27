import { useCallback, useEffect, useRef, useState } from 'react';
import { trpc } from '../lib/trpc';
import { createLatestGuard } from '../lib/latest';
import type { Rule } from '../lib/rules';
import { reportError } from '../lib/reportError';
import type { RulesFilterType } from './useRulesFilters';

interface UseRulesDataOptions {
  groupId: string;
  filter: RulesFilterType;
  page: number;
  search: string;
  pageSize: number;
}

export function useRulesData({ groupId, filter, page, search, pageSize }: UseRulesDataOptions) {
  const [rules, setRules] = useState<Rule[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [counts, setCounts] = useState({
    all: 0,
    allowed: 0,
    automatic: 0,
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

      let filteredRules: Rule[];
      let filteredTotal: number;

      if (filter === 'blocked') {
        const [subdomains, paths] = await Promise.all([
          trpc.groups.listRules.query({ groupId, type: 'blocked_subdomain' }),
          trpc.groups.listRules.query({ groupId, type: 'blocked_path' }),
        ]);

        let blockedRules = [...subdomains, ...paths];

        if (search.trim()) {
          const searchLower = search.toLowerCase().trim();
          blockedRules = blockedRules.filter((rule) =>
            rule.value.toLowerCase().includes(searchLower)
          );
        }

        blockedRules.sort((a, b) => a.value.localeCompare(b.value));
        filteredTotal = blockedRules.length;

        const start = (page - 1) * pageSize;
        filteredRules = blockedRules.slice(start, start + pageSize);
      } else {
        const result = await trpc.groups.listRulesPaginated.query({
          groupId,
          type: filter === 'allowed' || filter === 'automatic' ? 'whitelist' : undefined,
          source: filter === 'automatic' ? 'auto_extension' : undefined,
          limit: pageSize,
          offset: (page - 1) * pageSize,
          search: search.trim() || undefined,
        });

        filteredRules = result.rules;
        filteredTotal = result.total;
      }

      if (fetchSeqRef.current.isLatest(seq)) {
        setRules(filteredRules);
        setTotal(filteredTotal);
      }
    } catch (err) {
      if (!fetchSeqRef.current.isLatest(seq)) return;
      reportError('Failed to fetch rules:', err);
      setError('Unable to load rules');
    } finally {
      if (fetchSeqRef.current.isLatest(seq)) {
        setLoading(false);
      }
    }
  }, [groupId, filter, page, pageSize, search]);

  const fetchCounts = useCallback(async () => {
    if (!groupId) return;

    try {
      const [whitelist, autoApproved, subdomains, paths, disabledRules] = await Promise.all([
        trpc.groups.listRules.query({ groupId, type: 'whitelist', enabled: true }),
        trpc.groups.listRules.query({
          groupId,
          type: 'whitelist',
          source: 'auto_extension',
          enabled: true,
        }),
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
        automatic: autoApproved.length,
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
    rules,
    total,
    loading,
    error,
    counts,
    fetchRules,
    fetchCounts,
  };
}
