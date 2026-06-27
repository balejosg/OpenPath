import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import { RulesTableRow } from '../../components/rules-table/RulesTableRow';

const baseRule = {
  id: 'r1',
  groupId: 'g',
  type: 'whitelist' as const,
  value: 'a.example.com',
  source: 'manual' as const,
  comment: null,
  createdAt: '2026-01-01T00:00:00Z',
};
const noop = () => {};
const props = {
  isEditing: false,
  isSaving: false,
  isSelected: false,
  hasSelectionFeature: false,
  readOnly: false,
  editValue: '',
  editComment: '',
  onStartEdit: noop,
  onSaveEdit: async () => {},
  onCancelEdit: noop,
  onDelete: noop,
  onSetEditValue: noop,
  onSetEditComment: noop,
  onHandleEditKeyDown: noop,
  canEdit: true,
  hasOnSave: true,
  formatDate: () => '-',
};

describe('RulesTableRow enabled toggle', () => {
  it('calls onToggleEnabled with the rule when toggle button is clicked', () => {
    const onToggleEnabled = vi.fn();
    render(
      <table>
        <tbody>
          <RulesTableRow
            {...props}
            rule={{ ...baseRule, enabled: true }}
            onToggleEnabled={onToggleEnabled}
          />
        </tbody>
      </table>
    );
    fireEvent.click(screen.getByTestId('toggle-enabled-button'));
    expect(onToggleEnabled).toHaveBeenCalledWith(expect.objectContaining({ id: 'r1' }));
  });

  it('dims the row when enabled=false', () => {
    const { container } = render(
      <table>
        <tbody>
          <RulesTableRow {...props} rule={{ ...baseRule, enabled: false }} onToggleEnabled={noop} />
        </tbody>
      </table>
    );
    expect(container.querySelector('tr')?.className).toMatch(/opacity-/);
  });
});
