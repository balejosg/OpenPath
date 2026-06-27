import { useEffect, useRef, useState } from 'react';

export type RulesFilterType = 'all' | 'allowed' | 'blocked' | 'disabled';

interface UseRulesFiltersOptions {
  initialFilter?: RulesFilterType;
  initialPage?: number;
  initialSearch?: string;
}

export function useRulesFilters({
  initialFilter = 'all',
  initialPage = 1,
  initialSearch = '',
}: UseRulesFiltersOptions = {}) {
  const [page, setPage] = useState(initialPage);
  const [filter, setFilter] = useState<RulesFilterType>(initialFilter);
  const [search, setSearch] = useState(initialSearch);
  const searchTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (searchTimeoutRef.current) {
      clearTimeout(searchTimeoutRef.current);
    }

    searchTimeoutRef.current = setTimeout(() => {
      setPage(1);
    }, 300);

    return () => {
      if (searchTimeoutRef.current) {
        clearTimeout(searchTimeoutRef.current);
      }
    };
  }, [search]);

  useEffect(() => {
    setPage(1);
  }, [filter]);

  return {
    page,
    setPage,
    filter,
    setFilter,
    search,
    setSearch,
  };
}
