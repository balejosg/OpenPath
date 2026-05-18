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

    fireEvent.click(screen.getByRole('button', { name: /biblioteca/i }));
    fireEvent.click(screen.getByRole('button', { name: /\+ new group/i }));

    expect(onActiveViewChange).toHaveBeenCalledWith('library');
    expect(onOpenNewModal).toHaveBeenCalled();
  });
});
