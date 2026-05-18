import { AlertCircle, Loader2 } from 'lucide-react';
import type { LibraryGroup } from '../../hooks/useGroupsViewModel';
import { Modal } from '../ui/Modal';

interface CloneGroupModalProps {
  isOpen: boolean;
  cloneSource: LibraryGroup | null;
  saving: boolean;
  name: string;
  displayName: string;
  error: string;
  onClose: () => void;
  onNameChange: (value: string) => void;
  onDisplayNameChange: (value: string) => void;
  onClone: () => void;
}

export function CloneGroupModal({
  isOpen,
  cloneSource,
  saving,
  name,
  displayName,
  error,
  onClose,
  onNameChange,
  onDisplayNameChange,
  onClone,
}: CloneGroupModalProps) {
  if (!cloneSource) return null;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={`Clone: ${cloneSource.displayName || cloneSource.name}`}
      className="max-w-md"
    >
      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Name</label>
          <input
            type="text"
            placeholder="E.g. primary-policy"
            value={name}
            onChange={(event) => onNameChange(event.target.value)}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none"
          />
          <p className="text-xs text-slate-500 mt-1">
            Used as the slug (must be unique in the instance).
          </p>
        </div>

        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">Description</label>
          <textarea
            placeholder="Policy description..."
            value={displayName}
            onChange={(event) => onDisplayNameChange(event.target.value)}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none h-20 resize-none"
          />
        </div>

        {error && (
          <p className="text-sm text-red-600 flex items-start gap-2">
            <AlertCircle size={16} className="mt-0.5 flex-shrink-0" />
            <span>{error}</span>
          </p>
        )}

        <div className="flex gap-3 pt-2">
          <button
            onClick={onClose}
            disabled={saving}
            className="flex-1 px-4 py-2 border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={onClone}
            disabled={saving}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium disabled:opacity-50 flex items-center justify-center gap-2"
          >
            {saving && <Loader2 size={16} className="animate-spin" />}
            Clone
          </button>
        </div>
      </div>
    </Modal>
  );
}
