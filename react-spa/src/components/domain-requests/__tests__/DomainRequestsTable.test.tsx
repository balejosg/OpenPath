import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { DomainRequestsTableModel } from '../../../hooks/useDomainRequestsViewModel';
import { DomainRequestsTable } from '../DomainRequestsTable';

const pendingRow = {
  id: 'req-1',
  domain: 'example.com',
  status: 'pending',
  statusLabel: 'Pendiente',
  statusClassName: 'bg-amber-100 text-amber-700 border-amber-200',
  reason: 'Necesario para clase',
  machineHostname: 'host-1',
  groupName: 'Grupo 1',
  sourceSummary: 'Manual/API · Origen: teacher.local · Host: host-1',
  formattedCreatedAt: '01/04/2026',
  selected: false,
  selectable: true,
  reviewable: true,
} as const;

function buildModel(overrides: Partial<DomainRequestsTableModel> = {}): DomainRequestsTableModel {
  return {
    rows: [pendingRow],
    emptyState: null,
    canDeleteRequests: true,
    onClearFilters: vi.fn(),
    bulkSelection: {
      canSelectPage: true,
      title: 'Select',
      allPagePendingSelected: false,
      onToggleSelectPage: vi.fn(),
      onToggleRequest: vi.fn(),
    },
    pagination: {
      currentPage: 1,
      pageSize: 20,
      totalPages: 1,
      totalItems: 1,
      visibleStart: 1,
      visibleEnd: 1,
      onChangePage: vi.fn(),
    },
    onOpenApprove: vi.fn(),
    onOpenReject: vi.fn(),
    onOpenDelete: vi.fn(),
    ...overrides,
  };
}

describe('DomainRequestsTable', () => {
  it('renders the no-requests empty state', () => {
    render(
      <DomainRequestsTable
        model={buildModel({
          rows: [],
          emptyState: 'no-requests',
          pagination: {
            ...buildModel().pagination,
            totalItems: 0,
            visibleStart: 0,
            visibleEnd: 0,
          },
        })}
      />
    );

    expect(screen.getByText('All clear')).toBeInTheDocument();
    expect(screen.getByText('No domain requests are pending review.')).toBeInTheDocument();
  });

  it('renders the filtered empty state and clears filters', () => {
    const onClearFilters = vi.fn();

    render(
      <DomainRequestsTable
        model={buildModel({
          rows: [],
          emptyState: 'no-filter-results',
          onClearFilters,
          pagination: {
            ...buildModel().pagination,
            totalItems: 0,
            visibleStart: 0,
            visibleEnd: 0,
          },
        })}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: 'Clear filters' }));

    expect(screen.getByText('No requests match the selected filters')).toBeInTheDocument();
    expect(onClearFilters).toHaveBeenCalled();
  });

  it('renders pending rows and dispatches row-level actions', () => {
    const onOpenApprove = vi.fn();
    const onOpenReject = vi.fn();
    const onOpenDelete = vi.fn();
    const onToggleRequest = vi.fn();
    const onToggleSelectPage = vi.fn();

    render(
      <DomainRequestsTable
        model={buildModel({
          onOpenApprove,
          onOpenReject,
          onOpenDelete,
          bulkSelection: {
            canSelectPage: true,
            title: 'Select',
            allPagePendingSelected: false,
            onToggleSelectPage,
            onToggleRequest,
          },
        })}
      />
    );

    fireEvent.click(screen.getByLabelText('Bulk select page'));
    fireEvent.click(screen.getByLabelText('Select example.com'));
    fireEvent.click(screen.getByTitle('Approve'));
    fireEvent.click(screen.getByTitle('Reject'));
    fireEvent.click(screen.getByTitle('Delete'));

    expect(onToggleSelectPage).toHaveBeenCalled();
    expect(onToggleRequest).toHaveBeenCalledWith('req-1');
    expect(onOpenApprove).toHaveBeenCalledWith('req-1');
    expect(onOpenReject).toHaveBeenCalledWith('req-1');
    expect(onOpenDelete).toHaveBeenCalledWith('req-1');
  });

  it('can hide delete actions while keeping approve and reject available', () => {
    render(
      <DomainRequestsTable
        model={buildModel({
          canDeleteRequests: false,
        })}
      />
    );

    expect(screen.getByTitle('Approve')).toBeInTheDocument();
    expect(screen.getByTitle('Reject')).toBeInTheDocument();
    expect(screen.queryByTitle('Delete')).not.toBeInTheDocument();
  });

  it('renders reviewed rows without selection or review actions and hides empty pagination', () => {
    render(
      <DomainRequestsTable
        model={buildModel({
          rows: [
            {
              ...pendingRow,
              id: 'req-2',
              domain: 'approved.example',
              status: 'approved',
              statusLabel: 'Aprobada',
              statusClassName: 'bg-green-100 text-green-700 border-green-200',
              reason: null,
              selected: false,
              selectable: false,
              reviewable: false,
            },
          ],
          pagination: {
            ...buildModel().pagination,
            totalItems: 0,
            visibleStart: 0,
            visibleEnd: 0,
          },
        })}
      />
    );

    expect(screen.getByText('approved.example')).toBeInTheDocument();
    expect(screen.queryByLabelText('Select approved.example')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Approve')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Reject')).not.toBeInTheDocument();
    expect(screen.getByTitle('Delete')).toBeInTheDocument();
    expect(screen.queryByText(/Mostrando/)).not.toBeInTheDocument();
  });

  it('dispatches pagination updates and disables boundary controls', () => {
    const pageUpdates: Parameters<DomainRequestsTableModel['pagination']['onChangePage']>[0][] = [];
    const onChangePage: DomainRequestsTableModel['pagination']['onChangePage'] = (updater) => {
      pageUpdates.push(updater);
    };
    const { rerender } = render(
      <DomainRequestsTable
        model={buildModel({
          pagination: {
            ...buildModel().pagination,
            currentPage: 1,
            totalPages: 3,
            totalItems: 45,
            visibleStart: 1,
            visibleEnd: 20,
            onChangePage,
          },
        })}
      />
    );

    expect(screen.getByRole('button', { name: 'Previous' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    expect(pageUpdates).toHaveLength(1);
    const nextPageUpdater = pageUpdates[0];
    expect(typeof nextPageUpdater).toBe('function');
    expect(typeof nextPageUpdater === 'function' ? nextPageUpdater(1) : nextPageUpdater).toBe(2);

    rerender(
      <DomainRequestsTable
        model={buildModel({
          pagination: {
            ...buildModel().pagination,
            currentPage: 3,
            totalPages: 3,
            totalItems: 45,
            visibleStart: 41,
            visibleEnd: 45,
            onChangePage,
          },
        })}
      />
    );

    expect(screen.getByText('Showing 41-45 of 45')).toBeInTheDocument();
    expect(screen.getByText('Page 3 of 3')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Next' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Previous' }));
    expect(pageUpdates).toHaveLength(2);
    const previousPageUpdater = pageUpdates[1];
    expect(typeof previousPageUpdater).toBe('function');
    expect(
      typeof previousPageUpdater === 'function' ? previousPageUpdater(3) : previousPageUpdater
    ).toBe(2);
  });
});
