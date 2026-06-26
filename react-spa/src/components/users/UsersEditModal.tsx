import type React from 'react';
import { Loader2 } from 'lucide-react';

import { Modal } from '../ui/Modal';
import type { UseUsersViewModelReturn } from '../../hooks/useUsersViewModel';
import { useT } from '../../i18n/product-i18n';
import { UserRoleBadge } from './UserRoleBadge';

type Props = Pick<
  UseUsersViewModelReturn,
  | 'closeEditModal'
  | 'editEmail'
  | 'editName'
  | 'saving'
  | 'saveEdit'
  | 'selectedUser'
  | 'setEditEmail'
  | 'setEditName'
  | 'showEditModal'
>;

export function UsersEditModal({
  closeEditModal,
  editEmail,
  editName,
  saving,
  saveEdit,
  selectedUser,
  setEditEmail,
  setEditName,
  showEditModal,
}: Props): React.JSX.Element | null {
  const t = useT();

  if (!showEditModal || !selectedUser) {
    return null;
  }

  return (
    <Modal isOpen onClose={closeEditModal} title={t('users.editModal.title')} className="max-w-md">
      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            {t('users.editModal.nameLabel')}
          </label>
          <input
            type="text"
            value={editName}
            onChange={(e) => setEditName(e.target.value)}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            {t('auth.common.email')}
          </label>
          <input
            type="email"
            value={editEmail}
            onChange={(e) => setEditEmail(e.target.value)}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-2">
            {t('users.editModal.currentRolesLabel')}
          </label>
          <div className="space-y-2">
            <div className="flex flex-wrap gap-2">
              {selectedUser.roles.length > 0 ? (
                selectedUser.roles.map((role) => <UserRoleBadge key={role} role={role} />)
              ) : (
                <span className="text-sm text-slate-500">
                  {t('users.editModal.noRolesAssigned')}
                </span>
              )}
            </div>
            <p className="text-xs text-slate-500">{t('users.editModal.roleManagementHint')}</p>
          </div>
        </div>
        <div className="flex gap-3 pt-2">
          <button
            onClick={closeEditModal}
            disabled={saving}
            className="flex-1 px-4 py-2 border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            {t('common.cancel')}
          </button>
          <button
            onClick={() => void saveEdit()}
            disabled={saving}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium disabled:opacity-50 flex items-center justify-center gap-2"
          >
            {saving && <Loader2 size={16} className="animate-spin" />}
            {t('common.saveChanges')}
          </button>
        </div>
      </div>
    </Modal>
  );
}
