import { UserRole } from '../types';
import { normalizeUserRoleString } from '@openpath/shared/roles';
import type { ProductT } from '../i18n/product-i18n';

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

export function getRoleDisplayLabel(role: string, t: ProductT): string {
  const normalized = normalizeUserRoleString(role);
  if (normalized === 'admin') return t('roles.admin');
  if (normalized === 'teacher') return t('roles.teacher');
  if (normalized === 'student') return t('roles.user');
  return role;
}

export function getUserRoleLabel(role: UserRole, t: ProductT): string {
  if (role === UserRole.ADMIN) return t('roles.admin');
  if (role === UserRole.TEACHER) return t('roles.teacher');
  if (role === UserRole.STUDENT) return t('roles.user');
  return t('roles.noRole');
}
