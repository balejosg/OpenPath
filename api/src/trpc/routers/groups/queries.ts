import { TRPCError } from '@trpc/server';
import { z } from 'zod';

import { adminProcedure, teacherProcedure } from '../../trpc.js';
import { GroupsService } from '../../../services/groups.service.js';
import { ListRulesGroupedSchema, ListRulesPaginatedSchema, ListRulesSchema } from './schemas.js';
import { teacherViewGroupIdProcedure, throwServiceError } from './procedures.js';

export const groupQueryProcedures = {
  list: teacherProcedure.query(async ({ ctx }) => {
    return await GroupsService.listGroupsVisibleToUser(ctx.user);
  }),

  libraryList: teacherProcedure.query(async () => {
    return await GroupsService.listLibraryGroups();
  }),

  getById: teacherProcedure
    .input(z.object({ id: z.string().min(1) }))
    .query(async ({ input, ctx }) => {
      const result = await GroupsService.getGroupById(input.id);
      if (!result.ok) {
        throwServiceError(result.error);
      }

      if (!GroupsService.canUserViewGroup(ctx.user, result.data)) {
        throw new TRPCError({ code: 'FORBIDDEN', message: 'You do not have access to this group' });
      }

      return result.data;
    }),

  getByName: teacherProcedure
    .input(z.object({ name: z.string().min(1) }))
    .query(async ({ input, ctx }) => {
      const result = await GroupsService.getGroupByName(input.name);
      if (!result.ok) {
        throwServiceError(result.error);
      }

      if (!GroupsService.canUserViewGroup(ctx.user, result.data)) {
        throw new TRPCError({ code: 'FORBIDDEN', message: 'You do not have access to this group' });
      }

      return result.data;
    }),

  listRules: teacherViewGroupIdProcedure(ListRulesSchema).query(async ({ input }) => {
    const result = await GroupsService.listRules(input.groupId, input.type, input.enabled);
    if (!result.ok) {
      throwServiceError(result.error);
    }
    return result.data;
  }),

  listRulesPaginated: teacherViewGroupIdProcedure(ListRulesPaginatedSchema).query(
    async ({ input }) => {
      const result = await GroupsService.listRulesPaginated({
        groupId: input.groupId,
        type: input.type,
        enabled: input.enabled,
        limit: input.limit,
        offset: input.offset,
        search: input.search,
      });
      if (!result.ok) {
        throwServiceError(result.error);
      }
      return result.data;
    }
  ),

  listRulesGrouped: teacherViewGroupIdProcedure(ListRulesGroupedSchema).query(async ({ input }) => {
    const result = await GroupsService.listRulesGrouped({
      groupId: input.groupId,
      type: input.type,
      enabled: input.enabled,
      limit: input.limit,
      offset: input.offset,
      search: input.search,
    });
    if (!result.ok) {
      throwServiceError(result.error);
    }
    return result.data;
  }),

  stats: adminProcedure.query(async () => {
    return GroupsService.getStats();
  }),

  systemStatus: adminProcedure.query(async () => {
    return GroupsService.getSystemStatus();
  }),

  export: teacherViewGroupIdProcedure(z.object({ groupId: z.string().min(1) })).query(
    async ({ input }) => {
      const result = await GroupsService.exportGroup(input.groupId);
      if (!result.ok) {
        throwServiceError(result.error);
      }
      return result.data;
    }
  ),

  exportAll: adminProcedure.query(async () => {
    return GroupsService.exportAllGroups();
  }),
};
