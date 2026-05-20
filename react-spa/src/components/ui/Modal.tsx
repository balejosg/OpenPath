import React, { useEffect, useCallback, useId, useRef } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';
import { cn } from '../../lib/utils';
import { Button } from './Button';

let bodyScrollLockCount = 0;
let previousBodyOverflow: string | null = null;
let previousBodyPaddingRight: string | null = null;

const modalStack: string[] = [];

function lockBodyScroll(): void {
  if (typeof document === 'undefined') return;
  bodyScrollLockCount += 1;

  if (bodyScrollLockCount !== 1) return;

  previousBodyOverflow = document.body.style.overflow;
  previousBodyPaddingRight = document.body.style.paddingRight;

  const scrollbarWidth = (() => {
    if (typeof window === 'undefined') return 0;
    const clientWidth = document.documentElement.clientWidth;
    if (clientWidth <= 0) return 0;
    return Math.max(0, window.innerWidth - clientWidth);
  })();

  document.body.style.overflow = 'hidden';

  if (scrollbarWidth > 0 && typeof window !== 'undefined') {
    const computedPaddingRight = Number.parseFloat(
      window.getComputedStyle(document.body).paddingRight
    );
    const basePaddingRight = Number.isFinite(computedPaddingRight) ? computedPaddingRight : 0;
    document.body.style.paddingRight = `${basePaddingRight + scrollbarWidth}px`;
  }
}

function unlockBodyScroll(): void {
  if (typeof document === 'undefined') return;
  bodyScrollLockCount = Math.max(0, bodyScrollLockCount - 1);

  if (bodyScrollLockCount !== 0) return;

  document.body.style.overflow = previousBodyOverflow ?? '';
  document.body.style.paddingRight = previousBodyPaddingRight ?? '';
  previousBodyOverflow = null;
  previousBodyPaddingRight = null;
}

function removeFromModalStack(modalId: string): void {
  const index = modalStack.lastIndexOf(modalId);
  if (index === -1) return;
  modalStack.splice(index, 1);
}

function getFocusableElements(container: HTMLElement): HTMLElement[] {
  const selector =
    'a[href],button:not([disabled]),textarea:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])';

  return Array.from(container.querySelectorAll<HTMLElement>(selector));
}

interface ModalProps {
  isOpen: boolean;
  onClose: () => void;
  title?: string;
  children: React.ReactNode;
  className?: string;
  closeLabel?: string;
  bodyClassName?: string;
}

const Modal: React.FC<ModalProps> = ({
  isOpen,
  onClose,
  title,
  children,
  className,
  closeLabel = 'Close',
  bodyClassName,
}) => {
  const modalId = useId();
  const titleId = useId();
  const dialogRef = useRef<HTMLDivElement | null>(null);
  const closeButtonRef = useRef<HTMLButtonElement | null>(null);
  const previousActiveElementRef = useRef<HTMLElement | null>(null);
  const onCloseRef = useRef(onClose);

  useEffect(() => {
    onCloseRef.current = onClose;
  }, [onClose]);

  const handleKeyDown = useCallback(
    (event: KeyboardEvent) => {
      if (modalStack.at(-1) !== modalId) return;

      if (event.key === 'Escape') {
        onCloseRef.current();
        return;
      }

      if (event.key !== 'Tab') return;

      const dialog = dialogRef.current;
      if (!dialog) return;

      const focusable = getFocusableElements(dialog);
      if (focusable.length === 0) {
        event.preventDefault();
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement;
      const isActiveInside = active instanceof HTMLElement ? dialog.contains(active) : false;

      if (event.shiftKey) {
        if (!isActiveInside || active === first) {
          last.focus();
          event.preventDefault();
        }
        return;
      }

      if (!isActiveInside || active === last) {
        first.focus();
        event.preventDefault();
      }
    },
    [modalId]
  );

  useEffect(() => {
    if (!isOpen) return;

    previousActiveElementRef.current =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;

    modalStack.push(modalId);
    lockBodyScroll();
    window.addEventListener('keydown', handleKeyDown);

    closeButtonRef.current?.focus();

    return () => {
      window.removeEventListener('keydown', handleKeyDown);
      removeFromModalStack(modalId);
      unlockBodyScroll();

      const previous = previousActiveElementRef.current;
      if (previous && typeof previous.focus === 'function') {
        previous.focus();
      }
    };
  }, [handleKeyDown, isOpen, modalId]);

  if (!isOpen) return null;

  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
      {/* Overlay */}
      <div
        className="absolute inset-0 bg-slate-900/40 backdrop-blur-sm transition-opacity animate-in fade-in duration-200"
        onClick={onClose}
      />

      {/* Content */}
      <div
        className={cn(
          'relative w-full max-w-lg rounded-xl bg-white shadow-2xl animate-in zoom-in-95 slide-in-from-bottom-4 duration-200 flex flex-col max-h-[calc(100dvh-2rem)]',
          className
        )}
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={title ? titleId : undefined}
        tabIndex={-1}
      >
        <div className="flex items-center justify-between border-b border-slate-100 p-4 flex-shrink-0">
          {title && (
            <h2 id={titleId} className="text-lg font-semibold text-slate-900">
              {title}
            </h2>
          )}
          <Button
            variant="ghost"
            size="icon"
            className="h-8 w-8 text-slate-400 hover:text-slate-600"
            onClick={onClose}
            aria-label={closeLabel}
            title={closeLabel}
            ref={closeButtonRef}
          >
            <X size={18} />
          </Button>
        </div>

        <div className={cn('min-h-0', bodyClassName ?? 'overflow-y-auto p-6')}>{children}</div>
      </div>
    </div>,
    document.body
  );
};

export { Modal };
