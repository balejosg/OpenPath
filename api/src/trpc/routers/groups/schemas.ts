import { z } from 'zod';
import { validateRuleValue } from '@openpath/shared/rules-validation';

export const RuleTypeSchema = z.enum(['whitelist', 'blocked_subdomain', 'blocked_path']);
export const RuleSourceSchema = z.enum(['manual', 'auto_extension']);
export const GroupVisibilitySchema = z.enum(['private', 'instance_public']);

export const CreateGroupSchema = z.object({
  name: z.string().min(1).max(100),
  displayName: z.string().min(1).max(255),
});

export const CloneGroupSchema = z.object({
  sourceGroupId: z.string().min(1),
  name: z.string().min(1).max(100).optional(),
  displayName: z.string().min(1).max(255).optional(),
});

export const UpdateGroupSchema = z.object({
  id: z.string().min(1),
  displayName: z.string().min(1).max(255),
  enabled: z.boolean(),
  visibility: GroupVisibilitySchema.optional(),
});

export const ListRulesSchema = z.object({
  groupId: z.string().min(1),
  type: RuleTypeSchema.optional(),
  source: RuleSourceSchema.optional(),
  enabled: z.boolean().optional(),
});

export const ListRulesPaginatedSchema = z.object({
  groupId: z.string().min(1),
  type: RuleTypeSchema.optional(),
  source: RuleSourceSchema.optional(),
  enabled: z.boolean().optional(),
  limit: z.number().min(1).max(100).optional().default(50),
  offset: z.number().min(0).optional().default(0),
  search: z.string().optional(),
});

export const ListRulesGroupedSchema = z.object({
  groupId: z.string().min(1),
  type: RuleTypeSchema.optional(),
  source: RuleSourceSchema.optional(),
  enabled: z.boolean().optional(),
  limit: z.number().min(1).max(50).optional().default(20),
  offset: z.number().min(0).optional().default(0),
  search: z.string().optional(),
});

export const UpdateRuleSchema = z.object({
  id: z.string().min(1),
  groupId: z.string().min(1),
  value: z.string().min(1).max(500).optional(),
  comment: z.string().max(500).nullable().optional(),
});

export const DeleteRuleSchema = z.object({
  id: z.string().min(1),
  groupId: z.string().optional(),
});

export const RevokeAutoApprovalSchema = z.object({
  id: z.string().min(1),
  groupId: z.string().min(1),
});

export const CreateRuleSchema = z
  .object({
    groupId: z.string().min(1),
    type: RuleTypeSchema,
    value: z.string().min(1).max(500),
    comment: z.string().max(500).optional(),
  })
  .superRefine((data, ctx) => {
    const result = validateRuleValue(data.value, data.type);
    if (!result.valid) {
      ctx.addIssue({
        code: 'custom',
        path: ['value'],
        message: result.error ?? 'Invalid rule value',
      });
    }
  });

export const BulkCreateRulesSchema = z
  .object({
    groupId: z.string().min(1),
    type: RuleTypeSchema,
    values: z.array(z.string().min(1).max(500)),
  })
  .superRefine((data, ctx) => {
    data.values.forEach((value, index) => {
      const result = validateRuleValue(value, data.type);
      if (!result.valid) {
        ctx.addIssue({
          code: 'custom',
          path: ['values', index],
          message: result.error ?? 'Invalid rule value',
        });
      }
    });
  });

export const BulkDeleteRulesSchema = z.object({
  ids: z.array(z.string().min(1)).min(1).max(100),
});

export const SetRuleEnabledSchema = z.object({
  id: z.string().min(1),
  groupId: z.string().min(1),
  enabled: z.boolean(),
});

export const BulkSetRulesEnabledSchema = z.object({
  ids: z.array(z.string().min(1)).min(1).max(100),
  enabled: z.boolean(),
});
