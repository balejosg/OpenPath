import { useCallback, useMemo, useState } from 'react';
import { isAdmin } from '../lib/auth';
import { toClassroomsFromModels } from '../lib/classrooms';
import { selectFilteredClassroomsFromModels } from '../lib/classroom-selectors';
import { trpc } from '../lib/trpc';
import { reportError } from '../lib/reportError';
import { useAllowedGroups } from './useAllowedGroups';
import { useClassroomListModelsQuery } from './useClassroomsList';
import { useListDetailSelection } from './useListDetailSelection';
import { useNormalizedSearch } from './useNormalizedSearch';

interface UseClassroomsViewModelOptions {
  initialSelectedClassroomId?: string | null;
}

export function useClassroomsViewModel({
  initialSelectedClassroomId = null,
}: UseClassroomsViewModelOptions = {}) {
  const [searchQuery, setSearchQuery] = useState('');
  const [showNewModal, setShowNewModal] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [newName, setNewName] = useState('');
  const [newGroup, setNewGroup] = useState('');
  const [newError, setNewError] = useState('');
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const normalizedSearchQuery = useNormalizedSearch(searchQuery);
  const admin = isAdmin();
  const classroomsQuery = useClassroomListModelsQuery();

  const {
    groups: allowedGroups,
    groupById,
    options: groupOptions,
    isLoading: groupsLoading,
    error: groupsQueryError,
    refetch: refetchGroups,
  } = useAllowedGroups();
  const classroomModels = classroomsQuery.data;
  const loadingError = classroomsQuery.error;

  const filteredClassrooms = useMemo(
    () => selectFilteredClassroomsFromModels(classroomModels, normalizedSearchQuery),
    [classroomModels, normalizedSearchQuery]
  );

  const {
    selectedId: selectedClassroomId,
    selectedItem: selectedClassroom,
    setSelectedId: setSelectedClassroomId,
  } = useListDetailSelection(filteredClassrooms, {
    initialSelectedId: initialSelectedClassroomId,
  });

  const allowedGroupsError = groupsQueryError ? 'Unable to load classrooms' : null;
  const isInitialLoading = classroomsQuery.loading || groupsLoading;
  const loadError = loadingError ?? allowedGroupsError;

  const calendarGroupsForDisplay = useMemo(
    () =>
      allowedGroups.map((group) => ({
        id: group.id,
        displayName: group.displayName || group.name,
      })),
    [allowedGroups]
  );

  const refetchClassroomModels = classroomsQuery.refetchClassrooms;
  const refetchClassrooms = useCallback(
    async () => toClassroomsFromModels(await refetchClassroomModels()),
    [refetchClassroomModels]
  );

  const retryLoad = useCallback(() => {
    void refetchGroups();
    void refetchClassrooms();
  }, [refetchClassrooms, refetchGroups]);

  const openNewModal = useCallback(() => {
    setNewName('');
    setNewGroup('');
    setNewError('');
    setShowNewModal(true);
  }, []);

  const closeNewModal = useCallback(() => {
    if (saving) {
      return;
    }

    setShowNewModal(false);
  }, [saving]);

  const setNewNameValue = useCallback((value: string) => {
    setNewName(value);
    setNewError('');
  }, []);

  const handleCreateClassroom = useCallback(async () => {
    if (!newName.trim()) {
      setNewError('Classroom name is required');
      return;
    }

    try {
      setSaving(true);
      setNewError('');
      const created = await trpc.classrooms.create.mutate({
        name: newName.trim(),
        defaultGroupId: newGroup || undefined,
      });
      const updated = await refetchClassrooms();
      const createdClassroom = updated.find((classroom) => classroom.id === created.id);
      if (createdClassroom) {
        setSelectedClassroomId(createdClassroom.id);
      }
      setNewName('');
      setNewGroup('');
      setShowNewModal(false);
    } catch (err) {
      reportError('Failed to create classroom:', err);
      setNewError('Unable to create classroom');
    } finally {
      setSaving(false);
    }
  }, [newName, newGroup, refetchClassrooms, setSelectedClassroomId]);

  const openDeleteConfirm = useCallback(() => {
    setShowDeleteConfirm(true);
  }, []);

  const closeDeleteConfirm = useCallback(() => {
    if (deleting) {
      return;
    }

    setShowDeleteConfirm(false);
  }, [deleting]);

  const handleDeleteClassroom = useCallback(async () => {
    if (!selectedClassroom) {
      return;
    }

    try {
      setDeleting(true);
      await trpc.classrooms.delete.mutate({ id: selectedClassroom.id });
      const updated = await refetchClassrooms();
      setSelectedClassroomId(updated[0]?.id ?? null);
      setShowDeleteConfirm(false);
    } catch (err) {
      reportError('Failed to delete classroom:', err);
    } finally {
      setDeleting(false);
    }
  }, [selectedClassroom, refetchClassrooms, setSelectedClassroomId]);

  return {
    admin,
    allowedGroups,
    groupById,
    groupOptions,
    calendarGroupsForDisplay,
    filteredClassrooms,
    isInitialLoading,
    loadError,
    searchQuery,
    setSearchQuery,
    selectedClassroom,
    selectedClassroomId,
    setSelectedClassroomId,
    refetchClassrooms,
    retryLoad,
    newModal: {
      isOpen: showNewModal,
      saving,
      newName,
      newGroup,
      newError,
      open: openNewModal,
      close: closeNewModal,
      setName: setNewNameValue,
      setGroup: setNewGroup,
      create: handleCreateClassroom,
    },
    deleteDialog: {
      isOpen: showDeleteConfirm,
      deleting,
      open: openDeleteConfirm,
      close: closeDeleteConfirm,
      confirm: handleDeleteClassroom,
    },
  };
}
