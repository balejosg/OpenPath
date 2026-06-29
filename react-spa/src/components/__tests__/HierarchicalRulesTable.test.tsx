import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { getRootDomain } from '@openpath/shared/domain';
import { HierarchicalRulesTable } from '../HierarchicalRulesTable';
import type { DomainGroup } from '../HierarchicalRulesTable';
import type { Rule } from '../RulesTable';

// =============================================================================
// getRootDomain Tests
// =============================================================================

describe('getRootDomain', () => {
  describe('Standard TLDs', () => {
    it('extracts root from simple domain', () => {
      expect(getRootDomain('google.com')).toBe('google.com');
    });

    it('extracts root from subdomain', () => {
      expect(getRootDomain('mail.google.com')).toBe('google.com');
    });

    it('extracts root from deep subdomain', () => {
      expect(getRootDomain('a.b.c.google.com')).toBe('google.com');
    });

    it('extracts root from URL with protocol', () => {
      expect(getRootDomain('https://mail.google.com')).toBe('google.com');
    });

    it('extracts root from URL with www', () => {
      expect(getRootDomain('www.google.com')).toBe('google.com');
    });

    it('extracts root from URL with path', () => {
      expect(getRootDomain('google.com/search?q=test')).toBe('google.com');
    });

    it('extracts root from URL with port', () => {
      expect(getRootDomain('google.com:8080')).toBe('google.com');
    });

    it('handles wildcard prefix', () => {
      expect(getRootDomain('*.google.com')).toBe('google.com');
    });
  });

  describe('Country-code SLDs (ccSLDs)', () => {
    it('handles .co.uk domains', () => {
      expect(getRootDomain('bbc.co.uk')).toBe('bbc.co.uk');
      expect(getRootDomain('www.bbc.co.uk')).toBe('bbc.co.uk');
      expect(getRootDomain('news.bbc.co.uk')).toBe('bbc.co.uk');
    });

    it('handles .com.ar domains', () => {
      expect(getRootDomain('mercadolibre.com.ar')).toBe('mercadolibre.com.ar');
      expect(getRootDomain('www.mercadolibre.com.ar')).toBe('mercadolibre.com.ar');
    });

    it('handles .com.au domains', () => {
      expect(getRootDomain('abc.com.au')).toBe('abc.com.au');
      expect(getRootDomain('news.abc.com.au')).toBe('abc.com.au');
    });

    it('handles .co.jp domains', () => {
      expect(getRootDomain('amazon.co.jp')).toBe('amazon.co.jp');
      expect(getRootDomain('www.amazon.co.jp')).toBe('amazon.co.jp');
    });

    it('handles .com.br domains', () => {
      expect(getRootDomain('globo.com.br')).toBe('globo.com.br');
      expect(getRootDomain('g1.globo.com.br')).toBe('globo.com.br');
    });

    it('handles .org.uk domains', () => {
      expect(getRootDomain('charity.org.uk')).toBe('charity.org.uk');
    });

    it('handles .edu.au domains', () => {
      expect(getRootDomain('university.edu.au')).toBe('university.edu.au');
    });
  });

  describe('Edge cases', () => {
    it('returns single-part domain as-is', () => {
      expect(getRootDomain('localhost')).toBe('localhost');
    });

    it('handles empty string', () => {
      expect(getRootDomain('')).toBe('');
    });

    it('handles URL with fragment', () => {
      expect(getRootDomain('google.com#section')).toBe('google.com');
    });

    it('handles complex URL', () => {
      expect(getRootDomain('https://www.mail.google.com:443/inbox?id=1#top')).toBe('google.com');
    });
  });
});

// =============================================================================
// HierarchicalRulesTable Component Tests
// =============================================================================

describe('HierarchicalRulesTable Component', () => {
  const mockRules: Rule[] = [
    {
      id: '1',
      groupId: 'group-1',
      type: 'whitelist',
      value: 'google.com',
      comment: 'Search engine',
      createdAt: '2024-01-15T10:00:00Z',
    },
    {
      id: '2',
      groupId: 'group-1',
      type: 'blocked_subdomain',
      value: 'ads.google.com',
      comment: null,
      createdAt: '2024-01-16T10:00:00Z',
    },
    {
      id: '3',
      groupId: 'group-1',
      type: 'whitelist',
      value: 'facebook.com',
      comment: 'Social',
      createdAt: '2024-01-17T10:00:00Z',
    },
  ];

  const noop = vi.fn();

  describe('Basic Rendering', () => {
    it('renders loading state', () => {
      render(<HierarchicalRulesTable rules={[]} loading={true} onDelete={noop} />);
      expect(screen.getByText(/loading/i)).toBeInTheDocument();
    });

    it('renders empty state when no rules', () => {
      render(<HierarchicalRulesTable rules={[]} loading={false} onDelete={noop} />);
      expect(screen.getByText(/no rules configured/i)).toBeInTheDocument();
    });

    it('renders custom empty message', () => {
      render(
        <HierarchicalRulesTable
          rules={[]}
          loading={false}
          onDelete={noop}
          emptyMessage="Custom empty message"
        />
      );
      expect(screen.getByText('Custom empty message')).toBeInTheDocument();
    });

    it('renders grouped rules', () => {
      render(<HierarchicalRulesTable rules={mockRules} loading={false} onDelete={noop} />);

      // Should show group headers
      expect(screen.getByText('google.com')).toBeInTheDocument();
      expect(screen.getByText('facebook.com')).toBeInTheDocument();

      // Should show rule counts
      expect(screen.getByText('(2)')).toBeInTheDocument(); // google.com has 2 rules
      expect(screen.getByText('(1)')).toBeInTheDocument(); // facebook.com has 1 rule
    });
  });

  describe('Group Status', () => {
    it('shows "Allowed" for groups with only whitelist rules', () => {
      const allowedRules: Rule[] = [
        {
          id: '1',
          groupId: 'group-1',
          type: 'whitelist',
          value: 'example.com',
          comment: null,
          createdAt: '2024-01-15T10:00:00Z',
        },
      ];

      render(<HierarchicalRulesTable rules={allowedRules} loading={false} onDelete={noop} />);
      expect(screen.getByText('Allowed')).toBeInTheDocument();
    });

    it('shows "Mixed" (not "Blocked") for groups whose only rules are blocked carve-outs', () => {
      // blocked_subdomain / blocked_path are carve-out exceptions within a domain,
      // never a block of the whole root. The parent root row must not appear fully
      // "Blocked" just because a child subdomain/path is blocked.
      const blockedRules: Rule[] = [
        {
          id: '1',
          groupId: 'group-1',
          type: 'blocked_subdomain',
          value: 'ads.example.com',
          comment: null,
          createdAt: '2024-01-15T10:00:00Z',
        },
        {
          id: '2',
          groupId: 'group-1',
          type: 'blocked_path',
          value: 'example.com/ads',
          comment: null,
          createdAt: '2024-01-15T10:00:00Z',
        },
      ];

      render(<HierarchicalRulesTable rules={blockedRules} loading={false} onDelete={noop} />);
      expect(screen.getByText('Mixed')).toBeInTheDocument();
      expect(screen.queryByText('Blocked')).not.toBeInTheDocument();
    });

    it('shows "Mixed" for groups with mixed rules', () => {
      render(<HierarchicalRulesTable rules={mockRules} loading={false} onDelete={noop} />);
      // google.com has whitelist + blocked_subdomain = mixed
      expect(screen.getByText('Mixed')).toBeInTheDocument();
    });
  });

  describe('Expand/Collapse', () => {
    it('expands group when clicking on header', () => {
      render(<HierarchicalRulesTable rules={mockRules} loading={false} onDelete={noop} />);

      // Initially, child rules should not be visible
      expect(screen.queryByText('ads.google.com')).not.toBeInTheDocument();

      // Click on google.com group header
      const groupHeader = screen.getByText('google.com');
      fireEvent.click(groupHeader);

      // Now child rules should be visible
      expect(screen.getByText('ads.google.com')).toBeInTheDocument();
    });

    it('collapses group when clicking expanded header', () => {
      render(<HierarchicalRulesTable rules={mockRules} loading={false} onDelete={noop} />);

      // Expand
      const groupHeader = screen.getByText('google.com');
      fireEvent.click(groupHeader);
      expect(screen.getByText('ads.google.com')).toBeInTheDocument();

      // Collapse
      fireEvent.click(groupHeader);
      expect(screen.queryByText('ads.google.com')).not.toBeInTheDocument();
    });

    it('shows chevron icons for expand/collapse state', () => {
      render(<HierarchicalRulesTable rules={mockRules} loading={false} onDelete={noop} />);

      // Initially collapsed - should show ChevronRight (not testing exact icon, just behavior)
      const groupHeader = screen.getByText('google.com');

      // Expand
      fireEvent.click(groupHeader);

      // Rules should be visible
      expect(screen.getByText('ads.google.com')).toBeInTheDocument();
    });
  });

  describe('Delete Action', () => {
    it('calls onDelete when delete button is clicked on child rule', () => {
      const handleDelete = vi.fn();
      render(<HierarchicalRulesTable rules={mockRules} loading={false} onDelete={handleDelete} />);

      // Expand google.com group
      fireEvent.click(screen.getByText('google.com'));

      // Click delete on first child rule
      const deleteButtons = screen.getAllByTitle('Delete');
      fireEvent.click(deleteButtons[0]);

      expect(handleDelete).toHaveBeenCalledWith(expect.objectContaining({ value: 'google.com' }));
    });
  });

  describe('Add Subdomain Action', () => {
    it('shows add button when onAddSubdomain is provided', () => {
      const handleAddSubdomain = vi.fn();
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          onAddSubdomain={handleAddSubdomain}
        />
      );

      const addButtons = screen.getAllByTitle(/add subdomain/i);
      expect(addButtons.length).toBeGreaterThan(0);
    });

    it('calls onAddSubdomain with root domain when clicking add button', () => {
      const handleAddSubdomain = vi.fn();
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          onAddSubdomain={handleAddSubdomain}
        />
      );

      const addButton = screen.getByTitle('Add subdomain to google.com');
      fireEvent.click(addButton);

      expect(handleAddSubdomain).toHaveBeenCalledWith('google.com');
    });

    it('does not show add button when onAddSubdomain is not provided', () => {
      render(<HierarchicalRulesTable rules={mockRules} loading={false} onDelete={noop} />);

      expect(screen.queryByTitle(/add subdomain/i)).not.toBeInTheDocument();
    });
  });

  describe('Selection', () => {
    it('renders checkboxes when selection props are provided', () => {
      const selectedIds = new Set<string>();
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          selectedIds={selectedIds}
          onToggleSelection={noop}
          onToggleSelectAll={noop}
          isAllSelected={false}
          hasSelection={false}
        />
      );

      // Should have select all button
      expect(screen.getByTitle('Select all')).toBeInTheDocument();
    });

    it('calls onToggleSelectAll when header checkbox is clicked', () => {
      const selectedIds = new Set<string>();
      const handleToggleSelectAll = vi.fn();
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          selectedIds={selectedIds}
          onToggleSelection={noop}
          onToggleSelectAll={handleToggleSelectAll}
          isAllSelected={false}
          hasSelection={false}
        />
      );

      fireEvent.click(screen.getByTitle('Select all'));
      expect(handleToggleSelectAll).toHaveBeenCalled();
    });

    it('toggles all rules in group when clicking group checkbox', () => {
      const selectedIds = new Set<string>();
      const handleToggleSelection = vi.fn();
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          selectedIds={selectedIds}
          onToggleSelection={handleToggleSelection}
          onToggleSelectAll={noop}
          isAllSelected={false}
          hasSelection={false}
        />
      );

      // Groups are sorted alphabetically: facebook.com, google.com
      // Click on google.com group checkbox (second one) which has 2 rules
      const groupCheckboxes = screen.getAllByTitle('Select group');
      fireEvent.click(groupCheckboxes[1]); // google.com is second (after facebook.com)

      // Should toggle all rules in google.com group (2 rules: google.com and ads.google.com)
      expect(handleToggleSelection).toHaveBeenCalledTimes(2);
    });

    it('calls onToggleSelection for individual rule when expanded', () => {
      const selectedIds = new Set<string>();
      const handleToggleSelection = vi.fn();
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          selectedIds={selectedIds}
          onToggleSelection={handleToggleSelection}
          onToggleSelectAll={noop}
          isAllSelected={false}
          hasSelection={false}
        />
      );

      // Expand google.com group
      fireEvent.click(screen.getByText('google.com'));

      // Clear mock from group toggle
      handleToggleSelection.mockClear();

      // Click on individual rule checkbox
      const selectButtons = screen.getAllByTitle('Select');
      fireEvent.click(selectButtons[0]);

      expect(handleToggleSelection).toHaveBeenCalledWith('1');
    });
  });

  describe('Inline Editing', () => {
    it('shows edit button when onSave is provided', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          onSave={handleSave}
        />
      );

      // Expand group first
      fireEvent.click(screen.getByText('google.com'));

      const editButtons = screen.getAllByTestId('edit-button');
      expect(editButtons.length).toBeGreaterThan(0);
    });

    it('enters edit mode when clicking edit button', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          onSave={handleSave}
        />
      );

      // Expand group
      fireEvent.click(screen.getByText('google.com'));

      // Click edit
      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      expect(screen.getByTestId('edit-value-input')).toBeInTheDocument();
      expect(screen.getByTestId('save-edit-button')).toBeInTheDocument();
      expect(screen.getByTestId('cancel-edit-button')).toBeInTheDocument();
    });

    it('cancels edit when clicking cancel button', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          onSave={handleSave}
        />
      );

      // Expand and edit
      fireEvent.click(screen.getByText('google.com'));
      fireEvent.click(screen.getAllByTestId('edit-button')[0]);

      expect(screen.getByTestId('edit-value-input')).toBeInTheDocument();

      // Cancel
      fireEvent.click(screen.getByTestId('cancel-edit-button'));

      expect(screen.queryByTestId('edit-value-input')).not.toBeInTheDocument();
    });

    it('cancels edit when pressing Escape', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          onSave={handleSave}
        />
      );

      // Expand and edit
      fireEvent.click(screen.getByText('google.com'));
      fireEvent.click(screen.getAllByTestId('edit-button')[0]);

      expect(screen.getByTestId('edit-value-input')).toBeInTheDocument();

      await user.keyboard('{Escape}');

      expect(screen.queryByTestId('edit-value-input')).not.toBeInTheDocument();
    });

    it('calls onSave with updated value when saving', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          onSave={handleSave}
        />
      );

      // Expand and edit
      fireEvent.click(screen.getByText('google.com'));
      fireEvent.click(screen.getAllByTestId('edit-button')[0]);

      const valueInput = screen.getByTestId('edit-value-input');
      await user.clear(valueInput);
      await user.type(valueInput, 'newdomain.com');

      fireEvent.click(screen.getByTestId('save-edit-button'));

      await waitFor(() => {
        expect(handleSave).toHaveBeenCalledWith('1', {
          value: 'newdomain.com',
          comment: undefined,
        });
      });
    });

    it('saves when pressing Enter', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          onSave={handleSave}
        />
      );

      // Expand and edit
      fireEvent.click(screen.getByText('google.com'));
      fireEvent.click(screen.getAllByTestId('edit-button')[0]);

      const valueInput = screen.getByTestId('edit-value-input');
      await user.clear(valueInput);
      await user.type(valueInput, 'newdomain.com');
      await user.keyboard('{Enter}');

      await waitFor(() => {
        expect(handleSave).toHaveBeenCalled();
      });
    });

    it('disables save button when value is empty', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <HierarchicalRulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          onSave={handleSave}
        />
      );

      // Expand and edit
      fireEvent.click(screen.getByText('google.com'));
      fireEvent.click(screen.getAllByTestId('edit-button')[0]);

      const valueInput = screen.getByTestId('edit-value-input');
      await user.clear(valueInput);

      const saveButton = screen.getByTestId('save-edit-button');
      expect(saveButton).toBeDisabled();
    });
  });

  describe('ccTLD Grouping', () => {
    it('groups rules by ccSLD correctly', () => {
      const ukRules: Rule[] = [
        {
          id: '1',
          groupId: 'group-1',
          type: 'whitelist',
          value: 'bbc.co.uk',
          comment: null,
          createdAt: '2024-01-15T10:00:00Z',
        },
        {
          id: '2',
          groupId: 'group-1',
          type: 'blocked_subdomain',
          value: 'news.bbc.co.uk',
          comment: null,
          createdAt: '2024-01-16T10:00:00Z',
        },
      ];

      render(<HierarchicalRulesTable rules={ukRules} loading={false} onDelete={noop} />);

      // Should show bbc.co.uk as the group (not just co.uk)
      expect(screen.getByText('bbc.co.uk')).toBeInTheDocument();
      expect(screen.getByText('(2)')).toBeInTheDocument();
    });

    it('separates different ccSLD roots correctly', () => {
      const mixedRules: Rule[] = [
        {
          id: '1',
          groupId: 'group-1',
          type: 'whitelist',
          value: 'bbc.co.uk',
          comment: null,
          createdAt: '2024-01-15T10:00:00Z',
        },
        {
          id: '2',
          groupId: 'group-1',
          type: 'whitelist',
          value: 'abc.com.au',
          comment: null,
          createdAt: '2024-01-16T10:00:00Z',
        },
      ];

      render(<HierarchicalRulesTable rules={mixedRules} loading={false} onDelete={noop} />);

      expect(screen.getByText('bbc.co.uk')).toBeInTheDocument();
      expect(screen.getByText('abc.com.au')).toBeInTheDocument();
    });
  });

  describe('Global paths (domainless rules)', () => {
    it('shows "Global paths" label for rules with empty root domain', () => {
      const domainGroups: DomainGroup[] = [
        {
          root: '',
          rules: [
            {
              id: '1',
              groupId: 'group-1',
              type: 'blocked_path',
              value: '*/ads/*',
              comment: null,
              createdAt: '2024-01-15T10:00:00Z',
            },
          ],
          status: 'blocked',
        },
        {
          root: 'google.com',
          rules: [
            {
              id: '2',
              groupId: 'group-1',
              type: 'whitelist',
              value: 'google.com',
              comment: null,
              createdAt: '2024-01-15T10:00:00Z',
            },
          ],
          status: 'allowed',
        },
      ];

      render(
        <HierarchicalRulesTable domainGroups={domainGroups} loading={false} onDelete={noop} />
      );

      expect(screen.getByText('Global paths')).toBeInTheDocument();
      expect(screen.getByText('google.com')).toBeInTheDocument();
    });

    it('groups domainless paths under empty root when using client-side grouping', () => {
      const pathRules: Rule[] = [
        {
          id: '1',
          groupId: 'group-1',
          type: 'blocked_path',
          value: '*/ads/*',
          comment: null,
          createdAt: '2024-01-15T10:00:00Z',
        },
        {
          id: '2',
          groupId: 'group-1',
          type: 'blocked_path',
          value: '*/tracking/*',
          comment: null,
          createdAt: '2024-01-16T10:00:00Z',
        },
      ];

      render(<HierarchicalRulesTable rules={pathRules} loading={false} onDelete={noop} />);

      expect(screen.getByText('Global paths')).toBeInTheDocument();
      expect(screen.getByText('(2)')).toBeInTheDocument();
    });

    it('does not show add subdomain button for global paths group', () => {
      const domainGroups: DomainGroup[] = [
        {
          root: '',
          rules: [
            {
              id: '1',
              groupId: 'group-1',
              type: 'blocked_path',
              value: '*/ads/*',
              comment: null,
              createdAt: '2024-01-15T10:00:00Z',
            },
          ],
          status: 'blocked',
        },
      ];

      const onAddSubdomain = vi.fn();

      render(
        <HierarchicalRulesTable
          domainGroups={domainGroups}
          loading={false}
          onDelete={noop}
          onAddSubdomain={onAddSubdomain}
        />
      );

      expect(screen.getByText('Global paths')).toBeInTheDocument();
      // The + button should not be present for domainless groups
      const rows = screen.getAllByRole('row');
      // Header row + 1 group row = 2 rows; the group row should NOT have a + button
      const groupRow = rows[1];
      expect(groupRow.querySelector('button[title*="Add"]')).toBeNull();
    });
  });
});
