import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { GroupsHeader } from '../GroupsHeader';

describe('GroupsHeader', () => {
  it('switches view and opens the create modal from the my-groups tab', () => {
    const onActiveViewChange = vi.fn();
    const onOpenNewModal = vi.fn();

    render(
      <GroupsHeader
        activeView="my"
        admin
        canCreateGroups
        onActiveViewChange={onActiveViewChange}
        onOpenNewModal={onOpenNewModal}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: /library/i }));
    fireEvent.click(screen.getByRole('button', { name: /\+ new group/i }));

    expect(onActiveViewChange).toHaveBeenCalledWith('library');
    expect(onOpenNewModal).toHaveBeenCalled();
  });

  it('calls onActiveViewChange with "my" when clicking the My groups tab from library view', () => {
    const onActiveViewChange = vi.fn();

    render(
      <GroupsHeader
        activeView="library"
        admin={false}
        canCreateGroups={false}
        onActiveViewChange={onActiveViewChange}
        onOpenNewModal={vi.fn()}
      />
    );

    expect(screen.getByText('Policy Library')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /my groups/i }));
    expect(onActiveViewChange).toHaveBeenCalledWith('my');
  });

  it('hides the new group button when canCreateGroups is false', () => {
    render(
      <GroupsHeader
        activeView="my"
        admin
        canCreateGroups={false}
        onActiveViewChange={vi.fn()}
        onOpenNewModal={vi.fn()}
      />
    );

    expect(screen.queryByRole('button', { name: /new group/i })).not.toBeInTheDocument();
  });

  it('shows library title and subtitle when activeView is library', () => {
    render(
      <GroupsHeader
        activeView="library"
        admin={false}
        canCreateGroups
        onActiveViewChange={vi.fn()}
        onOpenNewModal={vi.fn()}
      />
    );

    expect(screen.getByText('Policy Library')).toBeInTheDocument();
    // New group button should NOT show in library view even with canCreateGroups
    expect(screen.queryByRole('button', { name: /new group/i })).not.toBeInTheDocument();
  });
});
