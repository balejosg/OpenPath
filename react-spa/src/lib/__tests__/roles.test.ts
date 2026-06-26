import { describe, expect, it } from 'vitest';
import { UserRole } from '../../types';
import {
  CREATE_USER_ROLES,
  DEFAULT_CREATE_USER_ROLE,
  USER_ROLE_LABELS,
  getPrimaryRole,
  getRoleDisplayLabel,
  mapBackendRoleToUserRole,
} from '../roles';
import { translateProductText } from '../../i18n/product-i18n';

const t = (
  key: Parameters<typeof translateProductText>[1],
  params?: Parameters<typeof translateProductText>[2]
) => translateProductText('en', key, params);

describe('roles helpers', () => {
  it('maps backend role strings to UserRole', () => {
    expect(mapBackendRoleToUserRole('admin')).toBe(UserRole.ADMIN);
    expect(mapBackendRoleToUserRole('openpath-admin')).toBe(UserRole.ADMIN);
    expect(mapBackendRoleToUserRole('teacher')).toBe(UserRole.TEACHER);
    expect(mapBackendRoleToUserRole('student')).toBe(UserRole.STUDENT);
    expect(mapBackendRoleToUserRole('user')).toBe(UserRole.STUDENT);
    expect(mapBackendRoleToUserRole('viewer')).toBe(UserRole.STUDENT);
    expect(mapBackendRoleToUserRole('unknown')).toBe(UserRole.NO_ROLES);
  });

  it('returns a stable primary role label', () => {
    expect(getPrimaryRole(['teacher'])).toBe('teacher');
    expect(getPrimaryRole(['student', 'teacher'])).toBe('teacher');
    expect(getPrimaryRole(['admin', 'teacher'])).toBe('admin');
    expect(getPrimaryRole(['viewer'])).toBe('student');
  });

  it('returns human-readable labels for raw role strings', () => {
    expect(getRoleDisplayLabel('admin', t)).toBe('Admin');
    expect(getRoleDisplayLabel('openpath-admin', t)).toBe('Admin');
    expect(getRoleDisplayLabel('teacher', t)).toBe('Teacher');
    expect(getRoleDisplayLabel('student', t)).toBe('User');
    expect(getRoleDisplayLabel('viewer', t)).toBe('User');
    expect(getRoleDisplayLabel('user', t)).toBe('User');
    expect(getRoleDisplayLabel('custom', t)).toBe('custom');
  });

  it('exposes UI role labels for UserRole enum', () => {
    expect(USER_ROLE_LABELS[UserRole.ADMIN]).toBe('Admin');
    expect(USER_ROLE_LABELS[UserRole.TEACHER]).toBe('Teacher');
    expect(USER_ROLE_LABELS[UserRole.STUDENT]).toBe('User');
    expect(USER_ROLE_LABELS[UserRole.NO_ROLES]).toBe('No Role');
  });

  it('defines allowed create-user roles and default', () => {
    expect(CREATE_USER_ROLES).toEqual(['teacher', 'admin']);
    expect(DEFAULT_CREATE_USER_ROLE).toBe('teacher');
  });
});
