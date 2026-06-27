import { createElement, useCallback, useMemo, useRef, useState } from 'react';
import type { DragEvent } from 'react';
import { Ban, Check, PowerOff } from 'lucide-react';
import { detectRuleType, validateRuleValue } from '../lib/ruleDetection';
import { readMultipleFiles } from '../lib/fileReader';
import {
  useManagedRulesCollection,
  type ManagedRulesCollectionMode,
  type ManagedRulesCounts,
  type ManagedRulesFilterType,
} from './useManagedRulesCollection';

export function buildRulesManagerTabs(counts: ManagedRulesCounts) {
  return [
    { id: 'all' as ManagedRulesFilterType, label: 'Todos', count: counts.all },
    {
      id: 'allowed' as ManagedRulesFilterType,
      label: 'Permitidas',
      count: counts.allowed,
      icon: createElement(Check, { size: 14 }),
    },
    {
      id: 'blocked' as ManagedRulesFilterType,
      label: 'Bloqueadas',
      count: counts.blocked,
      icon: createElement(Ban, { size: 14 }),
    },
    {
      id: 'disabled' as ManagedRulesFilterType,
      label: 'Inhabilitadas',
      count: counts.disabled,
      icon: createElement(PowerOff, { size: 14 }),
    },
  ];
}

export type ViewMode = ManagedRulesCollectionMode;

interface UseRulesManagerViewModelOptions {
  groupId: string;
  onToast: (message: string, type: 'success' | 'error', undoAction?: () => void) => void;
  onError: (message: string) => void;
}

export function useRulesManagerViewModel({
  groupId,
  onToast,
  onError,
}: UseRulesManagerViewModelOptions) {
  const [newValue, setNewValue] = useState('');
  const [inputError, setInputError] = useState('');
  const [adding, setAdding] = useState(false);
  const [bulkDeleting, setBulkDeleting] = useState(false);
  const [showImportModal, setShowImportModal] = useState(false);
  const [isDragOver, setIsDragOver] = useState(false);
  const [importInitialText, setImportInitialText] = useState('');
  const dragCounter = useRef(0);

  const collection = useManagedRulesCollection({
    groupId,
    onToast,
  });
  const viewMode = collection.viewMode.current;

  const whitelistDomains = useMemo(() => {
    return collection.rules.filter((rule) => rule.type === 'whitelist').map((rule) => rule.value);
  }, [collection.rules]);

  const detectedType = useMemo(() => {
    if (!newValue.trim()) return null;
    return detectRuleType(newValue, whitelistDomains);
  }, [newValue, whitelistDomains]);

  const validationError = useMemo(() => {
    if (!newValue.trim() || !detectedType) return '';
    const result = validateRuleValue(newValue, detectedType.type);
    return result.valid ? '' : (result.error ?? '');
  }, [newValue, detectedType]);

  const handleAddRule = async (readOnly: boolean) => {
    if (readOnly) return;
    if (!newValue.trim() || adding) return;

    if (detectedType) {
      const validation = validateRuleValue(newValue, detectedType.type);
      if (!validation.valid) {
        setInputError(validation.error ?? 'Invalid format');
        return;
      }
    }

    setAdding(true);
    setInputError('');

    const succeeded = await collection.actions.addRule(newValue);
    if (succeeded) {
      setNewValue('');
    }

    setAdding(false);
  };

  const handleInputChange = (value: string) => {
    setNewValue(value);
    if (inputError) setInputError('');
  };

  const handleBulkDelete = async () => {
    setBulkDeleting(true);
    await collection.actions.bulkDeleteRules();
    setBulkDeleting(false);
  };

  const handleDragEnter = useCallback((event: DragEvent) => {
    event.preventDefault();
    event.stopPropagation();
    dragCounter.current++;
    if (event.dataTransfer.items.length > 0) {
      setIsDragOver(true);
    }
  }, []);

  const handleDragLeave = useCallback((event: DragEvent) => {
    event.preventDefault();
    event.stopPropagation();
    dragCounter.current--;
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

      const { files } = event.dataTransfer;
      if (files.length === 0) return;

      void (async () => {
        try {
          const result = await readMultipleFiles(files);
          if (result.content) {
            setImportInitialText(result.content);
            setShowImportModal(true);
            if (result.skippedFiles.length > 0) {
              onError(`Archivos ignorados: ${result.skippedFiles.join(', ')}`);
            }
          } else if (result.skippedFiles.length > 0) {
            onError('Solo se permiten archivos .txt, .csv o .list');
          }
        } catch {
          onError('Unable to read files');
        }
      })();
    },
    [onError]
  );

  const handleImportModalClose = useCallback(() => {
    setShowImportModal(false);
    setImportInitialText('');
  }, []);

  const handleViewModeChange = (nextViewMode: ViewMode) => {
    collection.viewMode.change(nextViewMode);
  };

  const emptyMessage = collection.filters.search
    ? 'No results found for your search'
    : collection.filters.active === 'allowed'
      ? 'No allowed domains'
      : collection.filters.active === 'blocked'
        ? 'No blocked domains'
        : collection.filters.active === 'disabled'
          ? 'No disabled rules'
          : 'No rules configured. Add one to get started.';

  const tabs = buildRulesManagerTabs(collection.filters.counts);

  return {
    viewMode,
    collection,
    newValue,
    inputError,
    adding,
    bulkDeleting,
    showImportModal,
    isDragOver,
    importInitialText,
    detectedType,
    validationError,
    tabs,
    emptyMessage,
    handleAddRule,
    handleInputChange,
    handleBulkDelete,
    handleDragEnter,
    handleDragLeave,
    handleDragOver,
    handleDrop,
    handleImportModalClose,
    handleViewModeChange,
    openImportModal: () => setShowImportModal(true),
    closeImportModal: handleImportModalClose,
    setSearch: collection.filters.setSearch,
    setFilter: collection.filters.setActive,
    setPage: collection.setPage,
    setShowImportModal,
  };
}
