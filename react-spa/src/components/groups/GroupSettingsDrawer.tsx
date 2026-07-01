import { createPortal } from 'react-dom';
import { X } from 'lucide-react';
import type { GroupVisibility } from '@openpath/shared';
import { Button } from '../ui/Button';
import { useT } from '../../i18n/product-i18n';
import { GroupSettingsForm } from './GroupSettingsForm';

export interface GroupSettingsDrawerProps {
  isOpen: boolean;
  title: string;
  saving: boolean;
  slug?: string;
  description: string;
  status: 'Active' | 'Inactive';
  visibility: GroupVisibility;
  error: string | null;
  onClose: () => void;
  onDescriptionChange: (value: string) => void;
  onStatusChange: (value: 'Active' | 'Inactive') => void;
  onVisibilityChange: (value: GroupVisibility) => void;
  onSave: () => void;
}

export function GroupSettingsDrawer({
  isOpen,
  title,
  saving,
  slug,
  description,
  status,
  visibility,
  error,
  onClose,
  onDescriptionChange,
  onStatusChange,
  onVisibilityChange,
  onSave,
}: GroupSettingsDrawerProps) {
  const t = useT();
  if (!isOpen) return null;

  return createPortal(
    <div className="fixed inset-0 z-50 flex justify-end">
      <div
        className="absolute inset-0 bg-slate-900/40 backdrop-blur-sm animate-in fade-in duration-200"
        onClick={onClose}
      />
      <div
        className="relative h-full w-full max-w-md bg-white shadow-2xl animate-in slide-in-from-right duration-200 flex flex-col"
        role="dialog"
        aria-modal="true"
      >
        <div className="flex items-center justify-between border-b border-slate-100 p-4 flex-shrink-0">
          <h2 className="text-lg font-semibold text-slate-900">{title}</h2>
          <Button
            variant="ghost"
            size="icon"
            className="h-8 w-8 text-slate-400 hover:text-slate-600"
            onClick={onClose}
            aria-label={t('common.close')}
            title={t('common.close')}
          >
            <X size={18} />
          </Button>
        </div>
        <div className="overflow-y-auto p-6">
          <GroupSettingsForm
            saving={saving}
            slug={slug}
            description={description}
            status={status}
            visibility={visibility}
            error={error}
            onDescriptionChange={onDescriptionChange}
            onStatusChange={onStatusChange}
            onVisibilityChange={onVisibilityChange}
            onSave={onSave}
            onCancel={onClose}
          />
        </div>
      </div>
    </div>,
    document.body
  );
}
