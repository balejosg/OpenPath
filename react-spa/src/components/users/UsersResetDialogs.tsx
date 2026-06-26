import type React from 'react';

import type { UseUsersViewModelReturn } from '../../hooks/useUsersViewModel';
import { useT } from '../../i18n/product-i18n';
import { DangerConfirmDialog } from '../ui/ConfirmDialog';
import { Modal } from '../ui/Modal';

type Props = Pick<
  UseUsersViewModelReturn,
  | 'closeResetFlow'
  | 'confirmGenerateResetToken'
  | 'generatedResetToken'
  | 'resetError'
  | 'resetFlow'
  | 'resetUser'
  | 'resettingPassword'
>;

export function UsersResetDialogs({
  closeResetFlow,
  confirmGenerateResetToken,
  generatedResetToken,
  resetError,
  resetFlow,
  resetUser,
  resettingPassword,
}: Props): React.JSX.Element {
  const t = useT();

  return (
    <>
      <DangerConfirmDialog
        isOpen={resetFlow.status === 'confirm'}
        title={t('users.resetDialog.confirmTitle')}
        confirmLabel={t('users.resetDialog.confirmLabel')}
        cancelLabel={t('common.cancel')}
        isLoading={resettingPassword}
        errorMessage={resetError}
        onClose={closeResetFlow}
        onConfirm={confirmGenerateResetToken}
      >
        {resetUser ? (
          <div className="space-y-2 text-sm text-slate-600">
            <p>{t('users.resetDialog.confirmBody', { name: resetUser.name })}</p>
            <p className="font-mono text-xs text-slate-500">{resetUser.email}</p>
          </div>
        ) : null}
      </DangerConfirmDialog>

      <Modal
        isOpen={resetFlow.status === 'success'}
        onClose={closeResetFlow}
        title={t('users.resetDialog.successTitle')}
        className="max-w-md"
      >
        <div className="space-y-4">
          <p className="text-sm text-slate-600">{t('users.resetDialog.successBody')}</p>
          <div className="space-y-2">
            <label htmlFor="reset-token" className="text-sm font-medium text-slate-700">
              {t('users.resetDialog.tokenLabel')}
            </label>
            <input
              id="reset-token"
              type="text"
              readOnly
              value={generatedResetToken}
              className="w-full rounded-lg border border-slate-300 bg-slate-50 px-3 py-2 font-mono text-sm text-slate-900"
            />
          </div>
          <div className="flex justify-end">
            <button
              onClick={closeResetFlow}
              className="px-4 py-2 rounded-lg bg-blue-600 text-white text-sm font-medium hover:bg-blue-700 transition-colors"
            >
              {t('common.close')}
            </button>
          </div>
        </div>
      </Modal>
    </>
  );
}
