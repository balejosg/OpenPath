import React, { useState, useRef, useEffect, useMemo } from 'react';
import { Download, ChevronDown, FileText, FileJson, FileSpreadsheet } from 'lucide-react';
import { Button } from './ui/Button';
import { cn } from '../lib/utils';
import type { ExportFormat } from '../lib/exportRules';
import { useT } from '../i18n/product-i18n';

interface ExportDropdownProps {
  onExport: (format: ExportFormat) => void;
  disabled?: boolean;
  rulesCount: number;
}

/**
 * ExportDropdown - Dropdown button for exporting rules in different formats.
 */
export const ExportDropdown: React.FC<ExportDropdownProps> = ({
  onExport,
  disabled = false,
  rulesCount,
}) => {
  const t = useT();
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  const EXPORT_OPTIONS: { format: ExportFormat; label: string; icon: React.ReactNode }[] = useMemo(
    () => [
      { format: 'csv', label: t('exportDropdown.formatCsv'), icon: <FileSpreadsheet size={14} /> },
      { format: 'json', label: t('exportDropdown.formatJson'), icon: <FileJson size={14} /> },
      { format: 'txt', label: t('exportDropdown.formatTxt'), icon: <FileText size={14} /> },
    ],
    [t]
  );

  // Close dropdown on outside click
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    };

    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside);
    }

    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
    };
  }, [isOpen]);

  // Close on escape
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setIsOpen(false);
      }
    };

    if (isOpen) {
      document.addEventListener('keydown', handleKeyDown);
    }

    return () => {
      document.removeEventListener('keydown', handleKeyDown);
    };
  }, [isOpen]);

  const handleExport = (format: ExportFormat) => {
    onExport(format);
    setIsOpen(false);
  };

  return (
    <div className="relative" ref={dropdownRef}>
      <Button
        variant="outline"
        size="md"
        onClick={() => setIsOpen(!isOpen)}
        disabled={disabled || rulesCount === 0}
        title={
          rulesCount === 0 ? t('exportDropdown.noRulesToExport') : t('exportDropdown.exportRules')
        }
      >
        <Download size={16} className="mr-1" />
        {t('common.export')}
        <ChevronDown
          size={14}
          className={cn('ml-1 transition-transform', isOpen && 'rotate-180')}
        />
      </Button>

      {isOpen && (
        <div
          className={cn(
            'absolute right-0 mt-2 w-48 rounded-lg bg-white shadow-lg border border-slate-200 py-1 z-50',
            'animate-in fade-in slide-in-from-top-2 duration-150'
          )}
        >
          <div className="px-3 py-2 border-b border-slate-100">
            <p className="text-xs text-slate-500">
              {rulesCount === 1
                ? t('exportDropdown.exportCountSingular', { count: String(rulesCount) })
                : t('exportDropdown.exportCountPlural', { count: String(rulesCount) })}
            </p>
          </div>

          {EXPORT_OPTIONS.map((option) => (
            <button
              key={option.format}
              onClick={() => handleExport(option.format)}
              className={cn(
                'w-full flex items-center gap-2 px-3 py-2 text-sm text-slate-700',
                'hover:bg-slate-50 transition-colors'
              )}
            >
              {option.icon}
              {option.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
};

export default ExportDropdown;
