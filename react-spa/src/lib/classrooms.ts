import {
  inferGroupSource,
  resolveGroupLike,
  type GroupLike,
} from '../components/groups/GroupLabel';
import type { Classroom, CurrentGroupSource } from '../types';
import { trpc } from './trpc';

export type ClassroomListItem = Awaited<ReturnType<typeof trpc.classrooms.list.query>>[number];

export interface ClassroomListMetadata {
  defaultGroupDisplayName: string | null;
  currentGroupDisplayName: string | null;
}

export interface ClassroomControlState {
  id: string;
  name: string;
  displayName: string;
  defaultGroupId: string | null;
  defaultGroupDisplayName: string | null;
  activeGroupId: string | null;
  currentGroupId: string | null;
  currentGroupDisplayName: string | null;
  currentGroupSource: CurrentGroupSource | null;
}

export interface ClassroomListModel {
  id: string;
  name: string;
  displayName: string;
  defaultGroupId: string | null;
  defaultGroupDisplayName: string | null;
  machineCount: number;
  activeGroupId: string | null;
  currentGroupId: string | null;
  currentGroupDisplayName: string | null;
  currentGroupSource: CurrentGroupSource | null;
  status: Classroom['status'];
  onlineMachineCount: number;
  captivePortalDomains?: string[];
  machines: Classroom['machines'];
}

export interface ActiveClassroomRow {
  classroomId: string;
  classroomName: string;
  groupId: string;
  group: GroupLike | null;
  source: CurrentGroupSource;
  hasManualOverride: boolean;
}

function readOptionalStringField(item: unknown, key: keyof ClassroomListMetadata): string | null {
  if (!item || typeof item !== 'object') {
    return null;
  }

  const value = (item as Record<string, unknown>)[key];
  return typeof value === 'string' ? value : null;
}

export function readClassroomListMetadata(item: ClassroomListItem): ClassroomListMetadata {
  return {
    defaultGroupDisplayName: readOptionalStringField(item, 'defaultGroupDisplayName'),
    currentGroupDisplayName: readOptionalStringField(item, 'currentGroupDisplayName'),
  };
}

export function toClassroomListModel(item: ClassroomListItem): ClassroomListModel {
  const metadata = readClassroomListMetadata(item);

  return {
    id: item.id,
    name: item.name,
    displayName: item.displayName,
    defaultGroupId: item.defaultGroupId ?? null,
    defaultGroupDisplayName: metadata.defaultGroupDisplayName,
    machineCount: item.machineCount,
    activeGroupId: item.activeGroupId ?? null,
    currentGroupId: item.currentGroupId ?? null,
    currentGroupDisplayName: metadata.currentGroupDisplayName,
    currentGroupSource: item.currentGroupSource,
    status: item.status,
    onlineMachineCount: item.onlineMachineCount,
    captivePortalDomains: item.captivePortalDomains,
    machines: item.machines,
  };
}

export function toClassroomListModels(items: readonly ClassroomListItem[]): ClassroomListModel[] {
  return items.map(toClassroomListModel);
}

export function toClassroomFromModel(model: ClassroomListModel): Classroom {
  return {
    id: model.id,
    name: model.name,
    displayName: model.displayName,
    defaultGroupId: model.defaultGroupId,
    defaultGroupDisplayName: model.defaultGroupDisplayName,
    computerCount: model.machineCount,
    activeGroup: model.activeGroupId,
    currentGroupId: model.currentGroupId,
    currentGroupDisplayName: model.currentGroupDisplayName,
    currentGroupSource: model.currentGroupSource ?? undefined,
    status: model.status,
    onlineMachineCount: model.onlineMachineCount,
    captivePortalDomains: model.captivePortalDomains ?? [],
    machines: model.machines,
  };
}

export function toClassroom(item: ClassroomListItem): Classroom {
  return toClassroomFromModel(toClassroomListModel(item));
}

export function toClassroomsFromModels(models: readonly ClassroomListModel[]): Classroom[] {
  return models.map(toClassroomFromModel);
}

export function toClassrooms(items: readonly ClassroomListItem[]): Classroom[] {
  return toClassroomsFromModels(toClassroomListModels(items));
}

export function toClassroomControlStateFromModel(model: ClassroomListModel): ClassroomControlState {
  return {
    id: model.id,
    name: model.name,
    displayName: model.displayName,
    defaultGroupId: model.defaultGroupId,
    defaultGroupDisplayName: model.defaultGroupDisplayName,
    activeGroupId: model.activeGroupId,
    currentGroupId: model.currentGroupId,
    currentGroupDisplayName: model.currentGroupDisplayName,
    currentGroupSource: model.currentGroupSource,
  };
}

export function toClassroomControlState(item: ClassroomListItem): ClassroomControlState {
  return toClassroomControlStateFromModel(toClassroomListModel(item));
}

export function toClassroomControlStatesFromModels(
  models: readonly ClassroomListModel[]
): ClassroomControlState[] {
  return models.map(toClassroomControlStateFromModel);
}

export function toClassroomControlStates(
  items: readonly ClassroomListItem[]
): ClassroomControlState[] {
  return toClassroomControlStatesFromModels(toClassroomListModels(items));
}

export function toActiveClassroomRows(
  classrooms: readonly ClassroomControlState[],
  groupById: ReadonlyMap<string, GroupLike>
): ActiveClassroomRow[] {
  return classrooms
    .map((classroom) => {
      const groupId = classroom.currentGroupId;
      if (!groupId) {
        return null;
      }

      return {
        classroomId: classroom.id,
        classroomName: classroom.displayName || classroom.name,
        groupId,
        group: resolveGroupLike({
          groupId,
          groupById,
          displayName: classroom.currentGroupDisplayName,
        }),
        source: inferGroupSource({
          currentGroupSource: classroom.currentGroupSource,
          activeGroupId: classroom.activeGroupId,
          currentGroupId: classroom.currentGroupId,
          defaultGroupId: classroom.defaultGroupId,
        }),
        hasManualOverride: !!classroom.activeGroupId,
      };
    })
    .filter((row): row is ActiveClassroomRow => row !== null)
    .sort((a, b) => a.classroomName.localeCompare(b.classroomName));
}
