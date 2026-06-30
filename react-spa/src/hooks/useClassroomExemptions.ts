import { useCallback, useEffect, useMemo, useState } from 'react';
import type {
  Classroom,
  ClassroomExemption,
  OneOffScheduleWithPermissions,
  ScheduleWithPermissions,
} from '../types';
import { trpc } from '../lib/trpc';
import { reportError } from '../lib/reportError';
import {
  useScheduleBoundaryInvalidation,
  type ScheduleBoundaryLike,
} from './useScheduleBoundaryInvalidation';

interface UseClassroomExemptionsParams {
  selectedClassroom: Classroom | null;
  activeSchedule: ScheduleWithPermissions | OneOffScheduleWithPermissions | null;
  scheduleBoundarySources: readonly ScheduleBoundaryLike[];
  refetchClassrooms: () => Promise<Classroom[]>;
}

export function useClassroomExemptions({
  selectedClassroom,
  activeSchedule,
  scheduleBoundarySources,
  refetchClassrooms,
}: UseClassroomExemptionsParams) {
  const [exemptions, setExemptions] = useState<ClassroomExemption[]>([]);
  const [loadingExemptions, setLoadingExemptions] = useState(false);
  const [exemptionsError, setExemptionsError] = useState<string | null>(null);
  const [exemptionMutating, setExemptionMutating] = useState<Partial<Record<string, boolean>>>({});

  const fetchExemptions = useCallback(async (classroomId: string) => {
    try {
      setLoadingExemptions(true);
      setExemptionsError(null);
      const result = await trpc.classrooms.listExemptions.query({ classroomId });
      setExemptions(result.exemptions);
    } catch (err) {
      reportError('Failed to fetch exemptions:', err);
      setExemptionsError('Unable to load exemptions');
      setExemptions([]);
    } finally {
      setLoadingExemptions(false);
    }
  }, []);

  useEffect(() => {
    if (!selectedClassroom) {
      setExemptions([]);
      setExemptionsError(null);
      return;
    }

    void fetchExemptions(selectedClassroom.id);
  }, [selectedClassroom?.id, fetchExemptions, selectedClassroom]);

  const exemptionByMachineId = useMemo(() => {
    const map = new Map<string, ClassroomExemption>();
    exemptions.forEach((exemption) => {
      const existing = map.get(exemption.machineId);
      if (!existing || (existing.source === 'schedule' && exemption.source === 'operational')) {
        map.set(exemption.machineId, exemption);
      }
    });
    return map;
  }, [exemptions]);

  const setMachineExemptionMutating = useCallback((machineId: string, next: boolean) => {
    setExemptionMutating((prev) => ({ ...prev, [machineId]: next }));
  }, []);

  const handleCreateExemption = useCallback(
    async (machineId: string, groupId: string | null = null) => {
      if (!selectedClassroom || !activeSchedule) {
        return;
      }

      setMachineExemptionMutating(machineId, true);
      try {
        setExemptionsError(null);
        await trpc.classrooms.createExemption.mutate({
          machineId,
          classroomId: selectedClassroom.id,
          scheduleId: activeSchedule.id,
          groupId,
        });
        await fetchExemptions(selectedClassroom.id);
      } catch (err) {
        reportError('Failed to create exemption:', err);
        setExemptionsError('Unable to release the machine');
      } finally {
        setMachineExemptionMutating(machineId, false);
      }
    },
    [selectedClassroom, activeSchedule, fetchExemptions, setMachineExemptionMutating]
  );

  const handleDeleteExemption = useCallback(
    async (machineId: string) => {
      if (!selectedClassroom) {
        return;
      }

      const exemption = exemptionByMachineId.get(machineId);
      if (!exemption) {
        return;
      }

      setMachineExemptionMutating(machineId, true);
      try {
        setExemptionsError(null);
        await trpc.classrooms.deleteExemption.mutate({ id: exemption.id });
        await fetchExemptions(selectedClassroom.id);
      } catch (err) {
        reportError('Failed to delete exemption:', err);
        setExemptionsError('Unable to restore restriction');
      } finally {
        setMachineExemptionMutating(machineId, false);
      }
    },
    [selectedClassroom, exemptionByMachineId, fetchExemptions, setMachineExemptionMutating]
  );

  const handleCreateOperationalExemption = useCallback(
    async (machineId: string, durationHours: number, reason: string) => {
      if (!selectedClassroom) {
        return;
      }

      setMachineExemptionMutating(machineId, true);
      try {
        setExemptionsError(null);
        await trpc.classrooms.createOperationalExemption.mutate({
          machineId,
          classroomId: selectedClassroom.id,
          durationHours,
          reason,
        });
        await fetchExemptions(selectedClassroom.id);
      } catch (err) {
        reportError('Failed to create operational exemption:', err);
        setExemptionsError('Unable to create exemption');
      } finally {
        setMachineExemptionMutating(machineId, false);
      }
    },
    [selectedClassroom, fetchExemptions, setMachineExemptionMutating]
  );

  useScheduleBoundaryInvalidation({
    schedules: scheduleBoundarySources,
    enabled: !!selectedClassroom && !selectedClassroom.activeGroup,
    onBoundary: () => {
      void refetchClassrooms();
      if (selectedClassroom) {
        void fetchExemptions(selectedClassroom.id);
      }
    },
  });

  return {
    exemptionByMachineId,
    exemptionMutating,
    exemptionsError,
    handleCreateExemption,
    handleCreateOperationalExemption,
    handleDeleteExemption,
    loadingExemptions,
    setExemptionsError,
  };
}
