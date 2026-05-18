import React from 'react';
import { AlertCircle, Loader2 } from 'lucide-react';

import type { AllowedGroupOption } from '../../hooks/useAllowedGroups';
import { Modal } from '../ui/Modal';

interface NewClassroomModalProps {
  isOpen: boolean;
  saving: boolean;
  newName: string;
  newGroup: string;
  newError: string;
  groupOptions: AllowedGroupOption[];
  onClose: () => void;
  onNameChange: (value: string) => void;
  onGroupChange: (value: string) => void;
  onCreate: () => void;
}

const NewClassroomModal: React.FC<NewClassroomModalProps> = ({
  isOpen,
  saving,
  newName,
  newGroup,
  newError,
  groupOptions,
  onClose,
  onNameChange,
  onGroupChange,
  onCreate,
}) => {
  if (!isOpen) return null;

  return (
    <Modal isOpen onClose={onClose} title="New Classroom" className="max-w-md">
      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Classroom Name</label>
          <input
            type="text"
            placeholder="E.g. Lab C"
            value={newName}
            onChange={(e) => onNameChange(e.target.value)}
            className={`w-full border rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none ${
              newError ? 'border-red-300' : 'border-slate-300'
            }`}
          />
          {newError && (
            <p className="text-red-500 text-xs mt-1 flex items-center gap-1">
              <AlertCircle size={12} /> {newError}
            </p>
          )}
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Initial Group</label>
          <select
            value={newGroup}
            onChange={(e) => onGroupChange(e.target.value)}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
          >
            <option value="">No group</option>
            {groupOptions.map((g) => (
              <option key={g.value} value={g.value}>
                {g.label}
              </option>
            ))}
          </select>
        </div>
        <div className="flex gap-3 pt-2">
          <button
            onClick={onClose}
            disabled={saving}
            className="flex-1 px-4 py-2 border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50 transition-colors disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={onCreate}
            disabled={saving}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors font-medium disabled:opacity-50 flex items-center justify-center gap-2"
          >
            {saving && <Loader2 size={16} className="animate-spin" />}
            Create Classroom
          </button>
        </div>
      </div>
    </Modal>
  );
};

export default NewClassroomModal;
