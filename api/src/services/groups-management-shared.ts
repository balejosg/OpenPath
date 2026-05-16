import * as groupsStorage from '../lib/groups-storage.js';
import { removeGroupFromAllRoles } from '../lib/role-storage-command.js';
import { withTransaction } from '../db/index.js';

import DomainEventsService from './domain-events.service.js';

export interface GroupsManagementDependencies {
  createGroup: typeof groupsStorage.createGroup;
  copyRulesToGroup: typeof groupsStorage.copyRulesToGroup;
  deleteGroup: typeof groupsStorage.deleteGroup;
  exportAllGroups: typeof groupsStorage.exportAllGroups;
  exportGroup: typeof groupsStorage.exportGroup;
  getGroupById: typeof groupsStorage.getGroupById;
  getGroupMetaByName: typeof groupsStorage.getGroupMetaByName;
  getStats: typeof groupsStorage.getStats;
  getSystemStatus: typeof groupsStorage.getSystemStatus;
  publishAllWhitelistsChanged: () => void;
  publishWhitelistChanged: (groupId: string) => void;
  removeGroupFromAllRoles: typeof removeGroupFromAllRoles;
  toggleSystemStatus: typeof groupsStorage.toggleSystemStatus;
  touchGroupUpdatedAt: typeof groupsStorage.touchGroupUpdatedAt;
  updateGroup: typeof groupsStorage.updateGroup;
  withTransaction: typeof withTransaction;
}

export const defaultManagementDependencies: GroupsManagementDependencies = {
  createGroup: groupsStorage.createGroup,
  copyRulesToGroup: groupsStorage.copyRulesToGroup,
  deleteGroup: groupsStorage.deleteGroup,
  exportAllGroups: groupsStorage.exportAllGroups,
  exportGroup: groupsStorage.exportGroup,
  getGroupById: groupsStorage.getGroupById,
  getGroupMetaByName: groupsStorage.getGroupMetaByName,
  getStats: groupsStorage.getStats,
  getSystemStatus: groupsStorage.getSystemStatus,
  publishAllWhitelistsChanged:
    DomainEventsService.publishAllWhitelistsChanged.bind(DomainEventsService),
  publishWhitelistChanged: DomainEventsService.publishWhitelistChanged.bind(DomainEventsService),
  removeGroupFromAllRoles,
  toggleSystemStatus: groupsStorage.toggleSystemStatus,
  touchGroupUpdatedAt: groupsStorage.touchGroupUpdatedAt,
  updateGroup: groupsStorage.updateGroup,
  withTransaction,
};
