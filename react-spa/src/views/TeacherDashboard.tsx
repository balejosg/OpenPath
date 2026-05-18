import React, { useMemo, useState } from 'react';

import OneOffScheduleFormModal from '../components/OneOffScheduleFormModal';
import ScheduleFormModal from '../components/ScheduleFormModal';
import { TeacherActiveClassroomsCard } from '../components/teacher/TeacherActiveClassroomsCard';
import { TeacherClassroomControlCard } from '../components/teacher/TeacherClassroomControlCard';
import { TeacherDashboardCalendar } from '../components/teacher/TeacherDashboardCalendar';
import { TeacherDashboardHero } from '../components/teacher/TeacherDashboardHero';
import { TeacherScheduleDetailPanel } from '../components/teacher/TeacherScheduleDetailPanel';
import { TeacherTodayFocusPanel } from '../components/teacher/TeacherTodayFocusPanel';
import {
  buildTeacherScheduleEntries,
  getTeacherScheduleFocus,
  getWeekMonday,
} from '../components/teacher/teacher-schedule-model';
import { DangerConfirmDialog, ConfirmDialog } from '../components/ui/ConfirmDialog';
import type { GroupLike } from '../components/groups/GroupLabel';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../types';
import { useTeacherDashboardViewModel } from '../hooks/useTeacherDashboardViewModel';
import { useTeacherScheduleCommands } from '../hooks/useTeacherScheduleCommands';

interface TeacherDashboardProps {
  onNavigateToRules?: (group: { id: string; name: string }) => void;
}

function toEditableGroups(groups: readonly GroupLike[]): GroupLike[] {
  return groups.map((group) => ({
    ...group,
    enabled: group.enabled ?? true,
  }));
}

const TeacherDashboard: React.FC<TeacherDashboardProps> = ({ onNavigateToRules }) => {
  const viewModel = useTeacherDashboardViewModel();
  const [weekMonday, setWeekMonday] = useState(() => getWeekMonday(new Date()));

  const entries = useMemo(
    () =>
      buildTeacherScheduleEntries({
        weeklySchedules: viewModel.weeklySchedules,
        oneOffSchedules: viewModel.oneOffSchedules,
        classroomNameMap: viewModel.classroomNameMap,
        groupNameMap: viewModel.groupDisplayNameMap,
        weekMonday,
      }),
    [
      viewModel.weeklySchedules,
      viewModel.oneOffSchedules,
      viewModel.classroomNameMap,
      viewModel.groupDisplayNameMap,
      weekMonday,
    ]
  );
  const focus = useMemo(() => getTeacherScheduleFocus(entries, new Date()), [entries]);
  const editableGroups = useMemo(() => toEditableGroups(viewModel.groups), [viewModel.groups]);
  const scheduleCommands = useTeacherScheduleCommands({
    refetchClassrooms: viewModel.refetchClassrooms,
    refetchMySchedules: viewModel.refetchMySchedules,
    onNavigateToRules,
  });

  const currentWeeklySchedule =
    scheduleCommands.editingEntry?.kind === 'weekly'
      ? (scheduleCommands.editingEntry.schedule as ScheduleWithPermissions)
      : null;
  const currentOneOffSchedule =
    scheduleCommands.editingEntry?.kind === 'one_off'
      ? (scheduleCommands.editingEntry.schedule as OneOffScheduleWithPermissions)
      : null;

  return (
    <div className="space-y-6">
      <TeacherDashboardHero
        classroomsLoading={viewModel.classroomsLoading}
        activeCount={viewModel.activeClassrooms.length}
        classroomsError={viewModel.classroomsError}
        onRetry={() => void viewModel.refetchClassrooms()}
      />

      <TeacherTodayFocusPanel
        focus={focus}
        loading={viewModel.schedulesLoading}
        error={viewModel.schedulesError}
        onRetry={() => void viewModel.refetchMySchedules()}
        onOpenClassroom={scheduleCommands.handleOpenClassroom}
        onOpenRules={scheduleCommands.handleOpenRules}
        onTakeControl={(entry) => void scheduleCommands.handleTakeControl(entry)}
        onReleaseClassroom={(entry) => void scheduleCommands.handleReleaseClassroom(entry)}
        onSelectEntry={scheduleCommands.setSelectedEntry}
      />

      <TeacherDashboardCalendar
        entries={entries}
        loading={viewModel.schedulesLoading}
        error={viewModel.schedulesError}
        weekMonday={weekMonday}
        onPrevWeek={() =>
          setWeekMonday((current) => {
            const next = new Date(current);
            next.setDate(next.getDate() - 7);
            return getWeekMonday(next);
          })
        }
        onNextWeek={() =>
          setWeekMonday((current) => {
            const next = new Date(current);
            next.setDate(next.getDate() + 7);
            return getWeekMonday(next);
          })
        }
        onToday={() => setWeekMonday(getWeekMonday(new Date()))}
        onRetry={() => void viewModel.refetchMySchedules()}
        onSelectEntry={scheduleCommands.setSelectedEntry}
      />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <TeacherClassroomControlCard viewModel={viewModel} onNavigateToRules={onNavigateToRules} />
        <TeacherActiveClassroomsCard viewModel={viewModel} />
      </div>

      <TeacherScheduleDetailPanel
        entry={scheduleCommands.selectedEntry}
        isSaving={scheduleCommands.scheduleSaving}
        error={scheduleCommands.scheduleError}
        onClose={scheduleCommands.closeDetailPanel}
        onOpenClassroom={scheduleCommands.handleOpenClassroom}
        onOpenRules={scheduleCommands.handleOpenRules}
        onTakeControl={(entry) => void scheduleCommands.handleTakeControl(entry)}
        onReleaseClassroom={(entry) => void scheduleCommands.handleReleaseClassroom(entry)}
        onEditSchedule={scheduleCommands.handleEditSchedule}
        onDeleteSchedule={scheduleCommands.handleDeleteSchedule}
      />

      <ConfirmDialog
        isOpen={viewModel.controlConfirm !== null}
        title="Confirm change"
        confirmLabel={viewModel.controlConfirm?.nextGroupId ? 'Replace' : 'Release Classroom'}
        cancelLabel="Cancel"
        isLoading={viewModel.controlLoading}
        errorMessage={viewModel.controlConfirm ? (viewModel.controlError ?? undefined) : undefined}
        onClose={() => {
          viewModel.setControlConfirm(null);
          viewModel.setControlError(null);
        }}
        onConfirm={async () => {
          if (!viewModel.controlConfirm) return;
          const ok = await viewModel.applyControlChange(
            viewModel.controlConfirm.classroomId,
            viewModel.controlConfirm.nextGroupId
          );
          if (!ok) return;
          viewModel.setControlConfirm(null);
        }}
      >
        <p className="text-sm text-slate-600">
          The classroom already has a manually applied policy (
          <strong>{viewModel.controlConfirm?.currentName}</strong>).
        </p>
        <p className="text-sm text-slate-600">
          {viewModel.controlConfirm?.nextGroupId ? 'Replace with' : 'Release (no group)'}:{' '}
          <strong>{viewModel.controlConfirm?.nextName}</strong>?
        </p>
      </ConfirmDialog>

      {currentWeeklySchedule ? (
        <ScheduleFormModal
          key={currentWeeklySchedule.id}
          schedule={currentWeeklySchedule}
          groups={editableGroups}
          saving={scheduleCommands.scheduleSaving}
          error={scheduleCommands.scheduleError}
          onSave={(data) => void scheduleCommands.handleSaveWeeklySchedule(data)}
          onClose={scheduleCommands.closeEditSchedule}
        />
      ) : null}

      {currentOneOffSchedule ? (
        <OneOffScheduleFormModal
          key={currentOneOffSchedule.id}
          schedule={currentOneOffSchedule}
          groups={editableGroups}
          saving={scheduleCommands.scheduleSaving}
          error={scheduleCommands.scheduleError}
          onSave={(data) => void scheduleCommands.handleSaveOneOffSchedule(data)}
          onClose={scheduleCommands.closeEditSchedule}
        />
      ) : null}

      {scheduleCommands.deleteEntry ? (
        <DangerConfirmDialog
          isOpen
          title="Delete schedule"
          confirmLabel="Delete"
          cancelLabel="Cancel"
          isLoading={scheduleCommands.scheduleSaving}
          errorMessage={scheduleCommands.scheduleError || undefined}
          onClose={scheduleCommands.closeDeleteSchedule}
          onConfirm={() => void scheduleCommands.handleConfirmDeleteSchedule()}
        >
          <div className="space-y-2 text-sm text-slate-600">
            <p>
              Delete <strong>{scheduleCommands.deleteEntry.label}</strong>?
            </p>
            <p>Type: {scheduleCommands.deleteEntry.kind === 'one_off' ? 'One-off' : 'Weekly'}</p>
            <p>
              Schedule: {scheduleCommands.deleteEntry.startTime} -{' '}
              {scheduleCommands.deleteEntry.endTime}
            </p>
          </div>
        </DangerConfirmDialog>
      ) : null}
    </div>
  );
};

export default TeacherDashboard;
