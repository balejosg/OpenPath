import { describe, expect, it } from 'vitest';

import {
  filterClassroomsBySearch,
  selectActiveClassroomRowsFromModels,
  selectClassroomControlConfirmation,
  selectFilteredClassroomsFromModels,
} from '../classroom-selectors';
import type { Classroom } from '../../types';
import type { ClassroomListModel } from '../classrooms';
import { translateProductText } from '../../i18n/product-i18n';

const t = (
  key: Parameters<typeof translateProductText>[1],
  params?: Parameters<typeof translateProductText>[2]
) => translateProductText('en', key, params);

const classroomModels: ClassroomListModel[] = [
  {
    id: 'classroom-1',
    name: 'Laboratorio Norte',
    displayName: 'Laboratorio Norte',
    defaultGroupId: 'group-default',
    defaultGroupDisplayName: 'Plan Base',
    machineCount: 10,
    activeGroupId: 'group-manual',
    currentGroupId: 'group-manual',
    currentGroupDisplayName: 'Plan Manual',
    currentGroupSource: 'manual',
    status: 'operational',
    onlineMachineCount: 10,
    captivePortalDomains: [],
    machines: [],
  },
  {
    id: 'classroom-2',
    name: 'South Classroom',
    displayName: 'South Classroom',
    defaultGroupId: 'group-default',
    defaultGroupDisplayName: 'Plan Base',
    machineCount: 8,
    activeGroupId: null,
    currentGroupId: 'group-default',
    currentGroupDisplayName: 'Plan Base',
    currentGroupSource: 'default',
    status: 'operational',
    onlineMachineCount: 8,
    captivePortalDomains: [],
    machines: [],
  },
];

const classrooms: Classroom[] = [
  {
    id: 'classroom-1',
    name: 'Laboratorio Norte',
    displayName: 'Laboratorio Norte',
    defaultGroupId: 'group-default',
    defaultGroupDisplayName: 'Plan Base',
    computerCount: 10,
    activeGroup: 'grupo-manual',
    currentGroupId: 'group-manual',
    currentGroupDisplayName: 'Plan Manual',
    currentGroupSource: 'manual',
    status: 'operational',
    onlineMachineCount: 10,
    captivePortalDomains: [],
    machines: [],
  },
  {
    id: 'classroom-2',
    name: 'South Classroom',
    displayName: 'South Classroom',
    defaultGroupId: 'group-default',
    defaultGroupDisplayName: 'Plan Base',
    computerCount: 8,
    activeGroup: null,
    currentGroupId: 'group-default',
    currentGroupDisplayName: 'Plan Base',
    currentGroupSource: 'default',
    status: 'operational',
    onlineMachineCount: 8,
    captivePortalDomains: [],
    machines: [],
  },
];

const groupById = new Map([
  [
    'group-manual',
    {
      id: 'group-manual',
      name: 'grupo-manual',
      displayName: 'Grupo Manual',
      enabled: true,
    },
  ],
  [
    'group-default',
    {
      id: 'group-default',
      name: 'grupo-default',
      displayName: 'Grupo Base',
      enabled: true,
    },
  ],
]);

describe('classroom-selectors', () => {
  it('filters classrooms by normalized search terms', () => {
    expect(filterClassroomsBySearch(classrooms, 'laboratorio norte')).toEqual([classrooms[0]]);
    expect(filterClassroomsBySearch(classrooms, 'grupo-manual')).toEqual([classrooms[0]]);
    expect(filterClassroomsBySearch(classrooms, '')).toEqual(classrooms);
  });

  it('filters classroom models through the shared classroom selector', () => {
    expect(selectFilteredClassroomsFromModels(classroomModels, 'south classroom')).toEqual([
      classrooms[1],
    ]);
  });

  it('derives active classroom rows from classroom models', () => {
    expect(selectActiveClassroomRowsFromModels(classroomModels, groupById)).toEqual([
      {
        classroomId: 'classroom-1',
        classroomName: 'Laboratorio Norte',
        groupId: 'group-manual',
        group: groupById.get('group-manual'),
        source: 'manual',
        hasManualOverride: true,
      },
      {
        classroomId: 'classroom-2',
        classroomName: 'South Classroom',
        groupId: 'group-default',
        group: groupById.get('group-default'),
        source: 'default',
        hasManualOverride: false,
      },
    ]);
  });

  it('derives takeover confirmation state from classroom models', () => {
    expect(
      selectClassroomControlConfirmation({
        classrooms: classroomModels,
        groupById,
        classroomId: 'classroom-1',
        nextGroupId: 'group-default',
        t,
      })
    ).toEqual({
      classroomId: 'classroom-1',
      nextGroupId: 'group-default',
      currentName: 'Grupo Manual',
      nextName: 'Grupo Base',
    });

    expect(
      selectClassroomControlConfirmation({
        classrooms: classroomModels,
        groupById,
        classroomId: 'classroom-2',
        nextGroupId: 'group-default',
        t,
      })
    ).toBeNull();
  });
});
