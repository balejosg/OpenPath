import * as groupsStorage from '../lib/groups-storage.js';
import { withTransaction } from '../db/index.js';

import DomainEventsService from './domain-events.service.js';
import type { GroupsResult } from './groups-service-shared.js';

export interface GroupsRulesDependencies {
  bulkDeleteRules: typeof groupsStorage.bulkDeleteRules;
  bulkCreateRules?: typeof groupsStorage.bulkCreateRules;
  createRule: typeof groupsStorage.createRule;
  deleteRule: typeof groupsStorage.deleteRule;
  getGroupById: typeof groupsStorage.getGroupById;
  getRuleById: typeof groupsStorage.getRuleById;
  getRulesByIds: typeof groupsStorage.getRulesByIds;
  updateRule?: typeof groupsStorage.updateRule;
  setRuleEnabled?: typeof groupsStorage.setRuleEnabled;
  bulkSetRulesEnabled?: typeof groupsStorage.bulkSetRulesEnabled;
  publishWhitelistChanged: (groupId: string) => void;
  withTransaction: typeof withTransaction;
}

export const defaultRulesDependencies: GroupsRulesDependencies = {
  bulkDeleteRules: groupsStorage.bulkDeleteRules,
  bulkCreateRules: groupsStorage.bulkCreateRules,
  createRule: groupsStorage.createRule,
  deleteRule: groupsStorage.deleteRule,
  getGroupById: groupsStorage.getGroupById,
  getRuleById: groupsStorage.getRuleById,
  getRulesByIds: groupsStorage.getRulesByIds,
  updateRule: groupsStorage.updateRule,
  setRuleEnabled: groupsStorage.setRuleEnabled,
  bulkSetRulesEnabled: groupsStorage.bulkSetRulesEnabled,
  publishWhitelistChanged: DomainEventsService.publishWhitelistChanged.bind(DomainEventsService),
  withTransaction,
};

export async function ensureGroupExists(
  groupId: string,
  deps: Pick<GroupsRulesDependencies, 'getGroupById'> = defaultRulesDependencies
): Promise<GroupsResult<void>> {
  const group = await deps.getGroupById(groupId);
  if (!group) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'Group not found' } };
  }

  return { ok: true, data: undefined };
}
