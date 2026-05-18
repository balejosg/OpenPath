import { useCallback, useEffect, useRef, useState } from 'react';
import { reportError } from '../lib/reportError';

interface UseClipboardOptions {
  resetDelayMs?: number;
}

interface ClipboardState {
  copiedKey: string | null;
  error: string | null;
}

export function useClipboard(options: UseClipboardOptions = {}) {
  const resetDelayMs = options.resetDelayMs ?? 2000;
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [{ copiedKey, error }, setState] = useState<ClipboardState>({
    copiedKey: null,
    error: null,
  });

  const clearCopied = useCallback(() => {
    if (timeoutRef.current) {
      clearTimeout(timeoutRef.current);
      timeoutRef.current = null;
    }
    setState((previous) => ({ ...previous, copiedKey: null }));
  }, []);

  const copy = useCallback(
    async (text: string, key = 'default'): Promise<boolean> => {
      try {
        const clipboard = (
          globalThis as unknown as {
            navigator?: { clipboard?: { writeText?: (value: string) => Promise<void> } };
          }
        ).navigator?.clipboard;

        if (!clipboard?.writeText) {
          setState((previous) => ({ ...previous, error: 'Clipboard API no disponible' }));
          return false;
        }

        await clipboard.writeText(text);
        if (timeoutRef.current) {
          clearTimeout(timeoutRef.current);
          timeoutRef.current = null;
        }
        setState({ copiedKey: key, error: null });

        timeoutRef.current = setTimeout(() => {
          setState((previous) => ({ ...previous, copiedKey: null }));
        }, resetDelayMs);

        return true;
      } catch (err) {
        reportError('Failed to copy to clipboard:', err);
        setState((previous) => ({ ...previous, error: 'Unable to copy to clipboard' }));
        return false;
      }
    },
    [resetDelayMs]
  );

  const isCopied = useCallback(
    (key = 'default') => {
      return copiedKey === key;
    },
    [copiedKey]
  );

  useEffect(() => {
    return () => {
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
        timeoutRef.current = null;
      }
    };
  }, []);

  return {
    copy,
    isCopied,
    copiedKey,
    error,
    clearCopied,
  };
}
