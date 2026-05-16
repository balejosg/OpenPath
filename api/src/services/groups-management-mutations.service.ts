import { v4 as uuidv4 } from 'uuid';
import { sanitizeSlug } from '@openpath/shared/slug';

import DomainEventsService from './domain-events.service.js';
import type {
  CloneGroupInput,
  CreateGroupInput,
  GroupsResult,
  UpdateGroupInput,
} from './groups-service-shared.js';
import {
  defaultManagementDependencies,
  type GroupsManagementDependencies,
} from './groups-management-shared.js';
import type { GroupVisibility, GroupWithCounts, SystemStatus } from '../lib/groups-storage.js';

function sanitizeGroupName(raw: string): string {
  return sanitizeSlug(raw, { maxLength: 100, allowUnderscore: true });
}

async function findAvailableGroupName(
  baseName: string,
  deps: Pick<GroupsManagementDependencies, 'getGroupMetaByName'> = defaultManagementDependencies
): Promise<string> {
  const trimmedBase = sanitizeGroupName(baseName);
  if (!trimmedBase) {
    return `group-${uuidv4().slice(0, 8)}`;
  }

  const maxAttempts = 50;
  for (let i = 0; i < maxAttempts; i += 1) {
    const suffix = i === 0 ? '' : `-${String(i + 1)}`;
    const candidate = `${trimmedBase}${suffix}`.slice(0, 100).replace(/-+$/g, '');
    const exists = await deps.getGroupMetaByName(candidate);
    if (!exists) {
      return candidate;
    }
  }

  return `${trimmedBase}-${uuidv4().slice(0, 8)}`.slice(0, 100).replace(/-+$/g, '');
}

export async function createGroup(
  input: CreateGroupInput,
  deps: Pick<GroupsManagementDependencies, 'createGroup'> = defaultManagementDependencies
): Promise<GroupsResult<{ id: string; name: string }>> {
  if (!input.name || input.name.trim() === '') {
    return { ok: false, error: { code: 'BAD_REQUEST', message: 'Name is required' } };
  }
  if (!input.displayName || input.displayName.trim() === '') {
    return { ok: false, error: { code: 'BAD_REQUEST', message: 'Display name is required' } };
  }

  const safeName = sanitizeGroupName(input.name);
  if (!safeName) {
    return { ok: false, error: { code: 'BAD_REQUEST', message: 'Name is invalid' } };
  }

  try {
    const rawVisibility: unknown = input.visibility;
    const visibility =
      rawVisibility === 'private' || rawVisibility === 'instance_public'
        ? rawVisibility
        : undefined;
    const createOptions: {
      ownerUserId?: string | null;
      visibility?: GroupVisibility;
    } = {};
    if (visibility !== undefined) {
      createOptions.visibility = visibility;
    }
    if (input.ownerUserId !== undefined) {
      createOptions.ownerUserId = input.ownerUserId;
    }

    const id = await deps.createGroup(safeName, input.displayName, createOptions);
    return { ok: true, data: { id, name: safeName } };
  } catch (error) {
    if (error instanceof Error && error.message === 'UNIQUE_CONSTRAINT_VIOLATION') {
      return {
        ok: false,
        error: { code: 'CONFLICT', message: 'A group with this name already exists' },
      };
    }

    throw error;
  }
}

export async function updateGroup(
  input: UpdateGroupInput,
  deps: Pick<
    GroupsManagementDependencies,
    'getGroupById' | 'publishWhitelistChanged' | 'updateGroup'
  > = defaultManagementDependencies
): Promise<GroupsResult<GroupWithCounts>> {
  const existing = await deps.getGroupById(input.id);
  if (!existing) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Group not found' } };
  }

  const dispatcher = DomainEventsService.createDispatcher({
    publishWhitelistChanged: deps.publishWhitelistChanged,
  });
  const updated = await DomainEventsService.withQueuedEvents(async (events) => {
    await deps.updateGroup(input.id, input.displayName, input.enabled, input.visibility);

    const refreshed = await deps.getGroupById(input.id);
    if (!refreshed) {
      return null;
    }

    if (existing.enabled !== input.enabled) {
      events.publishWhitelistChanged(input.id);
    }

    return refreshed;
  }, dispatcher);
  if (!updated) {
    return {
      ok: false,
      error: { code: 'INTERNAL_SERVER_ERROR', message: 'Failed to fetch updated group' },
    };
  }

  return { ok: true, data: updated };
}

export async function deleteGroup(
  id: string,
  deps: Pick<
    GroupsManagementDependencies,
    'deleteGroup' | 'getGroupById' | 'publishWhitelistChanged' | 'removeGroupFromAllRoles'
  > = defaultManagementDependencies
): Promise<GroupsResult<{ deleted: boolean }>> {
  const existing = await deps.getGroupById(id);
  if (!existing) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Group not found' } };
  }

  const dispatcher = DomainEventsService.createDispatcher({
    publishWhitelistChanged: deps.publishWhitelistChanged,
  });
  const deleted = await DomainEventsService.withQueuedEvents(async (events) => {
    const didDelete = await deps.deleteGroup(id);
    if (didDelete) {
      await deps.removeGroupFromAllRoles(id);
      events.publishWhitelistChanged(id);
    }
    return didDelete;
  }, dispatcher);

  return { ok: true, data: { deleted } };
}

export async function cloneGroup(
  input: CloneGroupInput,
  deps: Pick<
    GroupsManagementDependencies,
    | 'copyRulesToGroup'
    | 'createGroup'
    | 'getGroupById'
    | 'getGroupMetaByName'
    | 'publishWhitelistChanged'
    | 'touchGroupUpdatedAt'
    | 'withTransaction'
  > = defaultManagementDependencies
): Promise<GroupsResult<{ id: string; name: string }>> {
  const source = await deps.getGroupById(input.sourceGroupId);
  if (!source) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Group not found' } };
  }

  const trimmedName = input.name?.trim();
  const baseName = trimmedName ?? `${source.name}-copy`;
  const name = await findAvailableGroupName(baseName, deps);

  try {
    const id = await DomainEventsService.writeTransactionalCommand(
      {
        publishers: {
          publishWhitelistChanged: deps.publishWhitelistChanged,
        },
        transactionRunner: deps.withTransaction,
      },
      async (tx, events) => {
        const createdGroupId = await deps.createGroup(
          name,
          input.displayName,
          {
            visibility: 'private',
            ownerUserId: input.ownerUserId,
          },
          tx
        );

        await deps.copyRulesToGroup({ fromGroupId: source.id, toGroupId: createdGroupId }, tx);
        await deps.touchGroupUpdatedAt(createdGroupId, tx);
        events.publishWhitelistChanged(createdGroupId);
        return createdGroupId;
      }
    );

    return { ok: true, data: { id, name } };
  } catch (error) {
    if (error instanceof Error && error.message === 'UNIQUE_CONSTRAINT_VIOLATION') {
      return {
        ok: false,
        error: { code: 'CONFLICT', message: 'A group with this name already exists' },
      };
    }

    throw error;
  }
}

export async function toggleSystemStatus(
  enable: boolean,
  deps: Pick<
    GroupsManagementDependencies,
    'publishAllWhitelistsChanged' | 'toggleSystemStatus'
  > = defaultManagementDependencies
): Promise<SystemStatus> {
  const dispatcher = DomainEventsService.createDispatcher({
    publishAllWhitelistsChanged: deps.publishAllWhitelistsChanged,
  });

  return DomainEventsService.withQueuedEvents(async (events) => {
    const result = await deps.toggleSystemStatus(enable);
    events.publishAllWhitelistsChanged();
    return result;
  }, dispatcher);
}
