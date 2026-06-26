import { resolveGroupDisplayName, type GroupLike } from '../components/groups/GroupLabel';
import type { Classroom } from '../types';
import type { ProductT } from '../i18n/product-i18n';
import {
  toActiveClassroomRows,
  toClassroomsFromModels,
  type ActiveClassroomRow,
  type ClassroomListModel,
} from './classrooms';
import { normalizeSearchTerm } from './search';

export interface ClassroomControlConfirmation {
  classroomId: string;
  nextGroupId: string | null;
  currentName: string;
  nextName: string;
}

export function filterClassroomsBySearch(
  classrooms: readonly Classroom[],
  normalizedSearchQuery: string
): Classroom[] {
  if (!normalizedSearchQuery) {
    return [...classrooms];
  }

  return classrooms.filter(
    (room) =>
      normalizeSearchTerm(room.name).includes(normalizedSearchQuery) ||
      (room.activeGroup
        ? normalizeSearchTerm(room.activeGroup).includes(normalizedSearchQuery)
        : false)
  );
}

export function selectFilteredClassroomsFromModels(
  classrooms: readonly ClassroomListModel[],
  normalizedSearchQuery: string
): Classroom[] {
  return filterClassroomsBySearch(toClassroomsFromModels(classrooms), normalizedSearchQuery);
}

export function selectActiveClassroomRowsFromModels(
  classrooms: readonly ClassroomListModel[],
  groupById: ReadonlyMap<string, GroupLike>
): ActiveClassroomRow[] {
  return toActiveClassroomRows(classrooms, groupById);
}

export function selectClassroomControlConfirmation(params: {
  classrooms: readonly ClassroomListModel[];
  groupById: ReadonlyMap<string, GroupLike>;
  classroomId: string;
  nextGroupId: string | null;
  t: ProductT;
}): ClassroomControlConfirmation | null {
  const classroom = params.classrooms.find((item) => item.id === params.classroomId);
  const currentActiveGroupId = classroom?.activeGroupId ?? null;

  if (!currentActiveGroupId || currentActiveGroupId === params.nextGroupId) {
    return null;
  }

  const currentGroup = params.groupById.get(currentActiveGroupId);
  const nextGroup = params.nextGroupId ? params.groupById.get(params.nextGroupId) : null;

  return {
    classroomId: params.classroomId,
    nextGroupId: params.nextGroupId,
    currentName: resolveGroupDisplayName({
      groupId: currentActiveGroupId,
      group: currentGroup ?? null,
      source: 'manual',
      revealUnknownId: false,
      t: params.t,
    }),
    nextName: resolveGroupDisplayName({
      groupId: params.nextGroupId,
      group: nextGroup ?? null,
      source: 'manual',
      noneLabel: params.t('groups.label.noGroup'),
      revealUnknownId: true,
      t: params.t,
    }),
  };
}
