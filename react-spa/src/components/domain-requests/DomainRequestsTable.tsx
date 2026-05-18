import { CheckCircle, CheckCircle2, Clock, Search, Trash2, XCircle } from 'lucide-react';
import type { DomainRequestsTableModel } from '../../hooks/useDomainRequestsViewModel';

interface DomainRequestsTableProps {
  model: DomainRequestsTableModel;
}

export function DomainRequestsTable({ model }: DomainRequestsTableProps) {
  if (model.emptyState === 'no-requests') {
    return (
      <div className="flex flex-col items-center justify-center h-[50vh] bg-white rounded-lg border border-slate-200 shadow-sm text-slate-500">
        <div className="bg-green-50 p-4 rounded-full mb-4">
          <CheckCircle2 size={48} className="text-green-500" />
        </div>
        <h2 className="text-xl font-semibold text-slate-800">All clear</h2>
        <p className="mt-2 text-slate-500 text-sm">No domain requests are pending review.</p>
      </div>
    );
  }

  if (model.emptyState === 'no-filter-results') {
    return (
      <div className="bg-white border border-slate-200 rounded-lg p-8 shadow-sm text-center">
        <Search size={32} className="mx-auto text-slate-300 mb-3" />
        <p className="text-slate-500">No requests match the selected filters</p>
        <button
          type="button"
          onClick={model.onClearFilters}
          className="mt-4 px-3 py-2 text-sm bg-white border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50"
        >
          Clear filters
        </button>
      </div>
    );
  }

  return (
    <>
      <div className="bg-white border border-slate-200 rounded-lg shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead className="bg-slate-50 border-b border-slate-200">
              <tr>
                <th className="text-left px-4 py-3">
                  <input
                    type="checkbox"
                    checked={model.bulkSelection.allPagePendingSelected}
                    onChange={model.bulkSelection.onToggleSelectPage}
                    disabled={!model.bulkSelection.canSelectPage}
                    className="rounded border-slate-300"
                    title={model.bulkSelection.title}
                    aria-label="Bulk select page"
                  />
                </th>
                <th className="text-left px-4 py-3 text-xs font-semibold text-slate-600 uppercase tracking-wider">
                  Domain
                </th>
                <th className="text-left px-4 py-3 text-xs font-semibold text-slate-600 uppercase tracking-wider">
                  Machine
                </th>
                <th className="text-left px-4 py-3 text-xs font-semibold text-slate-600 uppercase tracking-wider">
                  Group
                </th>
                <th className="text-left px-4 py-3 text-xs font-semibold text-slate-600 uppercase tracking-wider">
                  Status
                </th>
                <th className="text-left px-4 py-3 text-xs font-semibold text-slate-600 uppercase tracking-wider">
                  Date
                </th>
                <th className="text-right px-4 py-3 text-xs font-semibold text-slate-600 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200">
              {model.rows.map((request) => (
                <tr
                  key={request.id}
                  data-testid="request-row"
                  data-status={request.status}
                  className="hover:bg-slate-50 transition-colors"
                >
                  <td className="px-4 py-3">
                    {request.selectable ? (
                      <input
                        type="checkbox"
                        checked={request.selected}
                        onChange={() => model.bulkSelection.onToggleRequest(request.id)}
                        className="rounded border-slate-300"
                        aria-label={`Select ${request.domain}`}
                      />
                    ) : null}
                  </td>
                  <td className="px-4 py-3">
                    <div>
                      <div data-testid="domain-name" className="font-medium text-slate-800">
                        {request.domain}
                      </div>
                      {request.reason && (
                        <div className="text-xs text-slate-500 mt-0.5 truncate max-w-xs">
                          {request.reason}
                        </div>
                      )}
                      <div className="text-xs text-slate-400 mt-0.5 truncate max-w-xs">
                        {request.sourceSummary}
                      </div>
                    </div>
                  </td>
                  <td className="px-4 py-3 text-sm text-slate-600">{request.machineHostname}</td>
                  <td className="px-4 py-3 text-sm text-slate-600">{request.groupName}</td>
                  <td className="px-4 py-3">
                    <span
                      className={`text-xs px-2 py-0.5 rounded-full border font-medium ${request.statusClassName}`}
                    >
                      {request.statusLabel}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-sm text-slate-500">
                    <div className="flex items-center gap-1">
                      <Clock size={14} />
                      {request.formattedCreatedAt}
                    </div>
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex items-center justify-end gap-2">
                      {request.reviewable && (
                        <>
                          <button
                            onClick={() => model.onOpenApprove(request.id)}
                            className="p-1.5 text-green-600 hover:bg-green-50 rounded-lg transition-colors"
                            title="Approve"
                          >
                            <CheckCircle size={18} />
                          </button>
                          <button
                            onClick={() => model.onOpenReject(request.id)}
                            className="p-1.5 text-red-600 hover:bg-red-50 rounded-lg transition-colors"
                            title="Reject"
                          >
                            <XCircle size={18} />
                          </button>
                        </>
                      )}
                      {model.canDeleteRequests ? (
                        <button
                          onClick={() => model.onOpenDelete(request.id)}
                          className="p-1.5 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition-colors"
                          title="Delete"
                        >
                          <Trash2 size={18} />
                        </button>
                      ) : null}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {model.pagination.totalItems > 0 && (
        <div className="flex items-center justify-between text-sm text-slate-600">
          <span>
            Showing {model.pagination.visibleStart}-{model.pagination.visibleEnd} of{' '}
            {model.pagination.totalItems}
          </span>
          <div className="flex items-center gap-2">
            <button
              onClick={() => model.pagination.onChangePage((page) => Math.max(1, page - 1))}
              disabled={model.pagination.currentPage <= 1}
              className="px-3 py-1 border border-slate-300 rounded disabled:opacity-50"
            >
              Previous
            </button>
            <span>
              Page {model.pagination.currentPage} of {model.pagination.totalPages}
            </span>
            <button
              onClick={() =>
                model.pagination.onChangePage((page) =>
                  Math.min(model.pagination.totalPages, page + 1)
                )
              }
              disabled={model.pagination.currentPage >= model.pagination.totalPages}
              className="px-3 py-1 border border-slate-300 rounded disabled:opacity-50"
            >
              Next
            </button>
          </div>
        </div>
      )}
    </>
  );
}
