import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { RulesManagerTableSection } from '../RulesManagerTableSection';

vi.mock('../../RulesTable', () => ({
  RulesTable: () => <div data-testid="rules-table">flat-table</div>,
}));

vi.mock('../../HierarchicalRulesTable', () => ({
  HierarchicalRulesTable: () => <div data-testid="hierarchical-table">hierarchical-table</div>,
}));

vi.mock('../../ui/Tabs', () => ({
  Tabs: ({ onChange }: { onChange: (id: string) => void }) => (
    <button onClick={() => onChange('blocked')} type="button">
      change-tab
    </button>
  ),
}));

describe('RulesManagerTableSection', () => {
  it('renders the flat table and forwards tab changes', () => {
    const onFilterChange = vi.fn();

    render(
      <RulesManagerTableSection
        tabs={[
          { id: 'all', label: 'Todos', count: 1 },
          { id: 'blocked', label: 'Bloqueadas', count: 0 },
        ]}
        filter="all"
        error={null}
        viewMode="flat"
        rules={[]}
        domainGroups={[]}
        loading={false}
        readOnly={false}
        selectedIds={new Set()}
        isAllSelected={false}
        hasSelection={false}
        emptyMessage="No rules"
        onFilterChange={onFilterChange}
        onRetry={vi.fn()}
        onDelete={vi.fn()}
        onSave={vi.fn(() => Promise.resolve(true))}
        onToggleSelection={vi.fn()}
        onToggleSelectAll={vi.fn()}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: 'change-tab' }));

    expect(screen.getByTestId('rules-table')).toBeInTheDocument();
    expect(onFilterChange).toHaveBeenCalledWith('blocked');
  });
});
