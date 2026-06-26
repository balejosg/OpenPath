import { useQueries } from '@tanstack/react-query';

import type { ClassroomListModel } from '../lib/classrooms';
import { useT } from '../i18n/product-i18n';
import { trpc } from '../lib/trpc';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../types';

export interface TeacherDashboardSchedulesResult {
  weeklySchedules: ScheduleWithPermissions[];
  oneOffSchedules: OneOffScheduleWithPermissions[];
  loading: boolean;
  error: string | null;
  refetchSchedules: () => Promise<void>;
}

export function useTeacherDashboardSchedules(
  classrooms: readonly ClassroomListModel[]
): TeacherDashboardSchedulesResult {
  const t = useT();
  const scheduleQueries = useQueries({
    queries: classrooms.map((classroom) => ({
      queryKey: ['teacher-dashboard', 'classroom-schedules', classroom.id],
      queryFn: () => trpc.schedules.getByClassroom.query({ classroomId: classroom.id }),
      staleTime: 30_000,
    })),
  });

  const weeklySchedules = scheduleQueries.flatMap((query) =>
    (query.data?.schedules ?? []).filter((schedule) => schedule.isMine)
  );
  const oneOffSchedules = scheduleQueries.flatMap((query) =>
    (query.data?.oneOffSchedules ?? []).filter((schedule) => schedule.isMine)
  );

  const loading = scheduleQueries.some((query) => query.isPending);
  const error = scheduleQueries.some((query) => query.error)
    ? t('teacherDashboard.error.loadSchedules')
    : null;

  async function refetchSchedules(): Promise<void> {
    await Promise.all(scheduleQueries.map((query) => query.refetch()));
  }

  return {
    weeklySchedules,
    oneOffSchedules,
    loading,
    error,
    refetchSchedules,
  };
}
