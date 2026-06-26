import { useCallback, useState } from 'react';

import type { TeacherScheduleEntry } from '../components/teacher/teacher-schedule-model';
import { resolveTrpcErrorMessage } from '../lib/error-utils';
import { useT } from '../i18n/product-i18n';
import { reportError as defaultReportError } from '../lib/reportError';
import { trpc as defaultTrpc } from '../lib/trpc';

interface WeeklyScheduleFormData {
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

interface TeacherScheduleCommandsTrpc {
  classrooms: {
    setActiveGroup: {
      mutate: (input: { id: string; groupId: string | null }) => Promise<unknown> | undefined;
    };
  };
  schedules: {
    update: {
      mutate: (input: {
        id: string;
        dayOfWeek: number;
        startTime: string;
        endTime: string;
        groupId: string;
      }) => Promise<unknown> | undefined;
    };
    updateOneOff: {
      mutate: (input: {
        id: string;
        startAt: string;
        endAt: string;
        groupId: string;
      }) => Promise<unknown> | undefined;
    };
    delete: {
      mutate: (input: { id: string }) => Promise<unknown> | undefined;
    };
  };
}

interface UseTeacherScheduleCommandsParams {
  refetchClassrooms: () => Promise<unknown>;
  refetchMySchedules: () => Promise<unknown>;
  onNavigateToRules?: (group: { id: string; name: string }) => void;
  trpcClient?: TeacherScheduleCommandsTrpc;
  reportError?: (message: string, err: unknown) => void;
}

export function formatTeacherScheduleError(err: unknown, fallback: string): string {
  const raw = err instanceof Error ? err.message : '';
  return resolveTrpcErrorMessage(err, {
    conflict: 'That time slot is already reserved',
    fallback: raw || fallback,
  });
}

export function resolveTeacherScheduleGroupName(entry: TeacherScheduleEntry): string {
  return entry.schedule.groupDisplayName ?? entry.groupName;
}

export function useTeacherScheduleCommands({
  refetchClassrooms,
  refetchMySchedules,
  onNavigateToRules,
  trpcClient = defaultTrpc,
  reportError = defaultReportError,
}: UseTeacherScheduleCommandsParams) {
  const t = useT();
  const [selectedEntry, setSelectedEntry] = useState<TeacherScheduleEntry | null>(null);
  const [editingEntry, setEditingEntry] = useState<TeacherScheduleEntry | null>(null);
  const [deleteEntry, setDeleteEntry] = useState<TeacherScheduleEntry | null>(null);
  const [scheduleSaving, setScheduleSaving] = useState(false);
  const [scheduleError, setScheduleError] = useState('');

  const clearTransientState = useCallback(() => {
    setScheduleError('');
  }, []);

  const refreshDashboard = useCallback(async () => {
    await Promise.all([refetchClassrooms(), refetchMySchedules()]);
  }, [refetchClassrooms, refetchMySchedules]);

  const handleOpenRules = useCallback(
    (entry: TeacherScheduleEntry) => {
      onNavigateToRules?.({
        id: entry.schedule.groupId,
        name: resolveTeacherScheduleGroupName(entry),
      });
    },
    [onNavigateToRules]
  );

  const handleOpenClassroom = useCallback((entry: TeacherScheduleEntry) => {
    setSelectedEntry(entry);
  }, []);

  const handleTakeControl = useCallback(
    async (entry: TeacherScheduleEntry) => {
      setScheduleSaving(true);
      setScheduleError('');
      try {
        await trpcClient.classrooms.setActiveGroup.mutate({
          id: entry.classroomId,
          groupId: entry.schedule.groupId,
        });
        await refreshDashboard();
      } catch (err) {
        reportError('Failed to apply active group:', err);
        setScheduleError(t('scheduleCommands.error.applyGroup'));
      } finally {
        setScheduleSaving(false);
      }
    },
    [refreshDashboard, reportError, t, trpcClient]
  );

  const handleReleaseClassroom = useCallback(
    async (entry: TeacherScheduleEntry) => {
      setScheduleSaving(true);
      setScheduleError('');
      try {
        await trpcClient.classrooms.setActiveGroup.mutate({
          id: entry.classroomId,
          groupId: null,
        });
        await refreshDashboard();
      } catch (err) {
        reportError('Failed to release classroom:', err);
        setScheduleError(t('scheduleCommands.error.applyGroup'));
      } finally {
        setScheduleSaving(false);
      }
    },
    [refreshDashboard, reportError, t, trpcClient]
  );

  const handleEditSchedule = useCallback(
    (entry: TeacherScheduleEntry) => {
      clearTransientState();
      setEditingEntry(entry);
    },
    [clearTransientState]
  );

  const handleDeleteSchedule = useCallback(
    (entry: TeacherScheduleEntry) => {
      clearTransientState();
      setDeleteEntry(entry);
    },
    [clearTransientState]
  );

  const closeEditSchedule = useCallback(() => {
    if (scheduleSaving) return;
    setEditingEntry(null);
    setScheduleError('');
  }, [scheduleSaving]);

  const closeDeleteSchedule = useCallback(() => {
    if (scheduleSaving) return;
    setDeleteEntry(null);
    setScheduleError('');
  }, [scheduleSaving]);

  const closeDetailPanel = useCallback(() => {
    setSelectedEntry(null);
    setScheduleError('');
  }, []);

  const handleSaveWeeklySchedule = useCallback(
    async (data: WeeklyScheduleFormData) => {
      if (editingEntry?.kind !== 'weekly') return;

      setScheduleSaving(true);
      setScheduleError('');
      try {
        await trpcClient.schedules.update.mutate({
          id: editingEntry.schedule.id,
          dayOfWeek: data.dayOfWeek,
          startTime: data.startTime,
          endTime: data.endTime,
          groupId: data.groupId,
        });
        await refreshDashboard();
        setEditingEntry(null);
      } catch (err) {
        reportError('Failed to save schedule:', err);
        setScheduleError(formatTeacherScheduleError(err, t('scheduleCommands.error.saveSchedule')));
      } finally {
        setScheduleSaving(false);
      }
    },
    [editingEntry, refreshDashboard, reportError, t, trpcClient]
  );

  const handleSaveOneOffSchedule = useCallback(
    async (data: OneOffScheduleFormData) => {
      if (editingEntry?.kind !== 'one_off') return;

      setScheduleSaving(true);
      setScheduleError('');
      try {
        await trpcClient.schedules.updateOneOff.mutate({
          id: editingEntry.schedule.id,
          startAt: data.startAt,
          endAt: data.endAt,
          groupId: data.groupId,
        });
        await refreshDashboard();
        setEditingEntry(null);
      } catch (err) {
        reportError('Failed to save one-off schedule:', err);
        setScheduleError(formatTeacherScheduleError(err, t('scheduleCommands.error.saveSchedule')));
      } finally {
        setScheduleSaving(false);
      }
    },
    [editingEntry, refreshDashboard, reportError, t, trpcClient]
  );

  const handleConfirmDeleteSchedule = useCallback(async () => {
    if (!deleteEntry) return;

    setScheduleSaving(true);
    setScheduleError('');
    try {
      await trpcClient.schedules.delete.mutate({ id: deleteEntry.schedule.id });
      await refreshDashboard();
      setDeleteEntry(null);
      setSelectedEntry(null);
    } catch (err) {
      reportError('Failed to delete schedule:', err);
      setScheduleError(formatTeacherScheduleError(err, t('scheduleCommands.error.deleteSchedule')));
    } finally {
      setScheduleSaving(false);
    }
  }, [deleteEntry, refreshDashboard, reportError, t, trpcClient]);

  return {
    selectedEntry,
    setSelectedEntry,
    editingEntry,
    deleteEntry,
    scheduleSaving,
    scheduleError,
    handleOpenRules,
    handleOpenClassroom,
    handleTakeControl,
    handleReleaseClassroom,
    handleEditSchedule,
    handleDeleteSchedule,
    closeEditSchedule,
    closeDeleteSchedule,
    closeDetailPanel,
    handleSaveWeeklySchedule,
    handleSaveOneOffSchedule,
    handleConfirmDeleteSchedule,
  };
}
