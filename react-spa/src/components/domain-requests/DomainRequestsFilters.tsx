import type { RefObject } from 'react';
import type { RequestStatus } from '@openpath/api';
import { Filter, Search } from 'lucide-react';
import type { SortOption, SourceFilter } from '../../hooks/useDomainRequestsState';

interface DomainRequestsFiltersProps {
  searchInputRef: RefObject<HTMLInputElement | null>;
  searchTerm: string;
  statusFilter: RequestStatus | 'all';
  sortBy: SortOption;
  sourceFilter: SourceFilter;
  pageSize: number;
  onSearchChange: (value: string) => void;
  onStatusFilterChange: (value: RequestStatus | 'all') => void;
  onSortChange: (value: SortOption) => void;
  onSourceFilterChange: (value: SourceFilter) => void;
  onPageSizeChange: (value: number) => void;
  onClearSearch: () => void;
}

export function DomainRequestsFilters({
  searchInputRef,
  searchTerm,
  statusFilter,
  sortBy,
  sourceFilter,
  pageSize,
  onSearchChange,
  onStatusFilterChange,
  onSortChange,
  onSourceFilterChange,
  onPageSizeChange,
  onClearSearch,
}: DomainRequestsFiltersProps) {
  return (
    <div className="bg-white border border-slate-200 rounded-lg p-4 shadow-sm">
      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1">
          <Search size={18} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
          <input
            ref={searchInputRef}
            type="text"
            name="domain-requests-search"
            autoComplete="off"
            placeholder="Search by domain or machine..."
            value={searchTerm}
            onChange={(event) => onSearchChange(event.target.value)}
            onFocus={(event) => {
              if (event.currentTarget.value !== searchTerm) {
                onSearchChange(event.currentTarget.value);
              }
            }}
            className="w-full pl-10 pr-24 py-2 border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          />
          <button
            type="button"
            onClick={onClearSearch}
            aria-label="Limpiar busqueda"
            className="absolute right-2 top-1/2 -translate-y-1/2 text-xs px-2 py-1 rounded border border-slate-200 text-slate-600 hover:bg-slate-50"
          >
            Limpiar
          </button>
        </div>

        <div className="flex items-center gap-2">
          <Filter size={18} className="text-slate-400" />
          <select
            value={statusFilter}
            onChange={(event) => onStatusFilterChange(event.target.value as RequestStatus | 'all')}
            aria-label="Filtrar por estado"
            className="px-3 py-2 border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          >
            <option value="all">Todos</option>
            <option value="pending">Pendientes</option>
            <option value="approved">Aprobados</option>
            <option value="rejected">Rechazados</option>
          </select>
          <select
            value={sortBy}
            onChange={(event) => onSortChange(event.target.value as SortOption)}
            aria-label="Sort requests"
            className="px-3 py-2 border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          >
            <option value="pending">Pendientes primero</option>
            <option value="newest">Mas nuevas</option>
            <option value="oldest">Mas antiguas</option>
          </select>
          <select
            value={sourceFilter}
            onChange={(event) => onSourceFilterChange(event.target.value as SourceFilter)}
            aria-label="Filtrar por fuente"
            className="px-3 py-2 border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          >
            <option value="all">Todas las fuentes</option>
            <option value="firefox-extension">Firefox Extension</option>
            <option value="manual">Manual/API</option>
          </select>
          <select
            value={String(pageSize)}
            onChange={(event) => onPageSizeChange(Number(event.target.value))}
            aria-label="Elementos por pagina"
            className="px-3 py-2 border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          >
            <option value="10">10/pag</option>
            <option value="20">20/pag</option>
            <option value="50">50/pag</option>
          </select>
        </div>
      </div>
    </div>
  );
}
