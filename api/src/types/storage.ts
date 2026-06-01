/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * Storage Interface Definitions
 */

import type {
  DomainRequest,
  RequestStatus,
  User,
  SafeUser,
  Role,
  UserRole,
  Classroom,
  Machine,
  Schedule,
  PushSubscription,
  CreateRequestDTO,
  CreateUserDTO,
  CreateClassroomDTO,
} from './index.js';

// Local type aliases for internal use (resolves scope errors)
export type CreateRequestData = CreateRequestDTO;
export type CreateUserData = CreateUserDTO;
export type CreateClassroomData = CreateClassroomDTO;

// Re-export all types as named exports for external consumers
export type {
  DomainRequest,
  RequestStatus,
  User,
  SafeUser,
  Role,
  UserRole,
  Classroom,
  Machine,
  Schedule,
  PushSubscription,
};

// =============================================================================
// Request Storage
// =============================================================================

/**
 * Request statistics
 */
export interface RequestStats {
  total: number;
  pending: number;
  approved: number;
  rejected: number;
}

/**
 * Request storage interface
 */
export interface IRequestStorage {
  getAllRequests(status?: RequestStatus | null): Promise<DomainRequest[]>;
  getRequestById(id: string): Promise<DomainRequest | null>;
  getRequestsByGroup(groupId: string): Promise<DomainRequest[]>;
  hasPendingRequest(domain: string): Promise<boolean>;
  createRequest(data: CreateRequestData): Promise<DomainRequest>;
  updateRequestStatus(
    id: string,
    status: 'approved' | 'rejected',
    resolvedBy?: string,
    note?: string | null
  ): Promise<DomainRequest | null>;
  deleteRequest(id: string): Promise<boolean>;
  getStats(): Promise<RequestStats>;
}

// =============================================================================
// User Storage
// =============================================================================

/**
 * Data for updating a user
 */
export interface UpdateUserData {
  email?: string | undefined;
  name?: string | undefined;
  password?: string | undefined;
  active?: boolean | undefined;
}

/**
 * User storage interface
 */
export interface IUserStorage {
  getAllUsers(): Promise<SafeUser[]>;
  getUserById(id: string): Promise<User | null>;
  getUserByEmail(email: string): Promise<User | null>;
  createUser(
    data: CreateUserData,
    options?: {
      emailVerified?: boolean;
    }
  ): Promise<SafeUser>;
  updateUser(id: string, data: UpdateUserData): Promise<SafeUser | null>;
  deleteUser(id: string): Promise<boolean>;
  verifyPassword(user: User, password: string): Promise<boolean>;
}

// =============================================================================
// Role Storage
// =============================================================================

/**
 * Data for assigning a role
 */
export interface AssignRoleData {
  userId: string;
  role: UserRole;
  groupIds: string[];
  expiresAt?: string | null;
}

/**
 * Role storage interface
 */
export interface IRoleStorage {
  getRolesByUser(userId: string): Promise<Role[]>;
  getRoleById(roleId: string): Promise<Role | null>;
  getUsersWithRole(role: UserRole): Promise<string[]>;
  assignRole(data: AssignRoleData): Promise<Role>;
  updateRole(roleId: string, data: Partial<Role>): Promise<Role | null>;
  revokeRole(roleId: string): Promise<boolean>;
  revokeAllUserRoles(userId: string): Promise<number>;
}

// =============================================================================
// Classroom Storage
// =============================================================================

/**
 * Data for updating a classroom
 */
export interface UpdateClassroomData {
  name?: string | undefined;
  displayName?: string | undefined;
  captivePortalDomains?: string[] | undefined;
}

/**
 * Classroom storage interface
 */
export interface IClassroomStorage {
  getAllClassrooms(): Promise<Classroom[]>;
  getClassroomById(id: string): Promise<Classroom | null>;
  getClassroomByName(name: string): Promise<Classroom | null>;
  createClassroom(data: CreateClassroomData): Promise<Classroom>;
  updateClassroom(id: string, data: UpdateClassroomData): Promise<Classroom | null>;
  deleteClassroom(id: string): Promise<boolean>;
  addMachine(classroomId: string, hostname: string): Promise<Machine | null>;
  removeMachine(classroomId: string, hostname: string): Promise<boolean>;
  getMachineByHostname(
    hostname: string
  ): Promise<{ classroom: Classroom; machine: Machine } | null>;
  updateMachineStatus(hostname: string, status: 'online' | 'offline'): Promise<boolean>;
}

// =============================================================================
// Token Store
// =============================================================================

/**
 * Token store interface for blacklisting
 */
export interface ITokenStore {
  blacklist(token: string, expiresAt: Date): Promise<void>;
  isBlacklisted(token: string): Promise<boolean>;
  cleanup(): Promise<number>;
}
