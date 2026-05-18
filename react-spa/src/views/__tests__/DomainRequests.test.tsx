import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { screen, fireEvent, waitFor, within } from '@testing-library/react';
import { focusManager } from '@tanstack/react-query';
import DomainRequests from '../DomainRequests';
import { renderWithQueryClient } from '../../test-utils/query';

focusManager.setEventListener((handleFocus) => {
  const onVisibilityChange = () => {
    handleFocus(document.visibilityState === 'visible');
  };
  const onFocus = () => {
    handleFocus(true);
  };

  window.addEventListener('visibilitychange', onVisibilityChange, false);
  window.addEventListener('focus', onFocus, false);
  return () => {
    window.removeEventListener('visibilitychange', onVisibilityChange);
    window.removeEventListener('focus', onFocus);
  };
});

let queryClient: ReturnType<typeof renderWithQueryClient>['queryClient'] | null = null;

function renderDomainRequests() {
  const rendered = renderWithQueryClient(<DomainRequests />);
  queryClient = rendered.queryClient;
  return rendered;
}

afterEach(() => {
  queryClient?.clear();
  queryClient = null;
});

const { mockListRequests, mockListGroups, mockApprove, mockReject } = vi.hoisted(() => ({
  mockListRequests: vi.fn(),
  mockListGroups: vi.fn(),
  mockApprove: vi.fn(),
  mockReject: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    requests: {
      list: {
        query: mockListRequests,
      },
      listGroups: {
        query: mockListGroups,
      },
      approve: {
        mutate: mockApprove,
      },
      reject: {
        mutate: mockReject,
      },
      delete: {
        mutate: vi.fn(),
      },
    },
  },
}));

describe('DomainRequests - Original group approval', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockListRequests.mockResolvedValue([
      {
        id: 'req-1',
        domain: 'example.com',
        reason: 'Need for class',
        requesterEmail: 'teacher@example.com',
        groupId: 'group-1',

        status: 'pending',
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        resolvedAt: null,
        resolvedBy: null,
      },
    ]);
    mockListGroups.mockResolvedValue([{ id: 'group-1', path: 'group-1', name: 'Grupo 1' }]);
    mockApprove.mockResolvedValue({ success: true });
    mockReject.mockResolvedValue({ success: true });
  });

  it('approves using request id only and shows original group', async () => {
    renderDomainRequests();

    await screen.findByText('example.com');
    fireEvent.click(screen.getByTitle('Approve'));

    expect(await screen.findByText(/original group/i)).toBeInTheDocument();
    expect(screen.queryByText('Target group')).not.toBeInTheDocument();

    const approveButtons = screen.getAllByRole('button', { name: 'Approve' });
    const modalApproveButton = approveButtons.at(-1);
    if (!modalApproveButton) {
      throw new Error('Modal approve button not found');
    }
    fireEvent.click(modalApproveButton);

    await waitFor(() => {
      expect(mockApprove).toHaveBeenCalledWith({ id: 'req-1' });
    });
  });

  it('refreshes list when the window regains focus', async () => {
    renderDomainRequests();

    await waitFor(() => {
      expect(mockListRequests).toHaveBeenCalledTimes(1);
    });

    fireEvent(window, new Event('focus'));

    await waitFor(() => {
      expect(mockListRequests).toHaveBeenCalledTimes(2);
    });
  });

  it('clears bulk reject reason when clearing selection', async () => {
    renderDomainRequests();

    await screen.findByText('example.com');
    fireEvent.click(screen.getByLabelText('Select example.com'));

    const reasonInput = screen.getByPlaceholderText('Bulk rejection reason (optional)');
    fireEvent.change(reasonInput, { target: { value: 'No aplica' } });
    expect(screen.getByDisplayValue('No aplica')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Clear selection' }));

    expect(screen.queryByDisplayValue('No aplica')).not.toBeInTheDocument();
  });

  it('asks confirmation before bulk approve', async () => {
    renderDomainRequests();

    await screen.findByText('example.com');
    fireEvent.click(screen.getByLabelText('Select example.com'));
    fireEvent.click(screen.getByRole('button', { name: 'Approve selected' }));

    expect(mockApprove).not.toHaveBeenCalled();

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByRole('heading', { name: 'Approve requests' })).toBeInTheDocument();

    fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }));

    expect(screen.queryByRole('heading', { name: 'Approve requests' })).not.toBeInTheDocument();
    expect(mockApprove).not.toHaveBeenCalled();
  });

  it('asks confirmation before bulk reject', async () => {
    renderDomainRequests();

    await screen.findByText('example.com');
    fireEvent.click(screen.getByLabelText('Select example.com'));
    fireEvent.click(screen.getByRole('button', { name: 'Reject selected' }));

    expect(mockReject).not.toHaveBeenCalled();

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByRole('heading', { name: 'Reject requests' })).toBeInTheDocument();

    fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }));

    expect(screen.queryByRole('heading', { name: 'Reject requests' })).not.toBeInTheDocument();
    expect(mockReject).not.toHaveBeenCalled();
  });

  it('clears search and restores the table when using clear button', async () => {
    renderDomainRequests();

    await screen.findByText('example.com');

    const searchInput = screen.getByPlaceholderText('Search by domain or machine...');
    fireEvent.change(searchInput, { target: { value: 'zzzz-not-found' } });

    expect(screen.getByText('No requests match the selected filters')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Limpiar busqueda' }));

    expect(searchInput).toHaveValue('');
    expect(screen.getByText('example.com')).toBeInTheDocument();
  });

  it('matches search even with extra spaces and uppercase text', async () => {
    renderDomainRequests();

    await screen.findByText('example.com');

    const searchInput = screen.getByPlaceholderText('Search by domain or machine...');
    fireEvent.change(searchInput, { target: { value: '   EXAMPLE.COM   ' } });

    expect(screen.getByText('example.com')).toBeInTheDocument();
    expect(screen.queryByText('No requests match the selected filters')).not.toBeInTheDocument();
  });

  it('keeps filters visible and allows clearing when source filter has no matches', async () => {
    renderDomainRequests();

    await screen.findByText('example.com');

    const sourceFilter = screen.getByRole('combobox', { name: 'Filtrar por fuente' });
    fireEvent.change(sourceFilter, { target: { value: 'firefox-extension' } });

    expect(screen.queryByText('All clear')).not.toBeInTheDocument();
    expect(screen.getByText('No requests match the selected filters')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Clear filters' })).toBeInTheDocument();
    expect(sourceFilter).toHaveValue('firefox-extension');

    fireEvent.click(screen.getByRole('button', { name: 'Clear filters' }));

    expect(sourceFilter).toHaveValue('all');
    expect(screen.getByText('example.com')).toBeInTheDocument();
  });

  it('disables bulk selection header in approved filter with contextual title', async () => {
    const pendingRequest = {
      id: 'req-pending',
      domain: 'pending.example.com',
      reason: 'Need for class',
      requesterEmail: 'teacher@example.com',
      groupId: 'group-1',

      status: 'pending',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      resolvedAt: null,
      resolvedBy: null,
    };
    const approvedRequest = {
      id: 'req-approved',
      domain: 'approved.example.com',
      reason: 'Already approved',
      requesterEmail: 'teacher@example.com',
      groupId: 'group-1',

      status: 'approved',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      resolvedAt: new Date().toISOString(),
      resolvedBy: 'admin@example.com',
    };

    mockListRequests.mockImplementation((input?: { status?: string }) => {
      if (input?.status === 'approved') {
        return Promise.resolve([approvedRequest]);
      }
      return Promise.resolve([pendingRequest, approvedRequest]);
    });

    renderDomainRequests();

    await screen.findByText('pending.example.com');

    const statusFilter = screen.getByRole('combobox', { name: 'Filtrar por estado' });
    fireEvent.change(statusFilter, { target: { value: 'approved' } });

    await screen.findByText('approved.example.com');

    const bulkSelectHeader = screen.getByRole('checkbox', { name: 'Bulk select page' });
    expect(bulkSelectHeader).toBeDisabled();
    expect(bulkSelectHeader).toHaveAttribute(
      'title',
      'Bulk selection is not available for this filter'
    );
    expect(screen.queryByLabelText('Select approved.example.com')).not.toBeInTheDocument();
  });
});
