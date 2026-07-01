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

  it('navigates directly to domains from a my-group card', () => {
    const onNavigateToRules = vi.fn();

    render(
      <GroupsGrid
        activeView="my"
        groups={[
          {
            id: 'group-1',
            name: 'grupo-1',
            displayName: 'Grupo 1',
            description: 'Grupo 1',
            domainCount: 3,
            status: 'Active',
            visibility: 'private',
          },
        ]}
        loading={false}
        error={null}
        admin
        teacherCanCreateGroups={false}
        onRetry={vi.fn()}
        onOpenNewModal={vi.fn()}
        onNavigateToRules={onNavigateToRules}
        onOpenCloneModal={vi.fn()}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: /manage domains/i }));
    expect(onNavigateToRules).toHaveBeenCalledWith({ id: 'group-1', name: 'Grupo 1' });
  });
});
