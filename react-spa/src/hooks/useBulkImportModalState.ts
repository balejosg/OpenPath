import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { DragEvent } from 'react';

import type { RuleType } from '@openpath/shared/rules-validation';

import { useT } from '../i18n/product-i18n';
import { parseCSV, type CSVParseResult } from '../lib/csv-parser';
import { validateRuleValue } from '../lib/ruleDetection';
import { reportError } from '../lib/reportError';

interface UseBulkImportModalStateOptions {
  initialText: string;
  isOpen: boolean;
  onClose: () => void;
  onImport: (values: string[], type: RuleType) => Promise<{ created: number; total: number }>;
  emptyErrorByType: Record<RuleType, string>;
}

export function useBulkImportModalState({
  initialText,
  isOpen,
  onClose,
  onImport,
  emptyErrorByType,
}: UseBulkImportModalStateOptions) {
  const t = useT();
  const [text, setText] = useState(initialText);
  const [ruleType, setRuleType] = useState<RuleType>('whitelist');
  const [isImporting, setIsImporting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [isDragOver, setIsDragOver] = useState(false);

  const dropZoneRef = useRef<HTMLDivElement>(null);
  const dragCounter = useRef(0);

  useEffect(() => {
    if (initialText) {
      setText(initialText);
    }
  }, [initialText]);

  useEffect(() => {
    if (!isOpen) {
      dragCounter.current = 0;
      setIsDragOver(false);
    }
  }, [isOpen]);

  const parseResult: CSVParseResult = useMemo(() => {
    if (!text.trim()) {
      return {
        values: [],
        format: 'plain-text',
        totalRows: 0,
        skippedRows: 0,
        warnings: [],
      };
    }

    return parseCSV(text, { t });
  }, [text, t]);

  const validationResults = useMemo(() => {
    const valid: string[] = [];
    const invalid: { value: string; error: string }[] = [];

    for (const value of parseResult.values) {
      const result = validateRuleValue(value, ruleType);
      if (result.valid) {
        valid.push(value);
      } else {
        invalid.push({ value, error: result.error ?? t('bulkImport.error.invalidFormat') });
      }
    }

    return { valid, invalid };
  }, [parseResult.values, ruleType, t]);

  const valueCount = parseResult.values.length;
  const validCount = validationResults.valid.length;
  const invalidCount = validationResults.invalid.length;

  const resetState = useCallback(() => {
    setText('');
    setRuleType('whitelist');
    setError(null);
    setIsDragOver(false);
    dragCounter.current = 0;
  }, []);

  const handleImport = useCallback(async () => {
    if (validCount === 0) {
      setError(invalidCount > 0 ? t('bulkImport.error.noValidFormat') : emptyErrorByType[ruleType]);
      return;
    }

    setIsImporting(true);
    setError(null);

    try {
      const result = await onImport(validationResults.valid, ruleType);

      if (result.created > 0) {
        resetState();
        onClose();
      } else {
        setError(t('bulkImport.error.allExist'));
      }
    } catch (err) {
      reportError('Import failed:', err);
      setError(t('bulkImport.error.importFailed'));
    } finally {
      setIsImporting(false);
    }
  }, [
    emptyErrorByType,
    invalidCount,
    onClose,
    onImport,
    resetState,
    ruleType,
    t,
    validCount,
    validationResults.valid,
  ]);

  const handleClose = useCallback(() => {
    if (isImporting) {
      return;
    }

    resetState();
    onClose();
  }, [isImporting, onClose, resetState]);

  const readFileContents = useCallback((file: File): Promise<string> => {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = (event) => {
        const content = event.target?.result;
        if (typeof content === 'string') {
          resolve(content);
        } else {
          reject(new Error('Failed to read file'));
        }
      };
      reader.onerror = () => reject(new Error('Failed to read file'));
      reader.readAsText(file);
    });
  }, []);

  const handleFileDrop = useCallback(
    async (files: FileList | null) => {
      if (!files || files.length === 0) return;

      setError(null);
      const validFiles = Array.from(files).filter(
        (file) =>
          file.type === 'text/plain' ||
          file.name.endsWith('.txt') ||
          file.name.endsWith('.csv') ||
          file.name.endsWith('.list')
      );

      if (validFiles.length === 0) {
        setError(t('bulkImport.error.textFilesOnly'));
        return;
      }

      try {
        const contents = await Promise.all(validFiles.map(readFileContents));
        const combinedContent = contents.join('\n');
        setText((previous) => (previous ? `${previous}\n${combinedContent}` : combinedContent));
      } catch {
        setError(t('bulkImport.error.readFiles'));
      }
    },
    [readFileContents, t]
  );

  const handleDragEnter = useCallback((event: DragEvent) => {
    event.preventDefault();
    event.stopPropagation();
    dragCounter.current += 1;
    if (event.dataTransfer.items.length > 0) {
      setIsDragOver(true);
    }
  }, []);

  const handleDragLeave = useCallback((event: DragEvent) => {
    event.preventDefault();
    event.stopPropagation();
    dragCounter.current -= 1;
    if (dragCounter.current === 0) {
      setIsDragOver(false);
    }
  }, []);

  const handleDragOver = useCallback((event: DragEvent) => {
    event.preventDefault();
    event.stopPropagation();
  }, []);

  const handleDrop = useCallback(
    (event: DragEvent) => {
      event.preventDefault();
      event.stopPropagation();
      setIsDragOver(false);
      dragCounter.current = 0;
      void handleFileDrop(event.dataTransfer.files);
    },
    [handleFileDrop]
  );

  return {
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
  };
}
