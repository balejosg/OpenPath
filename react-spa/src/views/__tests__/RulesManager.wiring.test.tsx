import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/react';
import { RulesManager } from '../RulesManager';

const mockToast = vi.hoisted(() => ({
  success: vi.fn(),
  error: vi.fn(),
}));

const mockExportRules = vi.hoisted(() => ({
  exportRules: vi.fn(),
}));

const mockViewModel = vi.hoisted(() => ({
  handleAddRule: vi.fn().mockResolvedValue(undefined),
  handleBulkDelete: vi.fn().mockResolvedValue(undefined),
  handleDragEnter: vi.fn(),
  handleDragLeave: vi.fn(),
  handleDragOver: vi.fn(),
  handleDrop: vi.fn(),
  handleInputChange: vi.fn(),
  handleViewModeChange: vi.fn(),
  openImportModal: vi.fn(),
  closeImportModal: vi.fn(),
  setFilter: vi.fn(),
  setPage: vi.fn(),
  collectionSetFilter: vi.fn(),
  collectionSetPage: vi.fn(),
  collectionSetSearch: vi.fn(),
  collectionRefetch: vi.fn().mockResolvedValue(undefined),
  collectionAddRule: vi.fn().mockResolvedValue(true),
  collectionDeleteRule: vi.fn().mockResolvedValue(undefined),
  collectionBulkDeleteRules: vi.fn().mockResolvedValue(undefined),
  collectionBulkCreateRules: vi.fn().mockResolvedValue({ created: 1, total: 1 }),
  collectionUpdateRule: vi.fn().mockResolvedValue(true),
  collectionToggleSelection: vi.fn(),
  collectionToggleSelectAll: vi.fn(),
  collectionClearSelection: vi.fn(),
}));

const mockGroupSettings = vi.hoisted(() => ({
  metadata: null as null | {
    displayName: string;
    status: 'Active' | 'Inactive';
    visibility: 'private' | 'instance_public';
  },
  isOpen: false,
  open: vi.fn(),
  close: vi.fn(),
  saving: false,
  error: null as string | null,
  description: 'Grupo 1',
  status: 'Active' as 'Active' | 'Inactive',
  visibility: 'private' as 'private' | 'instance_public',
  setDescription: vi.fn(),
  setStatus: vi.fn(),
  setVisibility: vi.fn(),
  save: vi.fn(),
}));

vi.mock('../../hooks/useGroupSettings', () => ({
  useGroupSettings: () => mockGroupSettings,
}));

vi.mock('../../components/ui/Toast', () => ({
  useToast: () => ({
    success: mockToast.success,
    error: mockToast.error,
    ToastContainer: () => <div data-testid="toast-container" />,
  }),
}));

vi.mock('../../lib/exportRules', () => ({
  exportRules: mockExportRules.exportRules,
}));

vi.mock('../../hooks/useRulesManagerViewModel', () => ({
  useRulesManagerViewModel: ({
    onToast,
    onError,
  }: {
    onToast: (message: string, type: 'success' | 'error', undoAction?: () => void) => void;
    onError: (message: string) => void;
  }) => {
    onToast('saved', 'success');
    onToast('failed', 'error');
    onError('direct error');

    const rule = {
      id: 'rule-1',
      groupId: 'group-1',
      type: 'whitelist' as const,
      value: 'example.com',
      comment: null,
      createdAt: '2024-01-15T10:00:00Z',
    };

    return {
      viewMode: 'flat' as const,
      collection: {
        mode: 'flat' as const,
        rules: [rule],
        domainGroups: [],
        totalRules: 51,
        totalGroups: 0,
        counts: { all: 51, allowed: 50, blocked: 1, disabled: 0 },
        loading: false,
        error: null,
        filter: 'all' as const,
        setFilter: mockViewModel.collectionSetFilter,
        search: '',
        setSearch: mockViewModel.collectionSetSearch,
        page: 1,
        setPage: mockViewModel.collectionSetPage,
        totalPages: 2,
        hasMore: true,
        selection: {
          selectedIds: new Set(['rule-1']),
          toggleSelection: mockViewModel.collectionToggleSelection,
          toggleSelectAll: mockViewModel.collectionToggleSelectAll,
          selectGroup: vi.fn(),
          deselectGroup: vi.fn(),
          clearSelection: mockViewModel.collectionClearSelection,
          isAllSelected: false,
          hasSelection: true,
        },
        actions: {
          addRule: mockViewModel.collectionAddRule,
          deleteRule: mockViewModel.collectionDeleteRule,
          bulkDeleteRules: mockViewModel.collectionBulkDeleteRules,
          bulkCreateRules: mockViewModel.collectionBulkCreateRules,
          updateRule: mockViewModel.collectionUpdateRule,
        },
        refetch: mockViewModel.collectionRefetch,
      },
      newValue: 'new.example.com',
      inputError: '',
      adding: false,
      bulkDeleting: false,
      showImportModal: false,
      isDragOver: false,
      importInitialText: '',
      detectedType: { type: 'whitelist' as const, confidence: 'high' as const },
      validationError: '',
      tabs: [
        { id: 'all' as const, label: 'Todos', count: 51 },
        { id: 'allowed' as const, label: 'Permitidas', count: 50 },
        { id: 'blocked' as const, label: 'Bloqueadas', count: 1 },
        { id: 'disabled' as const, label: 'Inhabilitadas', count: 0 },
      ],
      emptyMessage: 'No rules configured',
      handleAddRule: mockViewModel.handleAddRule,
      handleInputChange: mockViewModel.handleInputChange,
      handleBulkDelete: mockViewModel.handleBulkDelete,
      handleDragEnter: mockViewModel.handleDragEnter,
      handleDragLeave: mockViewModel.handleDragLeave,
      handleDragOver: mockViewModel.handleDragOver,
      handleDrop: mockViewModel.handleDrop,
      handleImportModalClose: mockViewModel.closeImportModal,
      handleViewModeChange: mockViewModel.handleViewModeChange,
      openImportModal: mockViewModel.openImportModal,
      closeImportModal: mockViewModel.closeImportModal,
      setSearch: mockViewModel.collectionSetSearch,
      setFilter: mockViewModel.setFilter,
      setPage: mockViewModel.setPage,
      setShowImportModal: vi.fn(),
    };
  },
}));

describe('RulesManager wiring', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockGroupSettings.metadata = null;
    mockGroupSettings.isOpen = false;
  });

  it('passes collection callbacks to toolbar, table, pagination and bulk actions', () => {
    render(<RulesManager groupId="group-1" groupName="Wiring Group" onBack={vi.fn()} />);

    expect(mockToast.success).toHaveBeenCalledWith('saved', undefined);
    expect(mockToast.error).toHaveBeenCalledWith('failed');
    expect(mockToast.error).toHaveBeenCalledWith('direct error');

    fireEvent.change(screen.getByPlaceholderText(/search across/i), {
      target: { value: 'example' },
    });
    expect(mockViewModel.collectionSetSearch).toHaveBeenCalledWith('example');

    fireEvent.change(screen.getByPlaceholderText(/add domain/i), {
      target: { value: 'other.example.com' },
    });
    expect(mockViewModel.handleInputChange).toHaveBeenCalledWith('other.example.com');

    fireEvent.click(screen.getByRole('button', { name: /add/i }));
    expect(mockViewModel.handleAddRule).toHaveBeenCalledWith(false);

    fireEvent.keyDown(screen.getByPlaceholderText(/add domain/i), {
      key: 'Enter',
    });
    expect(mockViewModel.handleAddRule).toHaveBeenCalledTimes(2);

    fireEvent.click(screen.getByRole('button', { name: /import/i }));
    expect(mockViewModel.openImportModal).toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: /export/i }));
    fireEvent.click(screen.getByRole('button', { name: /csv/i }));
    expect(mockExportRules.exportRules).toHaveBeenCalledWith(
      expect.arrayContaining([expect.objectContaining({ value: 'example.com' })]),
      'csv',
      'Wiring Group-rules'
    );

    fireEvent.click(screen.getByRole('tab', { name: /permitidas/i }));
    expect(mockViewModel.collectionSetFilter).toHaveBeenCalledWith('allowed');

    fireEvent.click(screen.getByTitle('Deselect'));
    expect(mockViewModel.collectionToggleSelection).toHaveBeenCalledWith('rule-1');

    fireEvent.click(screen.getByTitle('Delete'));
    expect(mockViewModel.collectionDeleteRule).toHaveBeenCalledWith(
      expect.objectContaining({ id: 'rule-1' })
    );

    const paginationControls = screen.getByText('Page 1 of 2').closest('div');
    if (!paginationControls) throw new Error('Pagination controls not found');
    fireEvent.click(paginationControls.querySelectorAll('button')[1]);
    expect(mockViewModel.collectionSetPage).toHaveBeenCalledWith(2);

    fireEvent.click(screen.getAllByRole('button', { name: /delete/i })[1]);
    expect(mockViewModel.handleBulkDelete).toHaveBeenCalled();

    fireEvent.click(screen.getByTitle('Cancel selection'));
    expect(mockViewModel.collectionClearSelection).toHaveBeenCalled();
  });

  it('uses read-only mode to disable mutable page handlers', () => {
    render(<RulesManager groupId="group-1" groupName="Read Only" readOnly onBack={vi.fn()} />);

    expect(screen.getByText('Read-only view')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /add/i })).not.toBeInTheDocument();

    const container = screen.getByText('Rules Management').closest('div[class*="space-y-6"]');
    if (!container) throw new Error('Container not found');

    fireEvent.dragEnter(container);
    expect(mockViewModel.handleDragEnter).not.toHaveBeenCalled();
  });

  it('shows the settings gear when editable and opens the drawer', () => {
    mockGroupSettings.metadata = {
      displayName: 'Grupo 1',
      status: 'Active',
      visibility: 'private',
    };
    render(<RulesManager groupId="group-1" groupName="Wiring Group" onBack={vi.fn()} />);

    fireEvent.click(screen.getByRole('button', { name: /settings/i }));
    expect(mockGroupSettings.open).toHaveBeenCalled();
  });

  it('renders the settings drawer when open', () => {
    mockGroupSettings.metadata = {
      displayName: 'Grupo 1',
      status: 'Active',
      visibility: 'private',
    };
    mockGroupSettings.isOpen = true;
    render(<RulesManager groupId="group-1" groupName="Wiring Group" onBack={vi.fn()} />);

    expect(screen.getByText('Settings: Wiring Group')).toBeInTheDocument();
  });

  it('hides the settings gear in read-only mode', () => {
    mockGroupSettings.metadata = {
      displayName: 'Grupo 1',
      status: 'Active',
      visibility: 'private',
    };
    render(<RulesManager groupId="group-1" groupName="Read Only" readOnly onBack={vi.fn()} />);

    expect(screen.queryByRole('button', { name: /settings/i })).not.toBeInTheDocument();
  });
});
