import { useCallback, useEffect, useState } from 'react';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../types';
import { trpc } from '../lib/trpc';
import { resolveTrpcErrorMessage } from '../lib/error-utils';
import { reportError } from '../lib/reportError';

function formatScheduleError(err: unknown, fallback: string): string {
  const raw = err instanceof Error ? err.message : '';
  return resolveTrpcErrorMessage(err, {
    conflict: 'That time slot is already reserved',
    fallback: raw || fallback,
  });
}

interface ScheduleFormData {
  dayOfWeek: number;
  startTime: string;
  endTime: string;
  groupId: string;
}

interface OneOffScheduleFormData {
  startAt: string;
  endAt: string;
  groupId: string;
}

interface UseClassroomSchedulesParams {
  selectedClassroomId: string | null;
  onSchedulesUpdated?: () => void | Promise<void>;
}

export const useClassroomSchedules = ({
  selectedClassroomId,
  onSchedulesUpdated,
}: UseClassroomSchedulesParams) => {
  const [schedules, setSchedules] = useState<ScheduleWithPermissions[]>([]);
  const [oneOffSchedules, setOneOffSchedules] = useState<OneOffScheduleWithPermissions[]>([]);
  const [loadingSchedules, setLoadingSchedules] = useState(false);
  const [scheduleFormOpen, setScheduleFormOpen] = useState(false);
  const [editingSchedule, setEditingSchedule] = useState<ScheduleWithPermissions | null>(null);
  const [scheduleFormDay, setScheduleFormDay] = useState<number | undefined>(undefined);
  const [scheduleFormStartTime, setScheduleFormStartTime] = useState<string | undefined>(undefined);

  const [oneOffFormOpen, setOneOffFormOpen] = useState(false);
  const [editingOneOffSchedule, setEditingOneOffSchedule] =
    useState<OneOffScheduleWithPermissions | null>(null);

  const [scheduleSaving, setScheduleSaving] = useState(false);
  const [scheduleError, setScheduleError] = useState('');
  const [scheduleDeleteTarget, setScheduleDeleteTarget] = useState<{
    id: string;
    label: string;
  } | null>(null);

  const fetchSchedules = useCallback(async (classroomId: string) => {
    try {
      setLoadingSchedules(true);
      setScheduleError('');
      const result = await trpc.schedules.getByClassroom.query({ classroomId });
      setSchedules(result.schedules);
      setOneOffSchedules(result.oneOffSchedules);
    } catch (err) {
      reportError('Failed to fetch schedules:', err);
      setScheduleError('Unable to load schedules');
      setSchedules([]);
      setOneOffSchedules([]);
    } finally {
      setLoadingSchedules(false);
    }
  }, []);

  useEffect(() => {
    if (!selectedClassroomId) {
      setSchedules([]);
      setOneOffSchedules([]);
      return;
    }

    void fetchSchedules(selectedClassroomId);
  }, [selectedClassroomId, fetchSchedules]);

  const openScheduleCreate = useCallback((dayOfWeek?: number, startTime?: string) => {
    const normalizedDay =
      typeof dayOfWeek === 'number' &&
      Number.isInteger(dayOfWeek) &&
      dayOfWeek >= 1 &&
      dayOfWeek <= 5
        ? dayOfWeek
        : 1;
    const normalizedStartTime = startTime ?? '08:00';
    setScheduleError('');
    setEditingSchedule(null);
    setScheduleFormDay(normalizedDay);
    setScheduleFormStartTime(normalizedStartTime);
    setScheduleFormOpen(true);
  }, []);

  const openScheduleEdit = useCallback((schedule: ScheduleWithPermissions) => {
    setScheduleError('');
    setEditingSchedule(schedule);
    setScheduleFormDay(undefined);
    setScheduleFormStartTime(undefined);
    setScheduleFormOpen(true);
  }, []);

  const closeScheduleForm = useCallback(() => {
    if (scheduleSaving) return;
    setScheduleFormOpen(false);
    setEditingSchedule(null);
    setScheduleFormDay(undefined);
    setScheduleFormStartTime(undefined);
    setScheduleError('');
  }, [scheduleSaving]);

  const openOneOffScheduleCreate = useCallback(() => {
    setScheduleError('');
    setEditingOneOffSchedule(null);
    setOneOffFormOpen(true);
  }, []);

  const openOneOffScheduleEdit = useCallback((schedule: OneOffScheduleWithPermissions) => {
    setScheduleError('');
    setEditingOneOffSchedule(schedule);
    setOneOffFormOpen(true);
  }, []);

  const closeOneOffScheduleForm = useCallback(() => {
    if (scheduleSaving) return;
    setOneOffFormOpen(false);
    setEditingOneOffSchedule(null);
    setScheduleError('');
  }, [scheduleSaving]);

  const handleScheduleSave = useCallback(
    async (data: ScheduleFormData) => {
      if (!selectedClassroomId) return;

      try {
        setScheduleSaving(true);
        setScheduleError('');
        if (editingSchedule) {
          await trpc.schedules.update.mutate({
            id: editingSchedule.id,
            dayOfWeek: data.dayOfWeek,
            startTime: data.startTime,
            endTime: data.endTime,
            groupId: data.groupId,
          });
        } else {
          await trpc.schedules.create.mutate({
            classroomId: selectedClassroomId,
            dayOfWeek: data.dayOfWeek,
            startTime: data.startTime,
            endTime: data.endTime,
            groupId: data.groupId,
          });
        }

        await fetchSchedules(selectedClassroomId);
        await onSchedulesUpdated?.();
        setScheduleFormOpen(false);
        setEditingSchedule(null);
        setScheduleFormDay(undefined);
        setScheduleFormStartTime(undefined);
      } catch (err: unknown) {
        reportError('Failed to save schedule:', err);
        setScheduleError(formatScheduleError(err, 'Unable to save schedule'));
      } finally {
        setScheduleSaving(false);
      }
    },
    [selectedClassroomId, editingSchedule, fetchSchedules, onSchedulesUpdated]
  );

  const handleOneOffScheduleSave = useCallback(
    async (data: OneOffScheduleFormData) => {
      if (!selectedClassroomId) return;

      try {
        setScheduleSaving(true);
        setScheduleError('');

        if (editingOneOffSchedule) {
          await trpc.schedules.updateOneOff.mutate({
            id: editingOneOffSchedule.id,
            startAt: data.startAt,
            endAt: data.endAt,
            groupId: data.groupId,
          });
        } else {
          await trpc.schedules.createOneOff.mutate({
            classroomId: selectedClassroomId,
            startAt: data.startAt,
            endAt: data.endAt,
            groupId: data.groupId,
          });
        }

        await fetchSchedules(selectedClassroomId);
        await onSchedulesUpdated?.();
        setOneOffFormOpen(false);
        setEditingOneOffSchedule(null);
      } catch (err: unknown) {
        reportError('Failed to save one-off schedule:', err);
        setScheduleError(formatScheduleError(err, 'Unable to save schedule'));
      } finally {
        setScheduleSaving(false);
      }
    },
    [selectedClassroomId, editingOneOffSchedule, fetchSchedules, onSchedulesUpdated]
  );

  const requestScheduleDelete = useCallback((schedule: ScheduleWithPermissions) => {
    setScheduleError('');
    setScheduleDeleteTarget({
      id: schedule.id,
      label: `${schedule.startTime}–${schedule.endTime}`,
    });
  }, []);

  const requestOneOffScheduleDelete = useCallback((schedule: OneOffScheduleWithPermissions) => {
    setScheduleError('');
    setScheduleDeleteTarget({
      id: schedule.id,
      label: `${new Date(schedule.startAt).toLocaleString()}–${new Date(schedule.endAt).toLocaleString()}`,
    });
  }, []);

  const closeScheduleDelete = useCallback(() => {
    if (scheduleSaving) return;
    setScheduleDeleteTarget(null);
    setScheduleError('');
  }, [scheduleSaving]);

  const handleConfirmDeleteSchedule = useCallback(async () => {
    if (!selectedClassroomId || !scheduleDeleteTarget) return;

    try {
      setScheduleSaving(true);
      setScheduleError('');
      await trpc.schedules.delete.mutate({ id: scheduleDeleteTarget.id });
      await fetchSchedules(selectedClassroomId);
      await onSchedulesUpdated?.();
      setScheduleDeleteTarget(null);
    } catch (err: unknown) {
      reportError('Failed to delete schedule:', err);
      setScheduleError(formatScheduleError(err, 'Unable to delete schedule'));
    } finally {
      setScheduleSaving(false);
    }
  }, [selectedClassroomId, scheduleDeleteTarget, fetchSchedules, onSchedulesUpdated]);

  return {
    schedules,
    oneOffSchedules,
    loadingSchedules,
    scheduleFormOpen,
    editingSchedule,
    scheduleFormDay,
    scheduleFormStartTime,
    oneOffFormOpen,
    editingOneOffSchedule,
    scheduleSaving,
    scheduleError,
    scheduleDeleteTarget,
    openScheduleCreate,
    openScheduleEdit,
    closeScheduleForm,
    openOneOffScheduleCreate,
    openOneOffScheduleEdit,
    closeOneOffScheduleForm,
    handleScheduleSave,
    handleOneOffScheduleSave,
    requestScheduleDelete,
    requestOneOffScheduleDelete,
    closeScheduleDelete,
    handleConfirmDeleteSchedule,
  };
};
