import React from 'react';
import { AlertCircle, Copy, Check } from 'lucide-react';

import type { Classroom } from '../../types';
import { Modal } from '../ui/Modal';
import { useT } from '../../i18n/product-i18n';

interface EnrollClassroomModalProps {
  isOpen: boolean;
  enrollToken: string | null;
  selectedClassroom: Classroom | null;
  enrollPlatform: 'linux' | 'windows';
  enrollCommand: string;
  onClose: () => void;
  onSelectPlatform: (platform: 'linux' | 'windows') => void;
  onCopy: () => void;
  isCopied: boolean;
}

const EnrollClassroomModal: React.FC<EnrollClassroomModalProps> = ({
  isOpen,
  enrollToken,
  selectedClassroom,
  enrollPlatform,
  enrollCommand,
  onClose,
  onSelectPlatform,
  onCopy,
  isCopied,
}) => {
  const t = useT();
  if (!isOpen || !enrollToken || !selectedClassroom) return null;

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={t('enroll.modal.title')}>
      <p className="text-sm text-slate-600 mb-3">
        {t('enroll.modal.description', { classroomName: selectedClassroom.displayName })}
      </p>
      {selectedClassroom.currentGroupId === null ? (
        <div className="mb-3 flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          <AlertCircle size={16} className="mt-0.5 shrink-0" />
          <p>{t('enroll.modal.noGroupWarning')}</p>
        </div>
      ) : null}
      <div className="mb-3 inline-flex rounded-lg border border-slate-200 bg-slate-50 p-1">
        <button
          onClick={() => onSelectPlatform('linux')}
          className={`px-3 py-1.5 text-xs rounded-md transition-colors font-medium ${
            enrollPlatform === 'linux'
              ? 'bg-white text-slate-900 shadow-sm'
              : 'text-slate-600 hover:text-slate-800'
          }`}
        >
          {t('enroll.modal.platformLinux')}
        </button>
        <button
          onClick={() => onSelectPlatform('windows')}
          className={`px-3 py-1.5 text-xs rounded-md transition-colors font-medium ${
            enrollPlatform === 'windows'
              ? 'bg-white text-slate-900 shadow-sm'
              : 'text-slate-600 hover:text-slate-800'
          }`}
        >
          {t('enroll.modal.platformWindows')}
        </button>
      </div>
      <div className="bg-slate-900 text-green-400 rounded-lg p-4 font-mono text-xs overflow-x-auto relative">
        <button
          onClick={onCopy}
          className="absolute top-2 right-2 inline-flex items-center gap-1 text-slate-400 hover:text-white"
          title={isCopied ? t('common.copied') : t('common.copyToClipboard')}
          aria-label={isCopied ? t('common.copied') : t('common.copyToClipboard')}
        >
          {isCopied ? (
            <>
              <Check size={16} className="text-green-400" />
              <span className="text-[10px] font-semibold text-green-400">{t('common.copied')}</span>
            </>
          ) : (
            <Copy size={16} />
          )}
        </button>
        <pre className="whitespace-pre-wrap pr-8">{enrollCommand}</pre>
      </div>
      {enrollPlatform === 'linux' ? (
        <p className="text-xs text-slate-500 mt-3">{t('enroll.modal.linuxNote')}</p>
      ) : (
        <p className="text-xs text-slate-500 mt-3">{t('enroll.modal.windowsNote')}</p>
      )}
      <div className="mt-6 flex justify-end">
        <button
          onClick={onClose}
          className="px-4 py-2 bg-slate-100 text-slate-700 rounded-lg hover:bg-slate-200 transition-colors font-medium"
        >
          {t('common.close')}
        </button>
      </div>
    </Modal>
  );
};

export default EnrollClassroomModal;
