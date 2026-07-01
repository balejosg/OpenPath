import type { GroupVisibility } from '@openpath/shared';
import { isAdmin, isTeacher } from '../lib/auth';
import { trpc } from '../lib/trpc';
import { useGroupsViewModelActions } from './groupsViewModelActions';
import { useGroupsViewModelData } from './groupsViewModelData';
import { useGroupsViewModelState } from './groupsViewModelState';

type GroupsListOutput = Awaited<ReturnType<typeof trpc.groups.list.query>>;
export type AllowedGroup = GroupsListOutput[number];

type LibraryListOutput = Awaited<ReturnType<typeof trpc.groups.libraryList.query>>;
export type LibraryGroup = LibraryListOutput[number];

export type GroupsActiveView = 'my' | 'library';

export interface GroupCardViewModel {
  id: string;
  name: string;
  displayName: string;
  description: string;
  domainCount: number;
  status: 'Active' | 'Inactive';
  visibility: GroupVisibility;
}

interface UseGroupsViewModelOptions {
  onNavigateToRules: (group: { id: string; name: string; readOnly?: boolean }) => void;
}

export function useGroupsViewModel({ onNavigateToRules }: UseGroupsViewModelOptions) {
  const state = useGroupsViewModelState();

  const admin = isAdmin();
  const teacherCanCreateGroups = isTeacher();
  const canCreateGroups = admin || teacherCanCreateGroups;
  const data = useGroupsViewModelData(state.activeView);

  const actions = useGroupsViewModelActions({
    state,
    data,
    onNavigateToRules,
  });

  return {
    activeView: state.activeView,
    setActiveView: state.setActiveView,
    admin,
    teacherCanCreateGroups,
    canCreateGroups,
    groups: data.groups,
    loading: data.loading,
    error: data.error,
    refetchActiveView: data.refetchActiveView,
    showNewModal: state.showNewModal,
    showCloneModal: state.showCloneModal,
    selectedGroup: state.selectedGroup,
    cloneSource: state.cloneSource,
    newGroupName: state.newGroupName,
    setNewGroupName: state.setNewGroupName,
    newGroupDescription: state.newGroupDescription,
    setNewGroupDescription: state.setNewGroupDescription,
    newGroupError: state.newGroupError,
    cloneName: state.cloneName,
    setCloneName: state.setCloneName,
    cloneDisplayName: state.cloneDisplayName,
    setCloneDisplayName: state.setCloneDisplayName,
    cloneError: state.cloneError,
    saving: state.saving,
    ...actions,
  };
}
