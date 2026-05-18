import { useCallback, useEffect, useState } from 'react';
import type { Classroom } from '../types';
import { trpc } from '../lib/trpc';
import { resolveTrpcErrorMessage } from '../lib/error-utils';
import { reportError } from '../lib/reportError';

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

        const nextGroupId = groupId === '' ? null : groupId;

        await trpc.classrooms.setActiveGroup.mutate({
          id: selectedClassroom.id,
          groupId: nextGroupId,
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
        const fallback =
          groupId === ''
            ? 'You cannot leave the classroom without a default group while no valid active group exists.'
            : 'Unable to update the default group. Try again.';

        setClassroomConfigError(
          resolveTrpcErrorMessage(err, {
            badRequest:
              'You cannot leave the classroom without a default group while no valid active group exists.',
            forbidden: fallback,
            unauthorized: fallback,
            fallback,
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
  };
};
