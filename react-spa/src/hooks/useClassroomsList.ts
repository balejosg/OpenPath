import { useCallback, useEffect } from 'react';
import { useQuery } from '@tanstack/react-query';

import {
  toClassroomControlStatesFromModels,
  toClassroomListModels,
  toClassroomsFromModels,
  type ClassroomControlState,
  type ClassroomListModel,
} from '../lib/classrooms';
import { trpc } from '../lib/trpc';
import { reportError } from '../lib/reportError';
import type { Classroom } from '../types';

export const CLASSROOMS_LIST_QUERY_KEY = ['classrooms.list'] as const;

interface UseClassroomsListQueryOptions<TResult> {
  select: (items: readonly ClassroomListModel[]) => TResult;
  emptyValue: TResult;
  refetchIntervalMs?: number | false;
  refetchOnWindowFocus?: boolean;
}

interface UseClassroomsListQueryResult<TResult> {
  data: TResult;
  hasData: boolean;
  loading: boolean;
  fetching: boolean;
  error: string | null;
  refetchClassrooms: () => Promise<TResult>;
}

function useClassroomsListQuery<TResult>(
  options: UseClassroomsListQueryOptions<TResult>
): UseClassroomsListQueryResult<TResult> {
  const { select, emptyValue, refetchIntervalMs = false, refetchOnWindowFocus = false } = options;
  const query = useQuery<readonly ClassroomListModel[], Error, TResult>({
    queryKey: CLASSROOMS_LIST_QUERY_KEY,
    queryFn: async () => {
      const items = await trpc.classrooms.list.query();
      return toClassroomListModels(items);
    },
    select,
    refetchInterval: typeof refetchIntervalMs === 'number' ? refetchIntervalMs : false,
    refetchOnWindowFocus,
  });

  useEffect(() => {
    if (query.error) {
      reportError('Failed to fetch classrooms:', query.error);
    }
  }, [query.error]);

  const refetchClassrooms = useCallback(async () => {
    const result = await query.refetch();
    return result.data ?? query.data ?? emptyValue;
  }, [emptyValue, query.data, query.refetch]);

  return {
    data: query.data ?? emptyValue,
    hasData: query.data !== undefined,
    loading: query.status === 'pending',
    fetching: query.fetchStatus === 'fetching',
    error: query.error ? 'Unable to load classrooms' : null,
    refetchClassrooms,
  };
}

const EMPTY_CLASSROOMS: Classroom[] = [];
const EMPTY_CLASSROOM_LIST_MODELS: readonly ClassroomListModel[] = [];
const EMPTY_CLASSROOM_CONTROL_STATES: ClassroomControlState[] = [];

export function useClassroomListModelsQuery(options?: {
  refetchIntervalMs?: number | false;
  refetchOnWindowFocus?: boolean;
}): UseClassroomsListQueryResult<readonly ClassroomListModel[]> {
  return useClassroomsListQuery({
    select: (items) => items,
    emptyValue: EMPTY_CLASSROOM_LIST_MODELS,
    refetchIntervalMs: options?.refetchIntervalMs,
    refetchOnWindowFocus: options?.refetchOnWindowFocus,
  });
}

export function useClassroomsQuery(options?: {
  refetchIntervalMs?: number | false;
  refetchOnWindowFocus?: boolean;
}): UseClassroomsListQueryResult<Classroom[]> {
  return useClassroomsListQuery({
    select: toClassroomsFromModels,
    emptyValue: EMPTY_CLASSROOMS,
    refetchIntervalMs: options?.refetchIntervalMs,
    refetchOnWindowFocus: options?.refetchOnWindowFocus,
  });
}

export function useClassroomControlStatesQuery(options?: {
  refetchIntervalMs?: number | false;
  refetchOnWindowFocus?: boolean;
}): UseClassroomsListQueryResult<ClassroomControlState[]> {
  return useClassroomsListQuery({
    select: toClassroomControlStatesFromModels,
    emptyValue: EMPTY_CLASSROOM_CONTROL_STATES,
    refetchIntervalMs: options?.refetchIntervalMs,
    refetchOnWindowFocus: options?.refetchOnWindowFocus,
  });
}
