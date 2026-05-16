import { createTRPCWithAuth } from './trpc.js';
import type {
  ApiClient,
  Group,
  GroupStats,
  Rule,
  RuleType,
  SystemStatus,
} from './api-client-types.js';

export function createApiClient(token: string): ApiClient {
  const trpc = createTRPCWithAuth(token);

  return {
    getAllGroups(): Promise<Group[]> {
      return trpc.groups.list.query();
    },

    async getGroupById(id: string): Promise<Group | null> {
      try {
        return await trpc.groups.getById.query({ id });
      } catch {
        return null;
      }
    },

    async getGroupByName(name: string): Promise<Group | null> {
      try {
        return await trpc.groups.getByName.query({ name });
      } catch {
        return null;
      }
    },

    createGroup(name: string, displayName: string): Promise<{ id: string; name: string }> {
      return trpc.groups.create.mutate({ name, displayName });
    },

    updateGroup(id: string, displayName: string, enabled: boolean): Promise<Group> {
      return trpc.groups.update.mutate({ id, displayName, enabled });
    },

    async deleteGroup(id: string): Promise<boolean> {
      const result = await trpc.groups.delete.mutate({ id });
      return result.deleted;
    },

    getRulesByGroup(groupId: string, type?: RuleType): Promise<Rule[]> {
      return trpc.groups.listRules.query(type === undefined ? { groupId } : { groupId, type });
    },

    createRule(
      groupId: string,
      type: RuleType,
      value: string,
      comment?: string
    ): Promise<{ id: string }> {
      return trpc.groups.createRule.mutate(
        comment === undefined ? { groupId, type, value } : { groupId, type, value, comment }
      );
    },

    async deleteRule(id: string): Promise<boolean> {
      const result = await trpc.groups.deleteRule.mutate({ id });
      return result.deleted;
    },

    async bulkCreateRules(groupId: string, type: RuleType, values: string[]): Promise<number> {
      const result = await trpc.groups.bulkCreateRules.mutate({ groupId, type, values });
      return result.count;
    },

    getStats(): Promise<GroupStats> {
      return trpc.groups.stats.query();
    },

    getSystemStatus(): Promise<SystemStatus> {
      return trpc.groups.systemStatus.query();
    },

    toggleSystemStatus(enable: boolean): Promise<SystemStatus> {
      return trpc.groups.toggleSystem.mutate({ enable });
    },

    exportGroup(groupId: string): Promise<{ name: string; content: string }> {
      return trpc.groups.export.query({ groupId });
    },

    exportAllGroups(): Promise<{ name: string; content: string }[]> {
      return trpc.groups.exportAll.query();
    },
  };
}
