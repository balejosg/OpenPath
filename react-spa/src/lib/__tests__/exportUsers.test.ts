import { describe, expect, it } from 'vitest';

import { UserRole, type User } from '../../types';
import {
  buildUsersCsvExport,
  USERS_CSV_EXPORT_FILENAME,
  USERS_CSV_EXPORT_MIME_TYPE,
} from '../exportUsers';
import { translateProductText } from '../../i18n/product-i18n';

const t = (
  key: Parameters<typeof translateProductText>[1],
  params?: Parameters<typeof translateProductText>[2]
) => translateProductText('en', key, params);

describe('buildUsersCsvExport', () => {
  const users: User[] = [
    {
      id: 'user-1',
      name: 'Admin QA',
      email: 'admin@example.com',
      roles: [UserRole.ADMIN],
      status: 'Active',
    },
    {
      id: 'user-2',
      name: 'Teacher QA',
      email: 'teacher@example.com',
      roles: [UserRole.TEACHER],
      status: 'Inactive',
    },
  ];

  it('builds a localized CSV with code columnas by default', () => {
    const result = buildUsersCsvExport(users, {}, t);

    expect(result.filename).toBe(USERS_CSV_EXPORT_FILENAME);
    expect(result.mimeType).toBe(USERS_CSV_EXPORT_MIME_TYPE);
    expect(result.content).toBe(
      [
        'Nombre,Email,Roles,Estado,Roles_codigo,Estado_codigo',
        'Admin QA,admin@example.com,Admin,Active,admin,Active',
        'Teacher QA,teacher@example.com,Teacher,Inactive,teacher,Inactive',
      ].join('\n')
    );
  });

  it('can omit code columnas when requested', () => {
    const result = buildUsersCsvExport(users, { includeCodeColumns: false }, t);

    expect(result.content).toBe(
      [
        'Nombre,Email,Roles,Estado',
        'Admin QA,admin@example.com,Admin,Active',
        'Teacher QA,teacher@example.com,Teacher,Inactive',
      ].join('\n')
    );
  });
});
