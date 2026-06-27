import React, { useEffect, useState, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { X, CheckCircle, AlertCircle, Info } from 'lucide-react';
import { cn } from '../../lib/utils';

export interface ToastData {
  id: string;
  message: string;
  type: 'success' | 'error' | 'info';
  duration?: number;
  undoAction?: () => void;
}

const DEFAULT_TOAST_DURATION_MS = 5000;
// Undo notifications require the user to act before they vanish, so they live longer.
const UNDO_TOAST_DURATION_MS = 10000;

interface ToastItemProps {
  toast: ToastData;
  onDismiss: (id: string) => void;
}

const ToastItem: React.FC<ToastItemProps> = ({ toast, onDismiss }) => {
  const [progress, setProgress] = useState(100);
  const duration = toast.duration ?? DEFAULT_TOAST_DURATION_MS;

  useEffect(() => {
    const startTime = Date.now();
    const interval = setInterval(() => {
      const elapsed = Date.now() - startTime;
      const remaining = Math.max(0, 100 - (elapsed / duration) * 100);
      setProgress(remaining);

      if (remaining <= 0) {
        clearInterval(interval);
        onDismiss(toast.id);
      }
    }, 50);

    return () => clearInterval(interval);
  }, [duration, toast.id, onDismiss]);

  const icons = {
    success: <CheckCircle size={18} className="text-green-500" />,
    error: <AlertCircle size={18} className="text-red-500" />,
    info: <Info size={18} className="text-blue-500" />,
  };

  const bgColors = {
    success: 'bg-green-50 border-green-200',
    error: 'bg-red-50 border-red-200',
    info: 'bg-blue-50 border-blue-200',
  };

  const progressColors = {
    success: 'bg-green-500',
    error: 'bg-red-500',
    info: 'bg-blue-500',
  };

  return (
    <div
      className={cn(
        'relative overflow-hidden rounded-lg border shadow-lg animate-in slide-in-from-right-full duration-300',
        bgColors[toast.type]
      )}
    >
      <div className="flex items-center gap-3 p-4 pr-10">
        {icons[toast.type]}
        <span className="text-sm text-slate-700 flex-1">{toast.message}</span>
        {toast.undoAction && (
          <button
            onClick={() => {
              toast.undoAction?.();
              onDismiss(toast.id);
            }}
            className="text-sm font-medium text-blue-600 hover:text-blue-800 transition-colors"
          >
            Deshacer
          </button>
        )}
      </div>
      <button
        onClick={() => onDismiss(toast.id)}
        className="absolute top-2 right-2 p-1 text-slate-400 hover:text-slate-600 transition-colors"
      >
        <X size={14} />
      </button>
      <div className="h-1 w-full bg-slate-200/50">
        <div
          className={cn('h-full transition-all duration-100', progressColors[toast.type])}
          style={{ width: `${progress.toString()}%` }}
        />
      </div>
    </div>
  );
};

interface ToastContainerProps {
  toasts: ToastData[];
  onDismiss: (id: string) => void;
}

export const ToastContainer: React.FC<ToastContainerProps> = ({ toasts, onDismiss }) => {
  if (toasts.length === 0) return null;

  return createPortal(
    <div className="fixed bottom-4 right-4 z-[60] flex flex-col gap-2 max-w-sm">
      {toasts.map((toast) => (
        <ToastItem key={toast.id} toast={toast} onDismiss={onDismiss} />
      ))}
    </div>,
    document.body
  );
};

// Hook for managing toasts
export function useToast() {
  const [toasts, setToasts] = useState<ToastData[]>([]);

  const addToast = useCallback((toast: Omit<ToastData, 'id'>) => {
    const id = `toast-${Date.now().toString()}-${Math.random().toString(36).substring(2, 11)}`;
    setToasts((prev) => [...prev, { ...toast, id }]);
    return id;
  }, []);

  const dismissToast = useCallback((id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  const success = useCallback(
    (message: string, undoAction?: () => void) => {
      // An undo notification must stay long enough to read the message AND click "Deshacer",
      // so it gets a longer window than a passive success confirmation.
      return addToast({
        message,
        type: 'success',
        undoAction,
        duration: undoAction ? UNDO_TOAST_DURATION_MS : undefined,
      });
    },
    [addToast]
  );

  const error = useCallback(
    (message: string) => {
      return addToast({ message, type: 'error', duration: 7000 });
    },
    [addToast]
  );

  const info = useCallback(
    (message: string) => {
      return addToast({ message, type: 'info' });
    },
    [addToast]
  );

  return {
    toasts,
    addToast,
    dismissToast,
    success,
    error,
    info,
    ToastContainer: () => <ToastContainer toasts={toasts} onDismiss={dismissToast} />,
  };
}
