import {
  getRuleById,
  getRulesByIds,
  listRules,
  listRulesGrouped,
  listRulesPaginated,
} from './groups-rules-query.service.js';
import {
  bulkCreateRules,
  bulkDeleteRules,
  bulkSetRulesEnabled,
  createRule,
  deleteRule,
  setRuleEnabled,
  updateRule,
} from './groups-rules-mutations.service.js';

export {
  bulkCreateRules,
  bulkDeleteRules,
  bulkSetRulesEnabled,
  createRule,
  deleteRule,
  getRuleById,
  getRulesByIds,
  listRules,
  listRulesGrouped,
  listRulesPaginated,
  setRuleEnabled,
  updateRule,
};

export const GroupsRulesService = {
  bulkCreateRules,
  bulkDeleteRules,
  bulkSetRulesEnabled,
  createRule,
  deleteRule,
  getRuleById,
  getRulesByIds,
  listRules,
  listRulesGrouped,
  listRulesPaginated,
  setRuleEnabled,
  updateRule,
};

export default GroupsRulesService;
