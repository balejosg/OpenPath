import { describe, expect, it } from 'vitest';
import {
  readClassroomListMetadata,
  toActiveClassroomRows,
  toClassroom,
  toClassroomFromModel,
  toClassroomListModel,
  toClassroomControlState,
  toClassroomControlStateFromModel,
  toClassrooms,
  type ClassroomListItem,
} from '../classrooms';

const baseItem = {
  createdAt: '2026-03-06T10:00:00.000Z',
  updatedAt: '2026-03-06T10:00:00.000Z',
} satisfies Pick<ClassroomListItem, 'createdAt' | 'updatedAt'>;

type CompatibleClassroomListItem = ClassroomListItem & {
  defaultGroupDisplayName?: string | null;
  currentGroupDisplayName?: string | null;
};

describe('classrooms adapter', () => {
  it('maps classrooms list items with readable metadata into the shared Classroom shape', () => {
    const listItem: CompatibleClassroomListItem = {
      ...baseItem,
      id: 'classroom-1',
      name: 'Lab Norte',
      displayName: 'Lab Norte',
      defaultGroupId: 'group-1',
      defaultGroupDisplayName: 'Plan Norte',
      machineCount: 12,
      activeGroupId: 'group-2',
      currentGroupId: 'group-2',
      currentGroupDisplayName: 'Plan Manual',
      currentGroupSource: 'manual',
      status: 'operational',
      onlineMachineCount: 10,
      captivePortalDomains: ['login.example.test'],
      machines: [],
    };

    expect(readClassroomListMetadata(listItem)).toEqual({
      defaultGroupDisplayName: 'Plan Norte',
      currentGroupDisplayName: 'Plan Manual',
    });

    const classroom = toClassroom(listItem);

    expect(classroom).toEqual({
      id: 'classroom-1',
      name: 'Lab Norte',
      displayName: 'Lab Norte',
      defaultGroupId: 'group-1',
      defaultGroupDisplayName: 'Plan Norte',
      computerCount: 12,
      activeGroup: 'group-2',
      currentGroupId: 'group-2',
      currentGroupDisplayName: 'Plan Manual',
      currentGroupSource: 'manual',
      status: 'operational',
      onlineMachineCount: 10,
      captivePortalDomains: ['login.example.test'],
      machines: [],
    });

    const model = toClassroomListModel(listItem);
    expect(toClassroomFromModel(model)).toEqual(classroom);
  });

  it('normalizes missing readable metadata to null without a cast', () => {
    const classroom = toClassroom({
      ...baseItem,
      id: 'classroom-2',
      name: 'Lab Sur',
      displayName: 'Lab Sur',
      defaultGroupId: null,
      machineCount: 0,
      activeGroupId: null,
      currentGroupId: null,
      currentGroupSource: 'none',
      status: 'operational',
      onlineMachineCount: 0,
      captivePortalDomains: [],
      machines: [],
    });

    expect(classroom.defaultGroupDisplayName).toBeNull();
    expect(classroom.currentGroupDisplayName).toBeNull();
  });

  it('maps control-state consumers to the same metadata source', () => {
    const listItem: CompatibleClassroomListItem = {
      ...baseItem,
      id: 'classroom-3',
      name: 'Aula 3',
      displayName: 'Aula 3',
      defaultGroupId: 'group-1',
      currentGroupId: 'group-1',
      currentGroupSource: 'default',
      activeGroupId: null,
      defaultGroupDisplayName: 'Plan Aula 3',
      currentGroupDisplayName: 'Plan Aula 3',
      machineCount: 8,
      status: 'operational',
      onlineMachineCount: 8,
      captivePortalDomains: ['wifi.example.test'],
      machines: [],
    };

    const controlState = toClassroomControlState(listItem);
    const model = toClassroomListModel(listItem);

    expect(toClassrooms([listItem])).toHaveLength(1);
    expect(controlState).toEqual({
      id: 'classroom-3',
      name: 'Aula 3',
      displayName: 'Aula 3',
      defaultGroupId: 'group-1',
      defaultGroupDisplayName: 'Plan Aula 3',
      activeGroupId: null,
      currentGroupId: 'group-1',
      currentGroupDisplayName: 'Plan Aula 3',
      currentGroupSource: 'default',
    });
    expect(toClassroomControlStateFromModel(model)).toEqual(controlState);
  });

  it('derives active classroom rows from the shared control-state selector', () => {
    const controlStates = [
      {
        id: 'classroom-4',
        name: 'Lab Manual',
        displayName: 'Laboratorio Manual',
        defaultGroupId: 'group-default',
        defaultGroupDisplayName: 'Grupo Base',
        activeGroupId: 'group-manual',
        currentGroupId: 'group-manual',
        currentGroupDisplayName: 'Grupo Manual',
        currentGroupSource: null,
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
    ]);

    expect(toActiveClassroomRows(controlStates, groupById)).toEqual([
      {
        classroomId: 'classroom-4',
        classroomName: 'Laboratorio Manual',
        groupId: 'group-manual',
        group: {
          id: 'group-manual',
          name: 'grupo-manual',
          displayName: 'Grupo Manual',
          enabled: true,
        },
        source: 'manual',
        hasManualOverride: true,
      },
    ]);
  });
});
