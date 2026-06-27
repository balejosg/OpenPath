/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * GroupsService - Business logic for whitelist groups and rules management
 */

import {
  canUserAccessGroup,
  canUserViewGroup,
  ensureUserCanAccessGroupId,
  ensureUserCanViewGroupId,
  getGroupById,
  getGroupByName,
  listGroups,
  listGroupsVisibleToUser,
  listLibraryGroups,
} from './groups-access.service.js';
import {
  cloneGroup,
  createGroup,
  deleteGroup,
  exportAllGroups,
  exportGroup,
  getStats,
  getSystemStatus,
  toggleSystemStatus,
  updateGroup,
} from './groups-management.service.js';
import {
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
  revokeAutoApproval,
  setRuleEnabled,
  updateRule,
} from './groups-rules.service.js';
export type {
  BulkCreateRulesInput,
  CloneGroupInput,
  CreateGroupInput,
  CreateRuleInput,
  ExportResult,
  GroupsResult,
  GroupsServiceError,
  UpdateGroupInput,
  UpdateRuleInput,
} from './groups-service-shared.js';

// =============================================================================
// Types
// =============================================================================

// =============================================================================
// Service Implementation
// =============================================================================

// =============================================================================
// Default Export
// =============================================================================

export const GroupsService = {
  listGroups,
  listGroupsVisibleToUser,
  listLibraryGroups,
  canUserAccessGroup,
  canUserViewGroup,
  ensureUserCanAccessGroupId,
  ensureUserCanViewGroupId,
  getGroupById,
  getGroupByName,
  createGroup,
  cloneGroup,
  updateGroup,
  deleteGroup,
  listRules,
  listRulesPaginated,
  listRulesGrouped,
  getRuleById,
  getRulesByIds,
  createRule,
  updateRule,
  deleteRule,
  bulkCreateRules,
  bulkDeleteRules,
  setRuleEnabled,
  bulkSetRulesEnabled,
  revokeAutoApproval,
  getStats,
  getSystemStatus,
  toggleSystemStatus,
  exportGroup,
  exportAllGroups,
};

export default GroupsService;
