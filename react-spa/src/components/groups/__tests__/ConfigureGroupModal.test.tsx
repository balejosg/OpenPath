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
});
