import type React from 'react';
import { AlertCircle, Loader2 } from 'lucide-react';

import type { UseUsersViewModelReturn } from '../../hooks/useUsersViewModel';
import { Modal } from '../ui/Modal';

type Props = Pick<
  UseUsersViewModelReturn,
  | 'closeNewModal'
  | 'createError'
  | 'createUser'
  | 'newEmail'
  | 'newName'
  | 'newPassword'
  | 'newRole'
  | 'resetNewUserForm'
  | 'saving'
  | 'setCreateError'
  | 'setNewEmail'
  | 'setNewName'
  | 'setNewPassword'
  | 'setNewRole'
  | 'showNewModal'
>;

export function UsersCreateModal({
  closeNewModal,
  createError,
  createUser,
  newEmail,
  newName,
  newPassword,
  newRole,
  resetNewUserForm,
  saving,
  setCreateError,
  setNewEmail,
  setNewName,
  setNewPassword,
  setNewRole,
  showNewModal,
}: Props): React.JSX.Element | null {
  if (!showNewModal) {
    return null;
  }

  return (
    <Modal isOpen onClose={closeNewModal} title="New User" className="max-w-md">
      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Name</label>
          <input
            type="text"
            placeholder="Full name"
            value={newName}
            onChange={(e) => {
              setNewName(e.target.value);
              if (createError) setCreateError('');
            }}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Email</label>
          <input
            type="email"
            placeholder="user@example.com"
            value={newEmail}
            onChange={(e) => {
              setNewEmail(e.target.value);
              if (createError) setCreateError('');
            }}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Password</label>
          <input
            type="password"
            placeholder="Minimum 8 characters"
            value={newPassword}
            onChange={(e) => {
              setNewPassword(e.target.value);
              if (createError) setCreateError('');
            }}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Role</label>
          <select
            value={newRole}
            onChange={(e) => {
              setNewRole(e.target.value as typeof newRole);
              if (createError) setCreateError('');
            }}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none"
          >
            <option value="teacher">Teacher</option>
            <option value="admin">Admin</option>
          </select>
        </div>
        {createError && (
          <p className="text-red-500 text-xs flex items-center gap-1">
            <AlertCircle size={12} /> {createError}
          </p>
        )}
        <div className="flex gap-3 pt-2">
          <button
            onClick={() => {
              closeNewModal();
              resetNewUserForm();
            }}
            disabled={saving}
            className="flex-1 px-4 py-2 border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={() => void createUser()}
            disabled={saving}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium disabled:opacity-50 flex items-center justify-center gap-2"
          >
            {saving && <Loader2 size={16} className="animate-spin" />}
            Create User
          </button>
        </div>
      </div>
    </Modal>
  );
}
