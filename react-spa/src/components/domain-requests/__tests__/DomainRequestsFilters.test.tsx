import { createRef } from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { DomainRequestsFilters } from '../DomainRequestsFilters';

describe('DomainRequestsFilters', () => {
  it('forwards search and filter changes', () => {
    const onSearchChange = vi.fn();
    const onStatusFilterChange = vi.fn();
    const onSortChange = vi.fn();
    const onSourceFilterChange = vi.fn();
    const onPageSizeChange = vi.fn();
    const onClearSearch = vi.fn();

    render(
      <DomainRequestsFilters
        searchInputRef={createRef<HTMLInputElement>()}
        searchTerm=""
        statusFilter="all"
        sortBy="pending"
        sourceFilter="all"
        pageSize={20}
        onSearchChange={onSearchChange}
        onStatusFilterChange={onStatusFilterChange}
        onSortChange={onSortChange}
        onSourceFilterChange={onSourceFilterChange}
        onPageSizeChange={onPageSizeChange}
        onClearSearch={onClearSearch}
      />
    );

    fireEvent.change(screen.getByPlaceholderText('Search by domain or machine...'), {
      target: { value: 'example.com' },
    });
    fireEvent.change(screen.getByRole('combobox', { name: 'Filtrar por estado' }), {
      target: { value: 'approved' },
    });
    fireEvent.change(screen.getByRole('combobox', { name: 'Sort requests' }), {
      target: { value: 'oldest' },
    });
    fireEvent.change(screen.getByRole('combobox', { name: 'Filtrar por fuente' }), {
      target: { value: 'manual' },
    });
    fireEvent.change(screen.getByRole('combobox', { name: 'Elementos por pagina' }), {
      target: { value: '50' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Limpiar busqueda' }));

    expect(onSearchChange).toHaveBeenCalledWith('example.com');
    expect(onStatusFilterChange).toHaveBeenCalledWith('approved');
    expect(onSortChange).toHaveBeenCalledWith('oldest');
    expect(onSourceFilterChange).toHaveBeenCalledWith('manual');
    expect(onPageSizeChange).toHaveBeenCalledWith(50);
    expect(onClearSearch).toHaveBeenCalled();
  });
});
