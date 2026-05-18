import React from 'react';
import { Upload, FileText, AlertCircle, FileUp, Table, Info } from 'lucide-react';
import type { RuleType } from '@openpath/shared/rules-validation';
import { Modal } from './ui/Modal';
import { Button } from './ui/Button';
import { cn } from '../lib/utils';
import { useBulkImportModalState } from '../hooks/useBulkImportModalState';

interface BulkImportModalProps {
  isOpen: boolean;
  onClose: () => void;
  onImport: (values: string[], type: RuleType) => Promise<{ created: number; total: number }>;
  /** Pre-populate the textarea with this text (e.g., from a dropped file) */
  initialText?: string;
}

const RULE_TYPE_OPTIONS: { value: RuleType; label: string; description: string }[] = [
  {
    value: 'whitelist',
    label: 'Allowed domains',
    description: 'Domains that will be accessible',
  },
  {
    value: 'blocked_subdomain',
    label: 'Blocked subdomains',
    description: 'Specific subdomains to block',
  },
  {
    value: 'blocked_path',
    label: 'Blocked paths',
    description: 'Specific paths to block',
  },
];

const RULE_TYPE_UI: Record<
  RuleType,
  { label: string; placeholder: string; hint: string; emptyError: string }
> = {
  whitelist: {
    label: 'Domains to import',
    placeholder:
      'Paste domains here, one per line:\n\ngoogle.com\nyoutube.com\nexample.org\n\nYou can also paste lists separated by commas or spaces.',
    hint: 'Paste or type domains above',
    emptyError: 'Enter at least one domain',
  },
  blocked_subdomain: {
    label: 'Subdomains to import',
    placeholder:
      'Paste subdomains here, one per line:\n\nads.example.com\ntracker.example.com\n*.ads.example.com\n\nYou can also paste lists separated by commas or spaces.',
    hint: 'Paste or type subdomains above',
    emptyError: 'Enter at least one subdomain',
  },
  blocked_path: {
    label: 'Paths to import',
    placeholder:
      'Paste paths here, one per line:\n\nexample.com/ads\nexample.com/tracking/*\n*/analytics/*\n\nYou can also paste lists separated by commas or spaces.',
    hint: 'Paste or type paths above',
    emptyError: 'Enter at least one path',
  },
};

/**
 * BulkImportModal - Modal for importing multiple rules at once.
 * Supports plain text, CSV with headers, and simple CSV formats.
 */
export const BulkImportModal: React.FC<BulkImportModalProps> = ({
  isOpen,
  onClose,
  onImport,
  initialText = '',
}) => {
  const {
    dropZoneRef,
    error,
    handleClose,
    handleDragEnter,
    handleDragLeave,
    handleDragOver,
    handleDrop,
    handleImport,
    invalidCount,
    isDragOver,
    isImporting,
    parseResult,
    ruleType,
    setError,
    setRuleType,
    setText,
    text,
    validCount,
    validationResults,
    valueCount,
  } = useBulkImportModalState({
    emptyErrorByType: {
      whitelist: RULE_TYPE_UI.whitelist.emptyError,
      blocked_subdomain: RULE_TYPE_UI.blocked_subdomain.emptyError,
      blocked_path: RULE_TYPE_UI.blocked_path.emptyError,
    },
    initialText,
    isOpen,
    onClose,
    onImport,
  });

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Import rules" className="max-w-2xl">
      <div className="space-y-4">
        {/* Rule type selector */}
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-2">Rule type</label>
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
            {RULE_TYPE_OPTIONS.map((option) => (
              <button
                key={option.value}
                type="button"
                onClick={() => setRuleType(option.value)}
                className={cn(
                  'p-3 rounded-lg border-2 text-left transition-all',
                  ruleType === option.value
                    ? 'border-blue-500 bg-blue-50'
                    : 'border-slate-200 hover:border-slate-300 bg-white'
                )}
              >
                <div
                  className={cn(
                    'text-sm font-medium',
                    ruleType === option.value ? 'text-blue-700' : 'text-slate-700'
                  )}
                >
                  {option.label}
                </div>
                <div className="text-xs text-slate-500 mt-0.5">{option.description}</div>
              </button>
            ))}
          </div>
        </div>

        {/* Textarea for rule values with drag & drop */}
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-2">
            <FileText size={14} className="inline mr-1" />
            {RULE_TYPE_UI[ruleType].label}
          </label>
          <div
            ref={dropZoneRef}
            onDragEnter={handleDragEnter}
            onDragLeave={handleDragLeave}
            onDragOver={handleDragOver}
            onDrop={handleDrop}
            className="relative"
            data-testid="drop-zone"
          >
            <textarea
              value={text}
              onChange={(e) => {
                setText(e.target.value);
                setError(null);
              }}
              placeholder={RULE_TYPE_UI[ruleType].placeholder}
              className={cn(
                'w-full h-48 px-3 py-2 text-sm font-mono',
                'border-2 rounded-lg resize-none transition-all',
                'focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent',
                isDragOver
                  ? 'border-blue-400 bg-blue-50 border-dashed'
                  : error
                    ? 'border-red-300 bg-red-50'
                    : 'border-slate-300'
              )}
              disabled={isImporting}
            />

            {/* Drag overlay */}
            {isDragOver && (
              <div
                className="absolute inset-0 flex items-center justify-center bg-blue-50/90 rounded-lg border-2 border-dashed border-blue-400 pointer-events-none"
                data-testid="drag-overlay"
              >
                <div className="text-center">
                  <FileUp size={32} className="mx-auto text-blue-500 mb-2" />
                  <p className="text-sm font-medium text-blue-700">Drop the file here</p>
                  <p className="text-xs text-blue-500 mt-1">.txt, .csv, .list</p>
                </div>
              </div>
            )}
          </div>

          {/* Count indicator and drag hint */}
          <div className="flex items-center justify-between mt-2">
            <div className="text-xs text-slate-500">
              {valueCount > 0 ? (
                <span className="flex items-center gap-2">
                  <span className="text-blue-600 font-medium">{validCount} valid</span>
                  {invalidCount > 0 && (
                    <span className="text-red-500 font-medium">{invalidCount} invalid</span>
                  )}
                  <span className="text-slate-400">({valueCount} detected)</span>
                </span>
              ) : (
                RULE_TYPE_UI[ruleType].hint
              )}
            </div>
            <div className="text-xs text-slate-400">
              <FileUp size={12} className="inline mr-1" />
              Drag .txt or .csv files here
            </div>
          </div>

          {/* CSV format indicator */}
          {parseResult.format !== 'plain-text' && valueCount > 0 && (
            <div className="flex items-center gap-2 p-2 bg-slate-50 rounded-lg text-xs text-slate-600">
              <Table size={14} className="text-slate-400" />
              <span>
                CSV format detected
                {parseResult.valueColumn && (
                  <span className="text-slate-500">
                    {' '}
                    - column: <strong>{parseResult.valueColumn}</strong>
                  </span>
                )}
              </span>
            </div>
          )}

          {/* CSV warnings */}
          {parseResult.warnings.length > 0 && (
            <div className="flex items-start gap-2 p-2 bg-amber-50 rounded-lg text-xs text-amber-700">
              <Info size={14} className="text-amber-500 mt-0.5 flex-shrink-0" />
              <div>
                {parseResult.warnings.map((warning, i) => (
                  <div key={i}>{warning}</div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Validation errors detail */}
        {invalidCount > 0 && (
          <div className="p-3 bg-red-50 rounded-lg text-sm" data-testid="validation-errors">
            <div className="flex items-center gap-2 text-red-700 font-medium mb-2">
              <AlertCircle size={16} />
              {invalidCount}{' '}
              {invalidCount === 1 ? 'value with invalid format' : 'values with invalid format'}
            </div>
            <ul className="space-y-1 text-xs text-red-600">
              {validationResults.invalid.slice(0, 5).map((item, i) => (
                <li key={i} className="flex gap-2">
                  <code className="font-mono bg-red-100 px-1 rounded truncate max-w-[200px]">
                    {item.value}
                  </code>
                  <span className="text-red-500">{item.error}</span>
                </li>
              ))}
              {invalidCount > 5 && (
                <li className="text-red-400 italic">...and {String(invalidCount - 5)} more</li>
              )}
            </ul>
            {validCount > 0 && (
              <p className="text-xs text-slate-500 mt-2">
                Only the {String(validCount)} valid {validCount === 1 ? 'value' : 'values'} will be
                imported.
              </p>
            )}
          </div>
        )}

        {/* Error message */}
        {error && (
          <div className="flex items-center gap-2 p-3 bg-red-50 text-red-700 rounded-lg text-sm">
            <AlertCircle size={16} />
            {error}
          </div>
        )}

        {/* Actions */}
        <div className="flex justify-end gap-3 pt-2">
          <Button variant="outline" onClick={handleClose} disabled={isImporting}>
            Cancel
          </Button>
          <Button
            onClick={() => void handleImport()}
            disabled={validCount === 0 || isImporting}
            isLoading={isImporting}
          >
            <Upload size={14} className="mr-1" />
            Import {validCount > 0 && `(${String(validCount)})`}
          </Button>
        </div>
      </div>
    </Modal>
  );
};

export default BulkImportModal;
