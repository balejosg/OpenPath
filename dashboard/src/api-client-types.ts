/** Group with rule counts (matches API response) */
export interface Group {
  id: string;
  name: string;
  displayName: string;
  enabled: boolean;
  createdAt: string;
  updatedAt: string | null;
  whitelistCount: number;
  blockedSubdomainCount: number;
  blockedPathCount: number;
}

export type RuleType = 'whitelist' | 'blocked_subdomain' | 'blocked_path' | 'allowed_path';

export interface Rule {
  id: string;
  groupId: string;
  type: RuleType;
  value: string;
  comment: string | null;
  createdAt: string;
}

export interface GroupStats {
  groupCount: number;
  whitelistCount: number;
  blockedCount: number;
}

export interface SystemStatus {
  enabled: boolean;
  totalGroups: number;
  activeGroups: number;
  pausedGroups: number;
}

export interface LoginResult {
  success: boolean;
  accessToken?: string;
  refreshToken?: string;
  user?: {
    id: string;
    email: string;
    name: string;
  };
  error?: string;
}

export interface ApiClient {
  getAllGroups(): Promise<Group[]>;
  getGroupById(id: string): Promise<Group | null>;
  getGroupByName(name: string): Promise<Group | null>;
  createGroup(name: string, displayName: string): Promise<{ id: string; name: string }>;
  updateGroup(id: string, displayName: string, enabled: boolean): Promise<Group>;
  deleteGroup(id: string): Promise<boolean>;
  getRulesByGroup(groupId: string, type?: RuleType): Promise<Rule[]>;
  createRule(
    groupId: string,
    type: RuleType,
    value: string,
    comment?: string
  ): Promise<{ id: string }>;
  deleteRule(id: string): Promise<boolean>;
  bulkCreateRules(groupId: string, type: RuleType, values: string[]): Promise<number>;
  getStats(): Promise<GroupStats>;
  getSystemStatus(): Promise<SystemStatus>;
  toggleSystemStatus(enable: boolean): Promise<SystemStatus>;
  exportGroup(groupId: string): Promise<{ name: string; content: string }>;
  exportAllGroups(): Promise<{ name: string; content: string }[]>;
}

export interface DashboardAuthUser {
  id: string;
  email: string;
  name: string;
}

export interface DashboardAuthLoginPayload {
  accessToken: string;
  refreshToken: string;
  user?: DashboardAuthUser;
}

export interface DashboardAuthRefreshPayload {
  accessToken: string;
  refreshToken: string;
}

export interface DashboardGroupsClientContract {
  list: { query(): Promise<Group[]> };
  getById: { query(input: { id: string }): Promise<Group> };
  getByName: { query(input: { name: string }): Promise<Group> };
  create: {
    mutate(input: { name: string; displayName: string }): Promise<{ id: string; name: string }>;
  };
  update: {
    mutate(input: { id: string; displayName: string; enabled: boolean }): Promise<Group>;
  };
  delete: { mutate(input: { id: string }): Promise<{ deleted: boolean }> };
  listRules: { query(input: { groupId: string; type?: RuleType }): Promise<Rule[]> };
  createRule: {
    mutate(input: {
      groupId: string;
      type: RuleType;
      value: string;
      comment?: string;
    }): Promise<{ id: string }>;
  };
  deleteRule: { mutate(input: { id: string }): Promise<{ deleted: boolean }> };
  bulkCreateRules: {
    mutate(input: {
      groupId: string;
      type: RuleType;
      values: string[];
    }): Promise<{ count: number }>;
  };
  stats: { query(): Promise<GroupStats> };
  systemStatus: { query(): Promise<SystemStatus> };
  toggleSystem: { mutate(input: { enable: boolean }): Promise<SystemStatus> };
  export: { query(input: { groupId: string }): Promise<{ name: string; content: string }> };
  exportAll: { query(): Promise<{ name: string; content: string }[]> };
}

export interface DashboardAuthClientContract {
  login: { mutate(input: { email: string; password: string }): Promise<DashboardAuthLoginPayload> };
  refresh: {
    mutate(input: { refreshToken: string }): Promise<DashboardAuthRefreshPayload>;
  };
  logout: { mutate(input: { refreshToken: string }): Promise<unknown> };
  changePassword: {
    mutate(input: { currentPassword: string; newPassword: string }): Promise<unknown>;
  };
}

export interface DashboardTrpcClientContract {
  auth: DashboardAuthClientContract;
  groups: DashboardGroupsClientContract;
}
