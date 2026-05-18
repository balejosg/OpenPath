import type React from 'react';

import type { UseUsersViewModelReturn } from '../../hooks/useUsersViewModel';
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
  return (
    <>
      <DangerConfirmDialog
        isOpen={resetFlow.status === 'confirm'}
        title="Generate recovery token"
        confirmLabel="Generar token"
        cancelLabel="Cancel"
        isLoading={resettingPassword}
        errorMessage={resetError}
        onClose={closeResetFlow}
        onConfirm={confirmGenerateResetToken}
      >
        {resetUser ? (
          <div className="space-y-2 text-sm text-slate-600">
            <p>
              You are generating a recovery token for{' '}
              <span className="font-semibold text-slate-800">{resetUser.name}</span>.
            </p>
            <p className="font-mono text-xs text-slate-500">{resetUser.email}</p>
          </div>
        ) : null}
      </DangerConfirmDialog>

      <Modal
        isOpen={resetFlow.status === 'success'}
        onClose={closeResetFlow}
        title="Recovery token generated"
        className="max-w-md"
      >
        <div className="space-y-4">
          <p className="text-sm text-slate-600">
            Share this token securely with the user so they can complete the reset from the sign-in
            screen.
          </p>
          <div className="space-y-2">
            <label htmlFor="reset-token" className="text-sm font-medium text-slate-700">
              Token
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
              Close
            </button>
          </div>
        </div>
      </Modal>
    </>
  );
}
