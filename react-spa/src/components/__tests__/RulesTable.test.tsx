import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { RulesTable, Rule } from '../RulesTable';

describe('RulesTable Component', () => {
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
      value: 'ads.example.com',
      comment: null,
      createdAt: '2024-01-16T10:00:00Z',
    },
  ];

  const noop = vi.fn();

  it('renders loading state', () => {
    render(<RulesTable rules={[]} loading={true} onDelete={noop} />);
    expect(screen.getByText(/loading/i)).toBeInTheDocument();
  });

  it('renders empty state when no rules', () => {
    render(<RulesTable rules={[]} loading={false} onDelete={noop} />);
    expect(screen.getByText(/no rules configured/i)).toBeInTheDocument();
  });

  it('renders custom empty message', () => {
    render(
      <RulesTable rules={[]} loading={false} onDelete={noop} emptyMessage="Custom empty message" />
    );
    expect(screen.getByText('Custom empty message')).toBeInTheDocument();
  });

  it('renders rules in table', () => {
    render(<RulesTable rules={mockRules} loading={false} onDelete={noop} />);

    expect(screen.getByText('google.com')).toBeInTheDocument();
    expect(screen.getByText('ads.example.com')).toBeInTheDocument();
  });

  it('displays rule type badges', () => {
    render(<RulesTable rules={mockRules} loading={false} onDelete={noop} />);

    expect(screen.getByText('Allowed')).toBeInTheDocument();
    expect(screen.getByText('Sub. blocked')).toBeInTheDocument();
  });

  it('displays comments when present', () => {
    render(<RulesTable rules={mockRules} loading={false} onDelete={noop} />);

    expect(screen.getByText('Search engine')).toBeInTheDocument();
  });

  it('calls onDelete when delete button is clicked', () => {
    const handleDelete = vi.fn();
    render(<RulesTable rules={mockRules} loading={false} onDelete={handleDelete} />);

    const deleteButtons = screen.getAllByTitle('Delete');
    fireEvent.click(deleteButtons[0]);

    expect(handleDelete).toHaveBeenCalledWith(mockRules[0]);
  });

  it('shows edit button when onSave is provided', () => {
    const handleSave = vi.fn().mockResolvedValue(true);
    render(<RulesTable rules={mockRules} loading={false} onDelete={noop} onSave={handleSave} />);

    const editButtons = screen.getAllByTestId('edit-button');
    expect(editButtons).toHaveLength(2);
  });

  it('does not show edit button when onSave is not provided', () => {
    render(<RulesTable rules={mockRules} loading={false} onDelete={noop} />);

    expect(screen.queryByTestId('edit-button')).not.toBeInTheDocument();
  });

  describe('Selection functionality', () => {
    it('renders checkboxes when selection props are provided', () => {
      const selectedIds = new Set<string>();
      render(
        <RulesTable
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

      // Should have select all button + 2 row checkboxes
      const selectButtons = screen.getAllByTitle(/select/i);
      expect(selectButtons.length).toBeGreaterThanOrEqual(2);
    });

    it('calls onToggleSelection when row checkbox is clicked', () => {
      const selectedIds = new Set<string>();
      const handleToggleSelection = vi.fn();
      render(
        <RulesTable
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

      const selectButtons = screen.getAllByTitle('Select');
      fireEvent.click(selectButtons[0]);

      expect(handleToggleSelection).toHaveBeenCalledWith('1');
    });

    it('calls onToggleSelectAll when header checkbox is clicked', () => {
      const selectedIds = new Set<string>();
      const handleToggleSelectAll = vi.fn();
      render(
        <RulesTable
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

      const selectAllButton = screen.getByTitle('Select all');
      fireEvent.click(selectAllButton);

      expect(handleToggleSelectAll).toHaveBeenCalled();
    });

    it('highlights selected rows', () => {
      const selectedIds = new Set(['1']);
      render(
        <RulesTable
          rules={mockRules}
          loading={false}
          onDelete={noop}
          selectedIds={selectedIds}
          onToggleSelection={noop}
          onToggleSelectAll={noop}
          isAllSelected={false}
          hasSelection={true}
        />
      );

      // Check that Deselect button appears for selected row
      expect(screen.getByTitle('Deselect')).toBeInTheDocument();
    });

    it('does not render checkboxes when selection props are not provided', () => {
      render(<RulesTable rules={mockRules} loading={false} onDelete={noop} />);

      expect(screen.queryByTitle('Select all')).not.toBeInTheDocument();
      expect(screen.queryByTitle('Select')).not.toBeInTheDocument();
    });
  });

  describe('Column Sorting', () => {
    const sortableRules: Rule[] = [
      {
        id: '1',
        groupId: 'group-1',
        type: 'whitelist',
        value: 'banana.com',
        comment: null,
        createdAt: '2024-01-15T10:00:00Z',
      },
      {
        id: '2',
        groupId: 'group-1',
        type: 'blocked_subdomain',
        value: 'apple.com',
        comment: null,
        createdAt: '2024-01-20T10:00:00Z',
      },
      {
        id: '3',
        groupId: 'group-1',
        type: 'blocked_path',
        value: 'cherry.com',
        comment: null,
        createdAt: '2024-01-10T10:00:00Z',
      },
    ];

    it('renders sortable column headers with sort icons', () => {
      render(<RulesTable rules={sortableRules} loading={false} onDelete={noop} />);

      expect(screen.getByTestId('sort-value')).toBeInTheDocument();
      expect(screen.getByTestId('sort-type')).toBeInTheDocument();
      expect(screen.getByTestId('sort-createdAt')).toBeInTheDocument();
    });

    it('sorts by value ascending when clicking value header', () => {
      render(<RulesTable rules={sortableRules} loading={false} onDelete={noop} />);

      const sortButton = screen.getByTestId('sort-value');
      fireEvent.click(sortButton);

      const rows = screen.getAllByRole('row');
      // Header row + 3 data rows
      expect(rows).toHaveLength(4);

      // Check order: apple, banana, cherry (ascending)
      const cells = screen.getAllByText(/\.com$/);
      expect(cells[0]).toHaveTextContent('apple.com');
      expect(cells[1]).toHaveTextContent('banana.com');
      expect(cells[2]).toHaveTextContent('cherry.com');
    });

    it('sorts by value descending when clicking value header twice', () => {
      render(<RulesTable rules={sortableRules} loading={false} onDelete={noop} />);

      const sortButton = screen.getByTestId('sort-value');
      fireEvent.click(sortButton); // asc
      fireEvent.click(sortButton); // desc

      const cells = screen.getAllByText(/\.com$/);
      expect(cells[0]).toHaveTextContent('cherry.com');
      expect(cells[1]).toHaveTextContent('banana.com');
      expect(cells[2]).toHaveTextContent('apple.com');
    });

    it('clears sort when clicking header three times', () => {
      render(<RulesTable rules={sortableRules} loading={false} onDelete={noop} />);

      const sortButton = screen.getByTestId('sort-value');
      fireEvent.click(sortButton); // asc
      fireEvent.click(sortButton); // desc
      fireEvent.click(sortButton); // clear

      // Should return to original order: banana, apple, cherry
      const cells = screen.getAllByText(/\.com$/);
      expect(cells[0]).toHaveTextContent('banana.com');
      expect(cells[1]).toHaveTextContent('apple.com');
      expect(cells[2]).toHaveTextContent('cherry.com');
    });

    it('sorts by type', () => {
      render(<RulesTable rules={sortableRules} loading={false} onDelete={noop} />);

      const sortButton = screen.getByTestId('sort-type');
      fireEvent.click(sortButton);

      // Types in order: blocked_path, blocked_subdomain, whitelist
      const cells = screen.getAllByText(/\.com$/);
      expect(cells[0]).toHaveTextContent('cherry.com'); // blocked_path
      expect(cells[1]).toHaveTextContent('apple.com'); // blocked_subdomain
      expect(cells[2]).toHaveTextContent('banana.com'); // whitelist
    });

    it('sorts by date ascending', () => {
      render(<RulesTable rules={sortableRules} loading={false} onDelete={noop} />);

      const sortButton = screen.getByTestId('sort-createdAt');
      fireEvent.click(sortButton);

      // Oldest first: cherry (Jan 10), banana (Jan 15), apple (Jan 20)
      const cells = screen.getAllByText(/\.com$/);
      expect(cells[0]).toHaveTextContent('cherry.com');
      expect(cells[1]).toHaveTextContent('banana.com');
      expect(cells[2]).toHaveTextContent('apple.com');
    });

    it('sorts by date descending', () => {
      render(<RulesTable rules={sortableRules} loading={false} onDelete={noop} />);

      const sortButton = screen.getByTestId('sort-createdAt');
      fireEvent.click(sortButton); // asc
      fireEvent.click(sortButton); // desc

      // Newest first: apple (Jan 20), banana (Jan 15), cherry (Jan 10)
      const cells = screen.getAllByText(/\.com$/);
      expect(cells[0]).toHaveTextContent('apple.com');
      expect(cells[1]).toHaveTextContent('banana.com');
      expect(cells[2]).toHaveTextContent('cherry.com');
    });

    it('changes sort field when clicking different header', () => {
      render(<RulesTable rules={sortableRules} loading={false} onDelete={noop} />);

      // Sort by value first
      fireEvent.click(screen.getByTestId('sort-value'));

      // Then sort by type
      fireEvent.click(screen.getByTestId('sort-type'));

      // Should be sorted by type ascending
      const cells = screen.getAllByText(/\.com$/);
      expect(cells[0]).toHaveTextContent('cherry.com'); // blocked_path
    });
  });

  describe('Inline Editing', () => {
    const editableRules: Rule[] = [
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
        value: 'ads.example.com',
        comment: null,
        createdAt: '2024-01-16T10:00:00Z',
      },
    ];

    it('shows edit button when onSave is provided', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      expect(editButtons).toHaveLength(2);
    });

    it('does not show edit button when onSave is not provided', () => {
      render(<RulesTable rules={editableRules} loading={false} onDelete={noop} />);

      expect(screen.queryByTestId('edit-button')).not.toBeInTheDocument();
    });

    it('enters edit mode when clicking edit button', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      expect(screen.getByTestId('edit-value-input')).toBeInTheDocument();
      expect(screen.getByTestId('edit-comment-input')).toBeInTheDocument();
      expect(screen.getByTestId('save-edit-button')).toBeInTheDocument();
      expect(screen.getByTestId('cancel-edit-button')).toBeInTheDocument();
    });

    it('enters edit mode when clicking on value text', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const valueCell = screen.getByText('google.com');
      fireEvent.click(valueCell);

      expect(screen.getByTestId('edit-value-input')).toBeInTheDocument();
    });

    it('populates edit inputs with current values', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      const valueInput = screen.getByTestId('edit-value-input');
      const commentInput = screen.getByTestId('edit-comment-input');

      expect((valueInput as HTMLInputElement).value).toBe('google.com');
      expect((commentInput as HTMLInputElement).value).toBe('Search engine');
    });

    it('cancels edit when clicking cancel button', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      expect(screen.getByTestId('edit-value-input')).toBeInTheDocument();

      const cancelButton = screen.getByTestId('cancel-edit-button');
      fireEvent.click(cancelButton);

      expect(screen.queryByTestId('edit-value-input')).not.toBeInTheDocument();
    });

    it('cancels edit when pressing Escape key', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      expect(screen.getByTestId('edit-value-input')).toBeInTheDocument();

      await user.keyboard('{Escape}');

      expect(screen.queryByTestId('edit-value-input')).not.toBeInTheDocument();
    });

    it('calls onSave with updated value when saving', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      const valueInput = screen.getByTestId('edit-value-input');
      await user.clear(valueInput);
      await user.type(valueInput, 'newdomain.com');

      const saveButton = screen.getByTestId('save-edit-button');
      fireEvent.click(saveButton);

      await waitFor(() => {
        expect(handleSave).toHaveBeenCalledWith('1', {
          value: 'newdomain.com',
          comment: undefined,
        });
      });
    });

    it('calls onSave with updated comment when saving', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      const commentInput = screen.getByTestId('edit-comment-input');
      await user.clear(commentInput);
      await user.type(commentInput, 'Updated comment');

      const saveButton = screen.getByTestId('save-edit-button');
      fireEvent.click(saveButton);

      await waitFor(() => {
        expect(handleSave).toHaveBeenCalledWith('1', {
          value: undefined,
          comment: 'Updated comment',
        });
      });
    });

    it('saves when pressing Enter key', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

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
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      const valueInput = screen.getByTestId('edit-value-input');
      await user.clear(valueInput);

      const saveButton = screen.getByTestId('save-edit-button');
      expect(saveButton).toBeDisabled();
    });

    it('exits edit mode without calling onSave when nothing changed', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      // Press Enter without making changes
      await user.keyboard('{Enter}');

      expect(handleSave).not.toHaveBeenCalled();
      expect(screen.queryByTestId('edit-value-input')).not.toBeInTheDocument();
    });

    it('applies amber background to row in edit mode', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      const rows = screen.getAllByRole('row');
      // First row is header, second is the one we're editing
      expect(rows[1]).toHaveClass('bg-amber-50');
    });

    it('disables selection checkbox while editing', () => {
      const handleSave = vi.fn().mockResolvedValue(true);
      const selectedIds = new Set<string>();
      render(
        <RulesTable
          rules={editableRules}
          loading={false}
          onDelete={noop}
          onSave={handleSave}
          selectedIds={selectedIds}
          onToggleSelection={noop}
          onToggleSelectAll={noop}
          isAllSelected={false}
          hasSelection={false}
        />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      // The checkbox in the editing row should be disabled
      const selectButtons = screen.getAllByTitle(/select/i);
      expect(selectButtons[1]).toBeDisabled(); // First is select all, second is the row checkbox
    });

    it('exits edit mode after successful save', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      const valueInput = screen.getByTestId('edit-value-input');
      await user.clear(valueInput);
      await user.type(valueInput, 'newdomain.com');

      const saveButton = screen.getByTestId('save-edit-button');
      fireEvent.click(saveButton);

      await waitFor(() => {
        expect(screen.queryByTestId('edit-value-input')).not.toBeInTheDocument();
      });
    });

    it('stays in edit mode after failed save', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(false);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      const valueInput = screen.getByTestId('edit-value-input');
      await user.clear(valueInput);
      await user.type(valueInput, 'newdomain.com');

      const saveButton = screen.getByTestId('save-edit-button');
      fireEvent.click(saveButton);

      await waitFor(() => {
        expect(handleSave).toHaveBeenCalled();
      });

      // Should still be in edit mode after failed save
      expect(screen.getByTestId('edit-value-input')).toBeInTheDocument();
    });

    it('clears comment when saving empty comment', async () => {
      const user = userEvent.setup();
      const handleSave = vi.fn().mockResolvedValue(true);
      render(
        <RulesTable rules={editableRules} loading={false} onDelete={noop} onSave={handleSave} />
      );

      const editButtons = screen.getAllByTestId('edit-button');
      fireEvent.click(editButtons[0]);

      const commentInput = screen.getByTestId('edit-comment-input');
      await user.clear(commentInput);

      const saveButton = screen.getByTestId('save-edit-button');
      fireEvent.click(saveButton);

      await waitFor(() => {
        expect(handleSave).toHaveBeenCalledWith('1', {
          value: undefined,
          comment: null,
        });
      });
    });
  });
});
