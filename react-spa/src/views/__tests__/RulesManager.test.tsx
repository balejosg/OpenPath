import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { RulesManager } from '../RulesManager';

// Mock the hooks and components
const mockBulkCreateRules = vi.fn().mockResolvedValue({ created: 5, total: 5 });

vi.mock('../../hooks/useRulesManager', () => ({
  useRulesManager: () => ({
    rules: [
      {
        id: '1',
        groupId: 'test-group',
        type: 'whitelist',
        value: 'google.com',
        comment: null,
        createdAt: '2024-01-15T10:00:00Z',
      },
    ],
    total: 1,
    loading: false,
    error: null,
    page: 1,
    setPage: vi.fn(),
    totalPages: 1,
    hasMore: false,
    filter: 'all',
    setFilter: vi.fn(),
    search: '',
    setSearch: vi.fn(),
    counts: { all: 1, allowed: 1, automatic: 0, blocked: 0 },
    // Selection state
    selectedIds: new Set<string>(),
    toggleSelection: vi.fn(),
    toggleSelectAll: vi.fn(),
    clearSelection: vi.fn(),
    isAllSelected: false,
    hasSelection: false,
    // Actions
    addRule: vi.fn().mockResolvedValue(true),
    deleteRule: vi.fn(),
    bulkDeleteRules: vi.fn().mockResolvedValue(undefined),
    bulkCreateRules: mockBulkCreateRules,
    updateRule: vi.fn().mockResolvedValue(true),
    refetch: vi.fn(),
  }),
  FilterType: {},
}));

vi.mock('../../hooks/useGroupedRulesManager', () => ({
  useGroupedRulesManager: () => ({
    domainGroups: [
      {
        root: 'google.com',
        rules: [
          {
            id: '1',
            groupId: 'test-group',
            type: 'whitelist',
            value: 'google.com',
            comment: null,
            createdAt: '2024-01-15T10:00:00Z',
          },
        ],
        status: 'allowed',
      },
    ],
    totalGroups: 1,
    totalRules: 1,
    loading: false,
    error: null,
    page: 1,
    setPage: vi.fn(),
    totalPages: 1,
    hasMore: false,
    filter: 'all',
    setFilter: vi.fn(),
    search: '',
    setSearch: vi.fn(),
    counts: { all: 1, allowed: 1, automatic: 0, blocked: 0 },
    selectedIds: new Set<string>(),
    toggleSelection: vi.fn(),
    toggleSelectAll: vi.fn(),
    selectGroup: vi.fn(),
    deselectGroup: vi.fn(),
    clearSelection: vi.fn(),
    isAllSelected: false,
    hasSelection: false,
    addRule: vi.fn().mockResolvedValue(true),
    deleteRule: vi.fn(),
    bulkDeleteRules: vi.fn().mockResolvedValue(undefined),
    bulkCreateRules: mockBulkCreateRules,
    updateRule: vi.fn().mockResolvedValue(true),
    refetch: vi.fn(),
  }),
}));

const mockToastError = vi.fn();
vi.mock('../../components/ui/Toast', () => ({
  useToast: () => ({
    success: vi.fn(),
    error: mockToastError,
    ToastContainer: () => null,
  }),
}));

describe('RulesManager View', () => {
  const defaultProps = {
    groupId: 'test-group',
    groupName: 'Test Group',
    onBack: vi.fn(),
  };

  it('renders view with group name', () => {
    render(<RulesManager {...defaultProps} />);

    expect(screen.getByText('Gestión de Reglas')).toBeInTheDocument();
    expect(screen.getByText('Test Group')).toBeInTheDocument();
  });

  it('renders back button', () => {
    render(<RulesManager {...defaultProps} />);

    const backButton = screen.getByTitle('Volver a grupos');
    expect(backButton).toBeInTheDocument();
  });

  it('calls onBack when back button is clicked', () => {
    const handleBack = vi.fn();
    render(<RulesManager {...defaultProps} onBack={handleBack} />);

    fireEvent.click(screen.getByTitle('Volver a grupos'));
    expect(handleBack).toHaveBeenCalled();
  });

  it('renders search input', () => {
    render(<RulesManager {...defaultProps} />);

    expect(screen.getByPlaceholderText(/buscar en/i)).toBeInTheDocument();
  });

  it('renders add rule input and button', () => {
    render(<RulesManager {...defaultProps} />);

    expect(screen.getByPlaceholderText(/añadir dominio/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /añadir/i })).toBeInTheDocument();
  });

  it('renders filter tabs', () => {
    render(<RulesManager {...defaultProps} />);

    expect(screen.getByRole('tab', { name: /todos/i })).toBeInTheDocument();
    expect(screen.getByRole('tab', { name: /permitidas/i })).toBeInTheDocument();
    expect(screen.getByRole('tab', { name: /bloqueadas/i })).toBeInTheDocument();
  });

  it('renders rules table with data', () => {
    render(<RulesManager {...defaultProps} />);

    expect(screen.getByText('google.com')).toBeInTheDocument();
  });
});

// Helper to create mock File objects
function createMockFile(name: string, content: string, type = 'text/plain'): File {
  const blob = new Blob([content], { type });
  return new File([blob], name, { type });
}

// Helper to create a mock DataTransfer object
function createMockDataTransfer(files: File[]): DataTransfer {
  return {
    files: files as unknown as FileList,
    items: files.map((f) => ({
      kind: 'file',
      type: f.type,
      getAsFile: () => f,
    })) as unknown as DataTransferItemList,
    types: ['Files'],
    getData: () => '',
    setData: () => {
      /* noop */
    },
    clearData: () => {
      /* noop */
    },
    setDragImage: () => {
      /* noop */
    },
    dropEffect: 'none',
    effectAllowed: 'all',
  } as unknown as DataTransfer;
}

describe('RulesManager - Page-level Drag and Drop', () => {
  const defaultProps = {
    groupId: 'test-group',
    groupName: 'Test Group',
    onBack: vi.fn(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('shows drag overlay when dragging file over page', () => {
    render(<RulesManager {...defaultProps} />);

    const container = screen.getByText('Gestión de Reglas').closest('div[class*="space-y-6"]');
    if (!container) throw new Error('Container not found');

    const file = createMockFile('domains.txt', 'google.com');
    const dataTransfer = createMockDataTransfer([file]);

    fireEvent.dragEnter(container, { dataTransfer });

    expect(screen.getByTestId('page-drag-overlay')).toBeInTheDocument();
    expect(screen.getByText('Suelta los archivos aquí')).toBeInTheDocument();
  });

  it('hides drag overlay when drag leaves', () => {
    render(<RulesManager {...defaultProps} />);

    const container = screen.getByText('Gestión de Reglas').closest('div[class*="space-y-6"]');
    if (!container) throw new Error('Container not found');

    const file = createMockFile('domains.txt', 'google.com');
    const dataTransfer = createMockDataTransfer([file]);

    fireEvent.dragEnter(container, { dataTransfer });
    expect(screen.getByTestId('page-drag-overlay')).toBeInTheDocument();

    fireEvent.dragLeave(container, { dataTransfer });
    expect(screen.queryByTestId('page-drag-overlay')).not.toBeInTheDocument();
  });

  it('opens import modal with file content when valid file is dropped', async () => {
    render(<RulesManager {...defaultProps} />);

    const container = screen.getByText('Gestión de Reglas').closest('div[class*="space-y-6"]');
    if (!container) throw new Error('Container not found');

    const file = createMockFile('domains.txt', 'google.com\nyoutube.com');
    const dataTransfer = createMockDataTransfer([file]);

    fireEvent.drop(container, { dataTransfer });

    await waitFor(() => {
      expect(screen.getByText('Importar reglas')).toBeInTheDocument();
    });
  });

  it('shows error toast when invalid file is dropped', async () => {
    render(<RulesManager {...defaultProps} />);

    const container = screen.getByText('Gestión de Reglas').closest('div[class*="space-y-6"]');
    if (!container) throw new Error('Container not found');

    const file = createMockFile('image.png', '', 'image/png');
    const dataTransfer = createMockDataTransfer([file]);

    fireEvent.drop(container, { dataTransfer });

    await waitFor(() => {
      expect(mockToastError).toHaveBeenCalledWith('Solo se permiten archivos .txt, .csv o .list');
    });
  });

  it('shows skipped files in toast when mixed files are dropped', async () => {
    render(<RulesManager {...defaultProps} />);

    const container = screen.getByText('Gestión de Reglas').closest('div[class*="space-y-6"]');
    if (!container) throw new Error('Container not found');

    const validFile = createMockFile('domains.txt', 'google.com');
    const invalidFile = createMockFile('photo.jpg', '', 'image/jpeg');
    const dataTransfer = createMockDataTransfer([validFile, invalidFile]);

    fireEvent.drop(container, { dataTransfer });

    await waitFor(() => {
      expect(mockToastError).toHaveBeenCalledWith('Archivos ignorados: photo.jpg');
    });
  });

  it('renders import button that opens modal', () => {
    render(<RulesManager {...defaultProps} />);

    const importButton = screen.getByRole('button', { name: /importar/i });
    expect(importButton).toBeInTheDocument();

    fireEvent.click(importButton);
    expect(screen.getByText('Importar reglas')).toBeInTheDocument();
  });
});
