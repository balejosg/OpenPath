import { useCallback, useEffect, useState } from 'react';
import type { Classroom } from '../types';
import { trpc } from '../lib/trpc';
import { resolveTrpcErrorMessage } from '../lib/error-utils';
import { reportError } from '../lib/reportError';
import { CLASSROOM_UNRESTRICTED_SELECT_VALUE } from '../components/groups/GroupLabel';

interface UseClassroomConfigActionsParams {
  selectedClassroom: Classroom | null;
  refetchClassrooms: () => Promise<Classroom[]>;
  setSelectedClassroom: (classroom: Classroom | null) => void;
}

export const useClassroomConfigActions = ({
  selectedClassroom,
  refetchClassrooms,
  setSelectedClassroom,
}: UseClassroomConfigActionsParams) => {
  const [classroomConfigError, setClassroomConfigError] = useState('');

  useEffect(() => {
    setClassroomConfigError('');
  }, [selectedClassroom?.id]);

  const handleGroupChange = useCallback(
    async (groupId: string | null) => {
      if (!selectedClassroom) return;

      try {
        setClassroomConfigError('');

        const unrestricted = groupId === CLASSROOM_UNRESTRICTED_SELECT_VALUE;
        const nextGroupId = unrestricted || groupId === '' ? null : groupId;

        await trpc.classrooms.setActiveGroup.mutate({
          id: selectedClassroom.id,
          groupId: nextGroupId,
          ...(unrestricted ? { unrestricted: true } : {}),
        });
        const updatedClassrooms = await refetchClassrooms();
        const updated = updatedClassrooms.find((c) => c.id === selectedClassroom.id);
        if (updated) {
          setSelectedClassroom(updated);
        }
      } catch (err) {
        reportError('Failed to update active group:', err);
      }
    },
    [selectedClassroom, refetchClassrooms, setSelectedClassroom]
  );

  const handleDefaultGroupChange = useCallback(
    async (groupId: string) => {
      if (!selectedClassroom) return;

      try {
        setClassroomConfigError('');
        await trpc.classrooms.update.mutate({
          id: selectedClassroom.id,
          defaultGroupId: groupId || null,
        });
        const updatedClassrooms = await refetchClassrooms();
        const updated = updatedClassrooms.find((c) => c.id === selectedClassroom.id);
        if (updated) {
          setSelectedClassroom(updated);
        }
      } catch (err) {
        reportError('Failed to update default group:', err);
        setClassroomConfigError(
          resolveTrpcErrorMessage(err, {
            badRequest: 'Unable to update the default group. Try again.',
            forbidden: 'Unable to update the default group. Try again.',
            unauthorized: 'Unable to update the default group. Try again.',
            fallback: 'Unable to update the default group. Try again.',
          })
        );
      }
    },
    [selectedClassroom, refetchClassrooms, setSelectedClassroom]
  );

  const handleCaptivePortalDomainsChange = useCallback(
    async (captivePortalDomains: string[]) => {
      if (!selectedClassroom) return;

      try {
        setClassroomConfigError('');
        await trpc.classrooms.update.mutate({
          id: selectedClassroom.id,
          captivePortalDomains,
        });
        const updatedClassrooms = await refetchClassrooms();
        const updated = updatedClassrooms.find((c) => c.id === selectedClassroom.id);
        if (updated) {
          setSelectedClassroom(updated);
        }
      } catch (err) {
        reportError('Failed to update captive portal domains:', err);
        setClassroomConfigError(
          resolveTrpcErrorMessage(err, {
            badRequest: 'Enter exact domain names only, separated by commas.',
            fallback: 'Unable to update captive portal domains. Try again.',
          })
        );
      }
    },
    [selectedClassroom, refetchClassrooms, setSelectedClassroom]
  );

  return {
    classroomConfigError,
    handleGroupChange,
    handleDefaultGroupChange,
    handleCaptivePortalDomainsChange,
  };
};
