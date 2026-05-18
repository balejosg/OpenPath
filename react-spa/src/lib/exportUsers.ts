import type { User } from '../types';
import { USER_ROLE_LABELS } from './roles';
import { toCsv } from './csv';
import { getEsActiveInactiveLabel } from './status';

export const USERS_CSV_EXPORT_FILENAME = 'users.csv';
export const USERS_CSV_EXPORT_MIME_TYPE = 'text/csv;charset=utf-8';

export interface UsersCsvExportOptions {
  includeCodeColumns?: boolean;
}

export function buildUsersCsvExport(
  users: readonly User[],
  options: UsersCsvExportOptions = {}
): {
  filename: string;
  mimeType: string;
  content: string;
} {
  const includeCodeColumns = options.includeCodeColumns ?? true;

  const headers = ['Nombre', 'Email', 'Roles', 'Estado'];
  if (includeCodeColumns) headers.push('Roles_codigo', 'Estado_codigo');

  const rows = users.map((user) => {
    const rolesLabel = user.roles.map((role) => USER_ROLE_LABELS[role]).join('|');
    const statusLabel = getEsActiveInactiveLabel(user.status);
    const base = [user.name, user.email, rolesLabel, statusLabel];

    if (!includeCodeColumns) return base;

    const rolesCode = user.roles.join('|');
    const statusCode = user.status;
    return [...base, rolesCode, statusCode];
  });

  const content = toCsv([headers, ...rows]);
  return {
    filename: USERS_CSV_EXPORT_FILENAME,
    mimeType: USERS_CSV_EXPORT_MIME_TYPE,
    content,
  };
}
