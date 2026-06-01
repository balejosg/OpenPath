import { useCallback, useMemo, useState } from 'react';
import type { Classroom } from '../types';
import {
  resolveClassroomGroupSelectState,
  resolveGroupDisplayName,
  resolveGroupLike,
  type GroupLike,
} from '../components/groups/GroupLabel';
import { useClassroomConfigActions } from './useClassroomConfigActions';

export function useClassroomGroupControls(params: {
  admin: boolean;
  selectedClassroom: Classroom | null;
  groupById: ReadonlyMap<string, GroupLike>;
  refetchClassrooms: () => Promise<Classroom[]>;
  setSelectedClassroom: (classroom: Classroom | null) => void;
}) {
  const { admin, selectedClassroom, groupById, refetchClassrooms, setSelectedClassroom } = params;
  const [activeGroupOverwriteConfirm, setActiveGroupOverwriteConfirm] = useState<{
    classroomId: string;
    currentGroupId: string;
    nextGroupId: string | null;
  } | null>(null);
  const [activeGroupOverwriteLoading, setActiveGroupOverwriteLoading] = useState(false);

  const {
    classroomConfigError,
    handleGroupChange,
    handleDefaultGroupChange,
    handleCaptivePortalDomainsChange,
  } = useClassroomConfigActions({
    selectedClassroom,
    refetchClassrooms,
    setSelectedClassroom,
  });

  const {
    source: selectedClassroomSource,
    activeGroupValue: activeGroupSelectValue,
    defaultGroupValue: defaultGroupSelectValue,
  } = useMemo(
    () =>
      resolveClassroomGroupSelectState({
        classroom: selectedClassroom ?? null,
        admin,
      }),
    [selectedClassroom, admin]
  );

  const resolveGroupName = useCallback(
    (groupId: string | null) =>
      resolveGroupDisplayName({
        groupId,
        group:
          selectedClassroom?.currentGroupId === groupId
            ? resolveGroupLike({
                groupId,
                groupById,
                displayName: selectedClassroom.currentGroupDisplayName,
              })
            : groupId
              ? (groupById.get(groupId) ?? null)
              : null,
        source: groupId ? 'manual' : 'none',
        revealUnknownId: admin,
        noneLabel: 'No active group',
      }),
    [admin, groupById, selectedClassroom]
  );

  const requestActiveGroupChange = useCallback(
    (next: string) => {
      if (!selectedClassroom) {
        return;
      }

      const currentActiveGroupId = selectedClassroom.activeGroup ?? null;
      const nextGroupId = next || null;

      if (currentActiveGroupId && currentActiveGroupId !== nextGroupId) {
        setActiveGroupOverwriteConfirm({
          classroomId: selectedClassroom.id,
          currentGroupId: currentActiveGroupId,
          nextGroupId,
        });
        return;
      }

      void handleGroupChange(next);
    },
    [selectedClassroom, handleGroupChange]
  );

  const closeActiveGroupOverwriteConfirm = useCallback(() => {
    if (activeGroupOverwriteLoading) {
      return;
    }

    setActiveGroupOverwriteConfirm(null);
  }, [activeGroupOverwriteLoading]);

  const confirmActiveGroupOverwrite = useCallback(async () => {
    if (!activeGroupOverwriteConfirm) {
      return;
    }

    if (selectedClassroom?.id !== activeGroupOverwriteConfirm.classroomId) {
      setActiveGroupOverwriteConfirm(null);
      return;
    }

    setActiveGroupOverwriteLoading(true);
    try {
      await handleGroupChange(activeGroupOverwriteConfirm.nextGroupId);
      setActiveGroupOverwriteConfirm(null);
    } finally {
      setActiveGroupOverwriteLoading(false);
    }
  }, [activeGroupOverwriteConfirm, handleGroupChange, selectedClassroom?.id]);

  return {
    activeGroupOverwriteConfirm,
    activeGroupOverwriteLoading,
    activeGroupSelectValue,
    classroomConfigError,
    confirmActiveGroupOverwrite,
    defaultGroupSelectValue,
    handleDefaultGroupChange,
    handleCaptivePortalDomainsChange,
    requestActiveGroupChange,
    resolveGroupName,
    selectedClassroomSource,
    closeActiveGroupOverwriteConfirm,
  };
}
