import { teacherProcedure } from '../../trpc.js';
import * as auth from '../../../lib/auth.js';
import { GroupsService } from '../../../services/groups.service.js';
import {
  assertCanAccessGroupId,
  teacherGroupIdProcedure,
  throwServiceError,
} from './procedures.js';
import {
  BulkCreateRulesSchema,
  BulkDeleteRulesSchema,
  BulkSetRulesEnabledSchema,
  CreateRuleSchema,
  DeleteRuleSchema,
  SetRuleEnabledSchema,
  UpdateRuleSchema,
} from './schemas.js';

export const groupRuleProcedures = {
  createRule: teacherGroupIdProcedure(CreateRuleSchema).mutation(async ({ input }) => {
    const result = await GroupsService.createRule({
      groupId: input.groupId,
      type: input.type,
      value: input.value,
      comment: input.comment,
    });
    if (!result.ok) {
      throwServiceError(result.error);
    }
    return result.data;
  }),

  deleteRule: teacherProcedure.input(DeleteRuleSchema).mutation(async ({ input, ctx }) => {
    let resolvedGroupId = input.groupId;

    if (!auth.isAdminToken(ctx.user)) {
      const rule = await GroupsService.getRuleById(input.id);
      resolvedGroupId = rule?.groupId;

      if (resolvedGroupId) {
        await assertCanAccessGroupId(ctx.user, resolvedGroupId);
      }
    }

    const result = await GroupsService.deleteRule(input.id, resolvedGroupId);
    if (!result.ok) {
      throwServiceError(result.error);
    }
    return result.data;
  }),

  updateRule: teacherGroupIdProcedure(UpdateRuleSchema).mutation(async ({ input }) => {
    const result = await GroupsService.updateRule({
      id: input.id,
      groupId: input.groupId,
      value: input.value,
      comment: input.comment,
    });
    if (!result.ok) {
      throwServiceError(result.error);
    }
    return result.data;
  }),

  bulkCreateRules: teacherGroupIdProcedure(BulkCreateRulesSchema).mutation(async ({ input }) => {
    const result = await GroupsService.bulkCreateRules({
      groupId: input.groupId,
      type: input.type,
      values: input.values,
    });
    if (!result.ok) {
      throwServiceError(result.error);
    }
    return result.data;
  }),

  bulkDeleteRules: teacherProcedure
    .input(BulkDeleteRulesSchema)
    .mutation(async ({ input, ctx }) => {
      let preloadedRules: Awaited<ReturnType<typeof GroupsService.getRulesByIds>> | undefined;

      if (!auth.isAdminToken(ctx.user)) {
        preloadedRules = await GroupsService.getRulesByIds(input.ids);
        const groupIds = new Set(preloadedRules.map((rule) => rule.groupId));
        for (const groupId of groupIds) {
          await assertCanAccessGroupId(ctx.user, groupId);
        }
      }

      const result = await GroupsService.bulkDeleteRules(
        input.ids,
        preloadedRules ? { rules: preloadedRules } : undefined
      );
      if (!result.ok) {
        throwServiceError(result.error);
      }
      return result.data;
    }),

  setRuleEnabled: teacherGroupIdProcedure(SetRuleEnabledSchema).mutation(async ({ input }) => {
    const result = await GroupsService.setRuleEnabled({
      id: input.id,
      groupId: input.groupId,
      enabled: input.enabled,
    });
    if (!result.ok) throwServiceError(result.error);
    return result.data;
  }),

  bulkSetRulesEnabled: teacherProcedure
    .input(BulkSetRulesEnabledSchema)
    .mutation(async ({ input, ctx }) => {
      let preloadedRules: Awaited<ReturnType<typeof GroupsService.getRulesByIds>> | undefined;
      if (!auth.isAdminToken(ctx.user)) {
        preloadedRules = await GroupsService.getRulesByIds(input.ids);
        for (const groupId of new Set(preloadedRules.map((r) => r.groupId))) {
          await assertCanAccessGroupId(ctx.user, groupId);
        }
      }
      const result = await GroupsService.bulkSetRulesEnabled(
        input.ids,
        input.enabled,
        preloadedRules ? { rules: preloadedRules } : undefined
      );
      if (!result.ok) throwServiceError(result.error);
      return result.data;
    }),
};
