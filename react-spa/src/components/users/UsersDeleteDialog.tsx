import type React from 'react';

import type { UseUsersViewModelReturn } from '../../hooks/useUsersViewModel';
import { DangerConfirmDialog } from '../ui/ConfirmDialog';

type Props = Pick<
  UseUsersViewModelReturn,
  'clearDeleteState' | 'deleteError' | 'deleteTarget' | 'deleting' | 'handleConfirmDeleteUser'
>;

export function UsersDeleteDialog({
  clearDeleteState,
  deleteError,
  deleteTarget,
  deleting,
  handleConfirmDeleteUser,
}: Props): React.JSX.Element | null {
  if (!deleteTarget) {
    return null;
  }

  return (
    <DangerConfirmDialog
      isOpen
      title="Delete User"
      confirmLabel="Delete user"
      cancelLabel="Cancel"
      isLoading={deleting}
      errorMessage={deleteError}
      onClose={clearDeleteState}
      onConfirm={() => void handleConfirmDeleteUser()}
    >
      <p className="text-sm text-slate-600">
        Delete <span className="font-semibold text-slate-800">{deleteTarget.name}</span>?
      </p>
      <p className="text-xs text-slate-500">This action cannot be undone.</p>
    </DangerConfirmDialog>
  );
}
