import { act, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  useClassroomControlStatesQuery,
  useClassroomListModelsQuery,
  useClassroomsQuery,
} from '../useClassroomsList';
import { renderHookWithQueryClient } from '../../test-utils/query';

let queryClient: ReturnType<typeof renderHookWithQueryClient>['queryClient'] | null = null;

const { mockClassroomsList } = vi.hoisted(() => ({
  mockClassroomsList: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    classrooms: {
      list: { query: (): unknown => mockClassroomsList() },
    },
  },
}));

const baseClassroom = {
  id: 'classroom-1',
  name: 'Lab Norte',
  displayName: 'Lab Norte',
  defaultGroupId: 'group-default',
  defaultGroupDisplayName: 'Plan Base',
  machineCount: 12,
  activeGroupId: 'group-manual',
  currentGroupId: 'group-manual',
  currentGroupDisplayName: 'Plan Manual',
  currentGroupSource: 'manual',
  status: 'operational',
  onlineMachineCount: 10,
  machines: [],
  createdAt: '2026-03-06T10:00:00.000Z',
  updatedAt: '2026-03-06T10:00:00.000Z',
};

function renderUseClassroomsQuery<T>(hook: () => T) {
  const rendered = renderHookWithQueryClient(hook);
  queryClient = rendered.queryClient;
  return rendered;
}

describe('useClassroomsList', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockClassroomsList.mockResolvedValue([baseClassroom]);
  });

  afterEach(() => {
    queryClient?.clear();
    queryClient = null;
  });

  it('maps classroom list results into the shared Classroom shape', async () => {
    const { result } = renderUseClassroomsQuery(() => useClassroomsQuery());

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.error).toBeNull();
    expect(result.current.data).toEqual([
      {
        id: 'classroom-1',
        name: 'Lab Norte',
        displayName: 'Lab Norte',
        defaultGroupId: 'group-default',
        defaultGroupDisplayName: 'Plan Base',
        computerCount: 12,
        activeGroup: 'group-manual',
        currentGroupId: 'group-manual',
        currentGroupDisplayName: 'Plan Manual',
        currentGroupSource: 'manual',
        status: 'operational',
        onlineMachineCount: 10,
        captivePortalDomains: [],
        machines: [],
      },
    ]);
  });

  it('refetches classroom control states without losing the selector shape', async () => {
    const { result } = renderUseClassroomsQuery(() => useClassroomControlStatesQuery());

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.data[0]?.activeGroupId).toBe('group-manual');

    mockClassroomsList.mockResolvedValueOnce([
      {
        ...baseClassroom,
        activeGroupId: null,
        currentGroupId: 'group-default',
        currentGroupDisplayName: 'Plan Base',
        currentGroupSource: 'default',
      },
    ]);

    await act(async () => {
      await result.current.refetchClassrooms();
    });

    await waitFor(() => {
      expect(result.current.data[0]?.currentGroupSource).toBe('default');
    });

    expect(result.current.data[0]?.activeGroupId).toBeNull();
    expect(result.current.data[0]?.currentGroupId).toBe('group-default');
  });

  it('exposes canonical classroom list models for shared selectors', async () => {
    const { result } = renderUseClassroomsQuery(() => useClassroomListModelsQuery());

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.data).toEqual([
      {
        id: 'classroom-1',
        name: 'Lab Norte',
        displayName: 'Lab Norte',
        defaultGroupId: 'group-default',
        defaultGroupDisplayName: 'Plan Base',
        machineCount: 12,
        activeGroupId: 'group-manual',
        currentGroupId: 'group-manual',
        currentGroupDisplayName: 'Plan Manual',
        currentGroupSource: 'manual',
        status: 'operational',
        onlineMachineCount: 10,
        machines: [],
      },
    ]);
  });
});
