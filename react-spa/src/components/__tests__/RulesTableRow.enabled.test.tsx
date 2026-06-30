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
const noop = () => undefined;
const props = {
  isEditing: false,
  isSaving: false,
  isSelected: false,
  hasSelectionFeature: false,
  readOnly: false,
  editValue: '',
  editComment: '',
  onStartEdit: noop,
  onSaveEdit: () => Promise.resolve(),
  onCancelEdit: noop,
  onDelete: noop,
  onSetEditValue: noop,
  onSetEditComment: noop,
  onHandleEditKeyDown: noop,
  canEdit: true,
  hasOnSave: true,
  formatDate: () => '-',
};

describe('RulesTableRow type badge color', () => {
  function getBadgeSpan(container: HTMLElement) {
    // The type badge is the first rounded-full span inside the row
    return container.querySelector('span.rounded-full');
  }

  it('renders whitelist with green badge classes', () => {
    const { container } = render(
      <table>
        <tbody>
          <RulesTableRow {...props} rule={{ ...baseRule, type: 'whitelist' }} />
        </tbody>
      </table>
    );
    const badge = getBadgeSpan(container);
    expect(badge?.className).toMatch(/bg-green-100/);
    expect(badge?.className).not.toMatch(/bg-red-100/);
  });

  it('renders allowed_path with green badge classes', () => {
    const { container } = render(
      <table>
        <tbody>
          <RulesTableRow {...props} rule={{ ...baseRule, type: 'allowed_path' as const }} />
        </tbody>
      </table>
    );
    const badge = getBadgeSpan(container);
    expect(badge?.className).toMatch(/bg-green-100/);
    expect(badge?.className).not.toMatch(/bg-red-100/);
  });

  it('renders blocked_path with red badge classes', () => {
    const { container } = render(
      <table>
        <tbody>
          <RulesTableRow {...props} rule={{ ...baseRule, type: 'blocked_path' as const }} />
        </tbody>
      </table>
    );
    const badge = getBadgeSpan(container);
    expect(badge?.className).toMatch(/bg-red-100/);
    expect(badge?.className).not.toMatch(/bg-green-100/);
  });

  it('renders blocked_subdomain with red badge classes', () => {
    const { container } = render(
      <table>
        <tbody>
          <RulesTableRow {...props} rule={{ ...baseRule, type: 'blocked_subdomain' as const }} />
        </tbody>
      </table>
    );
    const badge = getBadgeSpan(container);
    expect(badge?.className).toMatch(/bg-red-100/);
    expect(badge?.className).not.toMatch(/bg-green-100/);
  });
});

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
    expect(container.querySelector('tr')?.className).toMatch(/opacity-60/);
  });
});
