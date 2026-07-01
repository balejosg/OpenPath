import { useState } from 'react';
import type { AllowedGroup, GroupsActiveView, LibraryGroup } from './useGroupsViewModel';

export function useGroupsViewModelState() {
  const [activeView, setActiveView] = useState<GroupsActiveView>('my');
  const [showNewModal, setShowNewModal] = useState(false);
  const [showCloneModal, setShowCloneModal] = useState(false);
  const [selectedGroup, setSelectedGroup] = useState<AllowedGroup | null>(null);
  const [cloneSource, setCloneSource] = useState<LibraryGroup | null>(null);
  const [newGroupName, setNewGroupName] = useState('');
  const [newGroupDescription, setNewGroupDescription] = useState('');
  const [newGroupError, setNewGroupError] = useState('');
  const [cloneName, setCloneName] = useState('');
  const [cloneDisplayName, setCloneDisplayName] = useState('');
  const [cloneError, setCloneError] = useState('');
  const [saving, setSaving] = useState(false);

  return {
    activeView,
    setActiveView,
    showNewModal,
    setShowNewModal,
    showCloneModal,
    setShowCloneModal,
    selectedGroup,
    setSelectedGroup,
    cloneSource,
    setCloneSource,
    newGroupName,
    setNewGroupName,
    newGroupDescription,
    setNewGroupDescription,
    newGroupError,
    setNewGroupError,
    cloneName,
    setCloneName,
    cloneDisplayName,
    setCloneDisplayName,
    cloneError,
    setCloneError,
    saving,
    setSaving,
  };
}
