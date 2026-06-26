import type { GroupVisibility } from '@openpath/shared';
import { AlertCircle, Loader2 } from 'lucide-react';
import type { AllowedGroup } from '../../hooks/useGroupsViewModel';
import { Modal } from '../ui/Modal';
import { useT } from '../../i18n/product-i18n';

interface ConfigureGroupModalProps {
  isOpen: boolean;
  group: AllowedGroup | null;
  saving: boolean;
  description: string;
  status: 'Active' | 'Inactive';
  visibility: GroupVisibility;
  error: string | null;
  onClose: () => void;
  onDescriptionChange: (value: string) => void;
  onStatusChange: (value: 'Active' | 'Inactive') => void;
  onVisibilityChange: (value: GroupVisibility) => void;
  onSave: () => void;
  onNavigateToRules: (group: { id: string; name: string; readOnly?: boolean }) => void;
}

export function ConfigureGroupModal({
  isOpen,
  group,
  saving,
  description,
  status,
  visibility,
  error,
  onClose,
  onDescriptionChange,
  onStatusChange,
  onVisibilityChange,
  onSave,
  onNavigateToRules,
}: ConfigureGroupModalProps) {
  const t = useT();
  if (!group) return null;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={t('groups.configureModal.title', { name: group.displayName || group.name })}
    >
      <div className="space-y-4">
        {group.displayName && (
          <p className="text-xs text-slate-500">
            {t('groups.configureModal.slug', { slug: group.name })}
          </p>
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
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-2">
            {t('groups.configureModal.allowedDomainsLabel')}
          </label>
          <div className="border border-slate-200 rounded-lg p-3 bg-slate-50 text-sm text-slate-600">
            {t('groups.configureModal.domainsConfigured', {
              count: group.whitelistCount + group.blockedSubdomainCount + group.blockedPathCount,
            })}
            <button
              onClick={() => {
                onClose();
                onNavigateToRules({
                  id: group.id,
                  name: group.displayName || group.name,
                });
              }}
              className="ml-2 text-blue-600 hover:text-blue-800 font-medium"
            >
              {t('groups.configureModal.manageButton')}
            </button>
          </div>
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
    </Modal>
  );
}
