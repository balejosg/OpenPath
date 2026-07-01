import type { GroupVisibility } from '@openpath/shared';
import { AlertCircle, Loader2 } from 'lucide-react';
import { useT } from '../../i18n/product-i18n';

export interface GroupSettingsFormProps {
  saving: boolean;
  slug?: string;
  description: string;
  status: 'Active' | 'Inactive';
  visibility: GroupVisibility;
  error: string | null;
  onDescriptionChange: (value: string) => void;
  onStatusChange: (value: 'Active' | 'Inactive') => void;
  onVisibilityChange: (value: GroupVisibility) => void;
  onSave: () => void;
  onCancel: () => void;
}

export function GroupSettingsForm({
  saving,
  slug,
  description,
  status,
  visibility,
  error,
  onDescriptionChange,
  onStatusChange,
  onVisibilityChange,
  onSave,
  onCancel,
}: GroupSettingsFormProps) {
  const t = useT();
  return (
    <div className="space-y-4">
      {slug && (
        <p className="text-xs text-slate-500">{t('groups.configureModal.slug', { slug })}</p>
      )}
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">
          {t('groups.configureModal.descriptionLabel')}
        </label>
        <textarea
          value={description}
          onChange={(event) => onDescriptionChange(event.target.value)}
          className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none h-20 resize-none"
        />
      </div>
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-2">
          {t('groups.configureModal.statusLabel')}
        </label>
        <div className="flex gap-3">
          <button
            onClick={() => onStatusChange('Active')}
            className={`px-4 py-2 rounded-lg border text-sm font-medium transition-colors ${status === 'Active' ? 'bg-green-50 border-green-200 text-green-700' : 'bg-white border-slate-200 text-slate-600 hover:bg-slate-50'}`}
          >
            {t('common.status.active')}
          </button>
          <button
            onClick={() => onStatusChange('Inactive')}
            className={`px-4 py-2 rounded-lg border text-sm font-medium transition-colors ${status === 'Inactive' ? 'bg-slate-100 border-slate-300 text-slate-700' : 'bg-white border-slate-200 text-slate-600 hover:bg-slate-50'}`}
          >
            {t('common.status.inactive')}
          </button>
        </div>
      </div>
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-2">
          {t('groups.configureModal.visibilityLabel')}
        </label>
        <div className="flex gap-3">
          <button
            onClick={() => onVisibilityChange('private')}
            className={`px-4 py-2 rounded-lg border text-sm font-medium transition-colors ${visibility === 'private' ? 'bg-slate-100 border-slate-300 text-slate-800' : 'bg-white border-slate-200 text-slate-600 hover:bg-slate-50'}`}
          >
            {t('groups.configureModal.visibilityPrivate')}
          </button>
          <button
            onClick={() => onVisibilityChange('instance_public')}
            className={`px-4 py-2 rounded-lg border text-sm font-medium transition-colors ${visibility === 'instance_public' ? 'bg-blue-50 border-blue-200 text-blue-700' : 'bg-white border-slate-200 text-slate-600 hover:bg-slate-50'}`}
          >
            {t('groups.configureModal.visibilityPublic')}
          </button>
        </div>
        <p className="text-xs text-slate-500 mt-2">
          {t('groups.configureModal.visibilityPublicHint')}
        </p>
      </div>
      {error && (
        <p className="text-sm text-red-600 flex items-start gap-2">
          <AlertCircle size={16} className="mt-0.5 flex-shrink-0" />
          <span>{error}</span>
        </p>
      )}
      <div className="flex gap-3 pt-2">
        <button
          onClick={onCancel}
          disabled={saving}
          className="flex-1 px-4 py-2 border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50 disabled:opacity-50"
        >
          {t('common.cancel')}
        </button>
        <button
          onClick={onSave}
          disabled={saving}
          className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium disabled:opacity-50 flex items-center justify-center gap-2"
        >
          {saving && <Loader2 size={16} className="animate-spin" />}
          {t('common.saveChanges')}
        </button>
      </div>
    </div>
  );
}
