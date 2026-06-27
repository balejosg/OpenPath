import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import { HierarchicalRuleRow } from '../HierarchicalRuleRow';

const baseRule = {
  id: 'r2',
  groupId: 'g',
  type: 'whitelist' as const,
  value: 'b.example.com',
  source: 'manual' as const,
  comment: null,
  createdAt: '2026-01-01T00:00:00Z',
};
const noop = () => {};
const baseProps = {
  isEditing: false,
  isSaving: false,
  isSelected: false,
  hasSelectionFeature: false,
  canEdit: true,
  readOnly: false,
  editValue: '',
  onStartEdit: noop,
  onSaveEdit: async () => {},
  onCancelEdit: noop,
  onDelete: noop,
  onSetEditValue: noop,
  onHandleEditKeyDown: noop,
};

describe('HierarchicalRuleRow enabled toggle', () => {
  it('calls onToggleEnabled with the rule when toggle button is clicked', () => {
    const onToggleEnabled = vi.fn();
    render(
      <table>
        <tbody>
          <HierarchicalRuleRow
            {...baseProps}
            rule={{ ...baseRule, enabled: true }}
            onToggleEnabled={onToggleEnabled}
          />
        </tbody>
      </table>
    );
    fireEvent.click(screen.getByTestId('toggle-enabled-button'));
    expect(onToggleEnabled).toHaveBeenCalledWith(expect.objectContaining({ id: 'r2' }));
  });

  it('dims the row when enabled=false', () => {
    const { container } = render(
      <table>
        <tbody>
          <HierarchicalRuleRow
            {...baseProps}
            rule={{ ...baseRule, enabled: false }}
            onToggleEnabled={noop}
          />
        </tbody>
      </table>
    );
    expect(container.querySelector('tr')?.className).toMatch(/opacity-60/);
  });
});
