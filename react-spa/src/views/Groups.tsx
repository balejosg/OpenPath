import React from 'react';
import { CloneGroupModal } from '../components/groups/CloneGroupModal';
import { CreateGroupModal } from '../components/groups/CreateGroupModal';
import { GroupsGrid } from '../components/groups/GroupsGrid';
import { GroupsHeader } from '../components/groups/GroupsHeader';
import { useToast } from '../components/ui/Toast';
import { useGroupsViewModel } from '../hooks/useGroupsViewModel';

interface GroupsProps {
  onNavigateToRules: (group: { id: string; name: string; readOnly?: boolean }) => void;
  headerActions?: React.ReactNode;
}

const Groups: React.FC<GroupsProps> = ({ onNavigateToRules, headerActions }) => {
  const { ToastContainer } = useToast();
  const viewModel = useGroupsViewModel({ onNavigateToRules });

  return (
    <div className="space-y-6">
      <GroupsHeader
        activeView={viewModel.activeView}
        admin={viewModel.admin}
        canCreateGroups={viewModel.canCreateGroups}
        onActiveViewChange={viewModel.setActiveView}
        onOpenNewModal={viewModel.openNewModal}
        headerActions={headerActions}
      />

      <GroupsGrid
        activeView={viewModel.activeView}
        groups={viewModel.groups}
        loading={viewModel.loading}
        error={viewModel.error}
        admin={viewModel.admin}
        teacherCanCreateGroups={viewModel.teacherCanCreateGroups}
        onRetry={() => {
          void viewModel.refetchActiveView();
        }}
        onOpenNewModal={viewModel.openNewModal}
        onNavigateToRules={onNavigateToRules}
        onOpenCloneModal={viewModel.openCloneModal}
      />

      <CreateGroupModal
        isOpen={viewModel.showNewModal}
        saving={viewModel.saving}
        name={viewModel.newGroupName}
        description={viewModel.newGroupDescription}
        error={viewModel.newGroupError}
        onClose={viewModel.closeNewModal}
        onNameChange={viewModel.handleNewGroupNameChange}
        onDescriptionChange={viewModel.setNewGroupDescription}
        onCreate={() => {
          void viewModel.handleCreateGroup();
        }}
      />

      <CloneGroupModal
        isOpen={viewModel.showCloneModal}
        cloneSource={viewModel.cloneSource}
        saving={viewModel.saving}
        name={viewModel.cloneName}
        displayName={viewModel.cloneDisplayName}
        error={viewModel.cloneError}
        onClose={viewModel.closeCloneModal}
        onNameChange={viewModel.handleCloneNameChange}
        onDisplayNameChange={viewModel.handleCloneDisplayNameChange}
        onClone={() => {
          void viewModel.handleCloneGroup();
        }}
      />

      <ToastContainer />
    </div>
  );
};

export default Groups;
