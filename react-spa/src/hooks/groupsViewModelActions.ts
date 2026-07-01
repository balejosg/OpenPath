import { isDuplicateError, resolveTrpcErrorMessage } from '../lib/error-utils';
import { reportError } from '../lib/reportError';
import { trpc } from '../lib/trpc';
import { sanitizeSlug } from '@openpath/shared/slug';
import type { useGroupsViewModelState } from './groupsViewModelState';
import type { useGroupsViewModelData } from './groupsViewModelData';

type GroupsViewModelState = ReturnType<typeof useGroupsViewModelState>;
type GroupsViewModelData = ReturnType<typeof useGroupsViewModelData>;

interface UseGroupsViewModelActionsOptions {
  state: GroupsViewModelState;
  data: GroupsViewModelData;
  onNavigateToRules: (group: { id: string; name: string; readOnly?: boolean }) => void;
}

export function useGroupsViewModelActions({
  state,
  data,
  onNavigateToRules,
}: UseGroupsViewModelActionsOptions) {
  const handleCreateGroup = async () => {
    if (!state.newGroupName.trim()) {
      state.setNewGroupError('Group name is required');
      return;
    }

    const slug = sanitizeSlug(state.newGroupName, { maxLength: 100, allowUnderscore: true });
    if (!slug) {
      state.setNewGroupError('Group slug is invalid');
      return;
    }

    try {
      state.setSaving(true);
      state.setNewGroupError('');
      await trpc.groups.create.mutate({
        name: slug,
        displayName: state.newGroupDescription.trim() || state.newGroupName.trim(),
      });
      await data.refetchGroups();
      state.setNewGroupName('');
      state.setNewGroupDescription('');
      state.setShowNewModal(false);
    } catch (err) {
      reportError('Failed to create group:', err);
      if (isDuplicateError(err)) {
        state.setNewGroupError(
          `A group already exists with that identifier (slug): "${slug}". Try "${slug}-2".`
        );
        return;
      }

      state.setNewGroupError(
        resolveTrpcErrorMessage(err, {
          badRequest: 'Review the group name (slug) before creating.',
          forbidden: 'You do not have permission to create groups.',
          fallback: 'Unable to create group. Try again.',
        })
      );
    } finally {
      state.setSaving(false);
    }
  };

  const handleCloneGroup = async () => {
    if (!state.cloneSource) return;

    const trimmedName = state.cloneName.trim();
    const sanitizedName = trimmedName
      ? sanitizeSlug(trimmedName, { maxLength: 100, allowUnderscore: true })
      : '';

    if (trimmedName && !sanitizedName) {
      state.setCloneError('Group slug is invalid');
      return;
    }

    try {
      state.setSaving(true);
      state.setCloneError('');

      const result = await trpc.groups.clone.mutate({
        sourceGroupId: state.cloneSource.id,
        name: sanitizedName || undefined,
        displayName: state.cloneDisplayName.trim() || undefined,
      });

      await data.refetchGroups();
      state.setActiveView('my');
      state.setShowCloneModal(false);
      state.setCloneSource(null);

      onNavigateToRules({
        id: result.id,
        name: state.cloneDisplayName.trim() || result.name,
      });
    } catch (err) {
      reportError('Failed to clone group:', err);
      state.setCloneError(
        resolveTrpcErrorMessage(err, {
          conflict: 'Inactive groups cannot be cloned.',
          forbidden: 'You do not have permission to clone this group.',
          fallback: 'Unable to clone group. Try again.',
        })
      );
    } finally {
      state.setSaving(false);
    }
  };

  const openNewModal = () => {
    state.setNewGroupName('');
    state.setNewGroupDescription('');
    state.setNewGroupError('');
    state.setShowNewModal(true);
  };

  const closeNewModal = () => {
    state.setShowNewModal(false);
  };

  const openCloneModal = (groupId: string) => {
    const group = data.libraryGroups.find((candidate) => candidate.id === groupId);
    if (!group) return;

    state.setCloneSource(group);
    const baseDisplayName = group.displayName || group.name;
    state.setCloneDisplayName(`${baseDisplayName} Copia`);
    state.setCloneName(`${group.name}-copia`);
    state.setCloneError('');
    state.setShowCloneModal(true);
  };

  const closeCloneModal = () => {
    state.setShowCloneModal(false);
    state.setCloneSource(null);
    state.setCloneError('');
  };

  const handleNewGroupNameChange = (value: string) => {
    state.setNewGroupName(value);
    if (state.newGroupError) state.setNewGroupError('');
  };

  const handleCloneNameChange = (value: string) => {
    state.setCloneName(value);
    if (state.cloneError) state.setCloneError('');
  };

  const handleCloneDisplayNameChange = (value: string) => {
    state.setCloneDisplayName(value);
    if (state.cloneError) state.setCloneError('');
  };

  return {
    handleCreateGroup,
    handleCloneGroup,
    openNewModal,
    closeNewModal,
    openCloneModal,
    closeCloneModal,
    handleNewGroupNameChange,
    handleCloneNameChange,
    handleCloneDisplayNameChange,
  };
}
