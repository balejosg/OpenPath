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
    expect(getRoleDisplayLabel('admin')).toBe('Admin');
    expect(getRoleDisplayLabel('openpath-admin')).toBe('Admin');
    expect(getRoleDisplayLabel('teacher')).toBe('Teacher');
    expect(getRoleDisplayLabel('student')).toBe('User');
    expect(getRoleDisplayLabel('viewer')).toBe('User');
    expect(getRoleDisplayLabel('user')).toBe('User');
    expect(getRoleDisplayLabel('custom')).toBe('custom');
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
