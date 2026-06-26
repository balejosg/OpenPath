import type React from 'react';

import { UserRole } from '../../types';
import { getUserRoleLabel } from '../../lib/roles';
import { useT } from '../../i18n/product-i18n';

const STYLES = {
  [UserRole.ADMIN]: 'bg-purple-50 text-purple-700 border-purple-200',
  [UserRole.TEACHER]: 'bg-blue-50 text-blue-700 border-blue-200',
  [UserRole.STUDENT]: 'bg-slate-100 text-slate-600 border-slate-200',
  [UserRole.NO_ROLES]: 'bg-red-50 text-red-600 border-red-200',
};

export function UserRoleBadge({ role }: { role: UserRole }): React.JSX.Element {
  const t = useT();
  return (
    <span
      className={`px-2 py-0.5 rounded text-[11px] font-semibold border uppercase tracking-wide ${STYLES[role]}`}
    >
      {getUserRoleLabel(role, t)}
    </span>
  );
}
