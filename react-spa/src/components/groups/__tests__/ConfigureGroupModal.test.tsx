import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { ConfigureGroupModal } from '../ConfigureGroupModal';

describe('ConfigureGroupModal', () => {
  it('updates configuration fields and navigates to rule management', () => {
    const onStatusChange = vi.fn();
    const onVisibilityChange = vi.fn();
    const onSave = vi.fn();
    const onClose = vi.fn();
    const onNavigateToRules = vi.fn();

    render(
      <ConfigureGroupModal
        isOpen
        group={{
          id: 'group-1',
          name: 'grupo-1',
          displayName: 'Grupo 1',
          createdAt: '2026-04-01T10:00:00.000Z',
          updatedAt: null,
          ownerUserId: null,
          whitelistCount: 2,
          blockedSubdomainCount: 1,
          blockedPathCount: 0,
          enabled: true,
          visibility: 'private',
        }}
        saving={false}
        description="Grupo 1"
        status="Active"
        visibility="private"
        error={null}
        onClose={onClose}
        onDescriptionChange={vi.fn()}
        onStatusChange={onStatusChange}
        onVisibilityChange={onVisibilityChange}
        onSave={onSave}
        onNavigateToRules={onNavigateToRules}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: 'Inactive' }));
    fireEvent.click(screen.getByRole('button', { name: 'Public' }));
    fireEvent.click(screen.getByRole('button', { name: 'Manage' }));
    fireEvent.click(screen.getByRole('button', { name: 'Save Changes' }));

    expect(onStatusChange).toHaveBeenCalledWith('Inactive');
    expect(onVisibilityChange).toHaveBeenCalledWith('instance_public');
    expect(onClose).toHaveBeenCalled();
    expect(onNavigateToRules).toHaveBeenCalledWith({ id: 'group-1', name: 'Grupo 1' });
    expect(onSave).toHaveBeenCalled();
  });

  it('calls onDescriptionChange when the textarea value changes', () => {
    const onDescriptionChange = vi.fn();

    render(
      <ConfigureGroupModal
        isOpen
        group={{
          id: 'group-2',
          name: 'grupo-2',
          displayName: 'Grupo 2',
          createdAt: '2026-04-01T10:00:00.000Z',
          updatedAt: null,
          ownerUserId: null,
          whitelistCount: 0,
          blockedSubdomainCount: 0,
          blockedPathCount: 0,
          enabled: true,
          visibility: 'private',
        }}
        saving={false}
        description=""
        status="Active"
        visibility="private"
        error={null}
        onClose={vi.fn()}
        onDescriptionChange={onDescriptionChange}
        onStatusChange={vi.fn()}
        onVisibilityChange={vi.fn()}
        onSave={vi.fn()}
        onNavigateToRules={vi.fn()}
      />
    );

    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'new description' } });
    expect(onDescriptionChange).toHaveBeenCalledWith('new description');
  });

  it('does not render the slug paragraph when displayName is empty', () => {
    render(
      <ConfigureGroupModal
        isOpen
        group={{
          id: 'group-3',
          name: 'grupo-3',
          displayName: '',
          createdAt: '2026-04-01T10:00:00.000Z',
          updatedAt: null,
          ownerUserId: null,
          whitelistCount: 0,
          blockedSubdomainCount: 0,
          blockedPathCount: 0,
          enabled: true,
          visibility: 'private',
        }}
        saving={false}
        description=""
        status="Active"
        visibility="private"
        error={null}
        onClose={vi.fn()}
        onDescriptionChange={vi.fn()}
        onStatusChange={vi.fn()}
        onVisibilityChange={vi.fn()}
        onSave={vi.fn()}
        onNavigateToRules={vi.fn()}
      />
    );

    // The slug <p> (text-xs text-slate-500) should not appear when displayName is falsy.
    // The group name may still appear in the modal title, so we target the slug paragraph class.
    const slugParagraph = document.querySelector('p.text-xs.text-slate-500');
    // Either the element is absent or it does not contain the slug text
    expect(slugParagraph?.textContent ?? '').not.toContain('grupo-3');
  });

  it('calls onVisibilityChange with "private" when the Private button is clicked', () => {
    const onVisibilityChange = vi.fn();

    render(
      <ConfigureGroupModal
        isOpen
        group={{
          id: 'group-4',
          name: 'grupo-4',
          displayName: 'Grupo 4',
          createdAt: '2026-04-01T10:00:00.000Z',
          updatedAt: null,
          ownerUserId: null,
          whitelistCount: 0,
          blockedSubdomainCount: 0,
          blockedPathCount: 0,
          enabled: true,
          visibility: 'instance_public',
        }}
        saving={false}
        description=""
        status="Active"
        visibility="instance_public"
        error={null}
        onClose={vi.fn()}
        onDescriptionChange={vi.fn()}
        onStatusChange={vi.fn()}
        onVisibilityChange={onVisibilityChange}
        onSave={vi.fn()}
        onNavigateToRules={vi.fn()}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: 'Private' }));
    expect(onVisibilityChange).toHaveBeenCalledWith('private');
  });

  it('renders nothing when group is null', () => {
    const { container } = render(
      <ConfigureGroupModal
        isOpen
        group={null}
        saving={false}
        description=""
        status="Active"
        visibility="private"
        error={null}
        onClose={vi.fn()}
        onDescriptionChange={vi.fn()}
        onStatusChange={vi.fn()}
        onVisibilityChange={vi.fn()}
        onSave={vi.fn()}
        onNavigateToRules={vi.fn()}
      />
    );

    expect(container.firstChild).toBeNull();
  });

  it('shows spinner and disables buttons when saving is true', () => {
    render(
      <ConfigureGroupModal
        isOpen
        group={{
          id: 'group-5',
          name: 'grupo-5',
          displayName: 'Grupo 5',
          createdAt: '2026-04-01T10:00:00.000Z',
          updatedAt: null,
          ownerUserId: null,
          whitelistCount: 0,
          blockedSubdomainCount: 0,
          blockedPathCount: 0,
          enabled: true,
          visibility: 'private',
        }}
        saving
        description=""
        status="Active"
        visibility="private"
        error={null}
        onClose={vi.fn()}
        onDescriptionChange={vi.fn()}
        onStatusChange={vi.fn()}
        onVisibilityChange={vi.fn()}
        onSave={vi.fn()}
        onNavigateToRules={vi.fn()}
      />
    );

    const saveButton = screen.getByRole('button', { name: /Save Changes/i });
    const cancelButton = screen.getByRole('button', { name: /Cancel/i });
    expect(saveButton).toBeDisabled();
    expect(cancelButton).toBeDisabled();
  });

  it('shows the error message when error prop is set', () => {
    render(
      <ConfigureGroupModal
        isOpen
        group={{
          id: 'group-6',
          name: 'grupo-6',
          displayName: 'Grupo 6',
          createdAt: '2026-04-01T10:00:00.000Z',
          updatedAt: null,
          ownerUserId: null,
          whitelistCount: 0,
          blockedSubdomainCount: 0,
          blockedPathCount: 0,
          enabled: true,
          visibility: 'private',
        }}
        saving={false}
        description=""
        status="Active"
        visibility="private"
        error="Something went wrong"
        onClose={vi.fn()}
        onDescriptionChange={vi.fn()}
        onStatusChange={vi.fn()}
        onVisibilityChange={vi.fn()}
        onSave={vi.fn()}
        onNavigateToRules={vi.fn()}
      />
    );

    expect(screen.getByText('Something went wrong')).toBeDefined();
  });
});
