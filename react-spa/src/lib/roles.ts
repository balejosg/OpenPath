import { UserRole } from '../types';
import { normalizeUserRoleString } from '@openpath/shared/roles';

export const CREATE_USER_ROLES = ['teacher', 'admin'] as const;
export type CreateUserRole = (typeof CREATE_USER_ROLES)[number];
export const DEFAULT_CREATE_USER_ROLE: CreateUserRole = 'teacher';

export const USER_ROLE_LABELS: Record<UserRole, string> = {
  [UserRole.ADMIN]: 'Admin',
  [UserRole.TEACHER]: 'Teacher',
  [UserRole.STUDENT]: 'User',
  [UserRole.NO_ROLES]: 'No Role',
};

export function mapBackendRoleToUserRole(role: string): UserRole {
  const normalized = normalizeUserRoleString(role);
  if (normalized === 'admin') return UserRole.ADMIN;
  if (normalized === 'teacher') return UserRole.TEACHER;
  if (normalized === 'student') return UserRole.STUDENT;
  return UserRole.NO_ROLES;
}

export function getPrimaryRole(roles: readonly string[]): string {
  const normalized = roles
    .map((r) => normalizeUserRoleString(r))
    .filter((r): r is 'admin' | 'teacher' | 'student' => r !== null);

  if (normalized.includes('admin')) return 'admin';
  if (normalized.includes('teacher')) return 'teacher';
  return 'student';
}

export function getRoleDisplayLabel(role: string): string {
  const normalized = normalizeUserRoleString(role);
  if (normalized === 'admin') return 'Admin';
  if (normalized === 'teacher') return 'Teacher';
  if (normalized === 'student') return 'User';
  return role;
}
