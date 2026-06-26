import { AlertCircle, Loader2 } from 'lucide-react';
import { Modal } from '../ui/Modal';
import { useT } from '../../i18n/product-i18n';

interface CreateGroupModalProps {
  isOpen: boolean;
  saving: boolean;
  name: string;
  description: string;
  error: string;
  onClose: () => void;
  onNameChange: (value: string) => void;
  onDescriptionChange: (value: string) => void;
  onCreate: () => void;
}

export function CreateGroupModal({
  isOpen,
  saving,
  name,
  description,
  error,
  onClose,
  onNameChange,
  onDescriptionChange,
  onCreate,
}: CreateGroupModalProps) {
  const t = useT();
  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={t('groups.createModal.title')}
      className="max-w-md"
    >
      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            {t('groups.createModal.nameLabel')}
          </label>
          <input
            type="text"
            placeholder={t('groups.createModal.namePlaceholder')}
            value={name}
            onChange={(event) => onNameChange(event.target.value)}
            className={`w-full border rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none ${error ? 'border-red-300' : 'border-slate-300'}`}
          />
          <p className="text-xs text-slate-500 mt-1">{t('groups.createModal.nameHint')}</p>
          {error && (
            <p className="text-red-500 text-xs mt-1 flex items-center gap-1">
              <AlertCircle size={12} /> {error}
            </p>
          )}
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            {t('groups.createModal.descriptionLabel')}
          </label>
          <textarea
            placeholder={t('groups.createModal.descriptionPlaceholder')}
            value={description}
            onChange={(event) => onDescriptionChange(event.target.value)}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none h-20 resize-none"
          />
        </div>
        <div className="flex gap-3 pt-2">
          <button
            onClick={onClose}
            disabled={saving}
            className="flex-1 px-4 py-2 border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            {t('common.cancel')}
          </button>
          <button
            onClick={onCreate}
            disabled={saving}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium disabled:opacity-50 flex items-center justify-center gap-2"
          >
            {saving && <Loader2 size={16} className="animate-spin" />}
            {t('groups.createModal.createButton')}
          </button>
        </div>
      </div>
    </Modal>
  );
}
