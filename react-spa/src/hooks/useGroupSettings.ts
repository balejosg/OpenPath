import { useState } from 'react';
import type { GroupVisibility } from '@openpath/shared';
import { resolveTrpcErrorMessage } from '../lib/error-utils';
import { reportError } from '../lib/reportError';
import { trpc } from '../lib/trpc';
import { useAllowedGroups } from './useAllowedGroups';

export interface GroupSettingsMetadata {
  displayName: string;
  status: 'Active' | 'Inactive';
  visibility: GroupVisibility;
}

interface UseGroupSettingsOptions {
  groupId: string;
  active: boolean;
}

export function useGroupSettings({ groupId, active }: UseGroupSettingsOptions) {
  const { groupById, refetch } = useAllowedGroups();
  const [isOpen, setIsOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [description, setDescription] = useState('');
  const [status, setStatus] = useState<'Active' | 'Inactive'>('Active');
  const [visibility, setVisibility] = useState<GroupVisibility>('private');

  const group = active ? groupById.get(groupId) : undefined;
  const metadata: GroupSettingsMetadata | null = group
    ? {
        displayName: group.displayName || group.name,
        status: group.enabled ? 'Active' : 'Inactive',
        visibility: (group.visibility as GroupVisibility | undefined) ?? 'private',
      }
    : null;

  const open = () => {
    if (!metadata) return;
    setDescription(metadata.displayName);
    setStatus(metadata.status);
    setVisibility(metadata.visibility);
    setError(null);
    setIsOpen(true);
  };

  const close = () => {
    setError(null);
    setIsOpen(false);
  };

  const save = async () => {
    try {
      setSaving(true);
      setError(null);
      await trpc.groups.update.mutate({
        id: groupId,
        displayName: description,
        enabled: status === 'Active',
        visibility,
      });
      await refetch();
      setIsOpen(false);
    } catch (err) {
      reportError('Failed to update group:', err);
      setError(
        resolveTrpcErrorMessage(err, {
          badRequest: 'Review the group settings before saving.',
          forbidden: 'You do not have permission to update this group.',
          fallback: 'Unable to update group. Try again.',
        })
      );
    } finally {
      setSaving(false);
    }
  };

  return {
    metadata,
    isOpen,
    open,
    close,
    saving,
    error,
    description,
    status,
    visibility,
    setDescription,
    setStatus,
    setVisibility,
    save,
  };
}
