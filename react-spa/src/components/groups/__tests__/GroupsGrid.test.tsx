import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { GroupsGrid } from '../GroupsGrid';

describe('GroupsGrid', () => {
  it('renders library groups and dispatches clone and read-only navigation actions', () => {
    const onNavigateToRules = vi.fn();
    const onOpenCloneModal = vi.fn();

    render(
      <GroupsGrid
        activeView="library"
        groups={[
          {
            id: 'library-1',
            name: 'biblioteca',
            displayName: 'Biblioteca',
            description: 'Biblioteca',
            domainCount: 4,
            status: 'Active',
            visibility: 'instance_public',
          },
        ]}
        loading={false}
        error={null}
        admin
        teacherCanCreateGroups={false}
        onRetry={vi.fn()}
        onOpenNewModal={vi.fn()}
        onNavigateToRules={onNavigateToRules}
        onOpenConfigModal={vi.fn()}
        onOpenCloneModal={onOpenCloneModal}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: /view/i }));
    fireEvent.click(screen.getByRole('button', { name: /clone/i }));

    expect(onNavigateToRules).toHaveBeenCalledWith({
      id: 'library-1',
      name: 'Biblioteca',
      readOnly: true,
    });
    expect(onOpenCloneModal).toHaveBeenCalledWith('library-1');
  });
});
