import React, { useCallback } from 'react';
import { AlertCircle } from 'lucide-react';

import { Modal } from './Modal';
import { Button } from './Button';
import { useT } from '../../i18n/product-i18n';

export interface ConfirmDialogProps {
  isOpen: boolean;
  title: string;
  children?: React.ReactNode;

  confirmLabel?: string;
  cancelLabel?: string;
  confirmVariant?: 'primary' | 'danger';
  isLoading?: boolean;
  errorMessage?: string;
  disableConfirm?: boolean;

  onClose: () => void;
  onConfirm: () => void | Promise<void>;
}

export const ConfirmDialog: React.FC<ConfirmDialogProps> = ({
  isOpen,
  title,
  children,
  confirmLabel,
  cancelLabel,
  confirmVariant = 'primary',
  isLoading = false,
  errorMessage,
  disableConfirm = false,
  onClose,
  onConfirm,
}) => {
  const t = useT();
  const resolvedConfirmLabel = confirmLabel ?? t('common.confirm');
  const resolvedCancelLabel = cancelLabel ?? t('common.cancel');
  const handleClose = useCallback(() => {
    if (isLoading) return;
    onClose();
  }, [isLoading, onClose]);

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title={title} className="max-w-md">
      <div className="space-y-4">
        {children}

        {errorMessage ? (
          <p className="text-red-600 text-sm flex items-start gap-2" role="alert">
            <AlertCircle size={16} className="mt-0.5 flex-shrink-0" />
            <span>{errorMessage}</span>
          </p>
        ) : null}

        <div className="flex gap-3 pt-2">
          <Button variant="outline" className="flex-1" onClick={handleClose} disabled={isLoading}>
            {resolvedCancelLabel}
          </Button>
          <Button
            variant={confirmVariant}
            className="flex-1"
            onClick={() => void onConfirm()}
            isLoading={isLoading}
            disabled={disableConfirm}
          >
            {resolvedConfirmLabel}
          </Button>
        </div>
      </div>
    </Modal>
  );
};

export const DangerConfirmDialog: React.FC<Omit<ConfirmDialogProps, 'confirmVariant'>> = (
  props
) => {
  return <ConfirmDialog {...props} confirmVariant="danger" />;
};
