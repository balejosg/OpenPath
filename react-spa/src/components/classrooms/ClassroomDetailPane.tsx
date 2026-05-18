import React from 'react';
import { Plus } from 'lucide-react';
import type {
  Classroom,
  ClassroomExemption,
  CurrentGroupSource,
  OneOffScheduleWithPermissions,
  ScheduleWithPermissions,
} from '../../types';
import type { GroupLike } from '../groups/GroupLabel';
import ClassroomConfigCard from './ClassroomConfigCard';
import ClassroomMachinesCard from './ClassroomMachinesCard';
import ClassroomScheduleCard from './ClassroomScheduleCard';

interface CalendarGroupDisplay {
  id: string;
  displayName: string;
}

interface ClassroomDetailPaneProps {
  admin: boolean;
  allowedGroups: readonly GroupLike[];
  calendarGroupsForDisplay: CalendarGroupDisplay[];
  classroomConfigError: string;
  activeGroupSelectValue: string;
  defaultGroupSelectValue: string;
  selectedClassroom: Classroom | null;
  selectedClassroomSource: CurrentGroupSource;
  groupById: ReadonlyMap<string, GroupLike>;
  schedules: ScheduleWithPermissions[];
  sortedOneOffSchedules: OneOffScheduleWithPermissions[];
  loadingSchedules: boolean;
  scheduleError: string;
  activeSchedule: ScheduleWithPermissions | OneOffScheduleWithPermissions | null;
  exemptionByMachineId: ReadonlyMap<string, ClassroomExemption>;
  exemptionMutating: Partial<Record<string, boolean>>;
  exemptionsError: string | null;
  loadingExemptions: boolean;
  enrollModalLoadingToken: boolean;
  onOpenNewModal: () => void;
  onOpenDeleteDialog: () => void;
  onRequestActiveGroupChange: (next: string) => void;
  onDefaultGroupChange: (next: string) => void | Promise<void>;
  onOpenEnrollModal: () => void | Promise<void>;
  onCreateExemption: (machineId: string) => void | Promise<void>;
  onCreateOperationalExemption: (
    machineId: string,
    durationHours: number,
    reason: string
  ) => void | Promise<void>;
  onDeleteExemption: (machineId: string) => void | Promise<void>;
  onOpenScheduleCreate: (dayOfWeek?: number, startTime?: string) => void;
  onOpenScheduleEdit: (schedule: ScheduleWithPermissions) => void;
  onRequestScheduleDelete: (schedule: ScheduleWithPermissions) => void;
  onOpenOneOffScheduleCreate: () => void;
  onOpenOneOffScheduleEdit: (schedule: OneOffScheduleWithPermissions) => void;
  onRequestOneOffScheduleDelete: (schedule: OneOffScheduleWithPermissions) => void;
}

export default function ClassroomDetailPane({
  admin,
  allowedGroups,
  calendarGroupsForDisplay,
  classroomConfigError,
  activeGroupSelectValue,
  defaultGroupSelectValue,
  selectedClassroom,
  selectedClassroomSource,
  groupById,
  schedules,
  sortedOneOffSchedules,
  loadingSchedules,
  scheduleError,
  activeSchedule,
  exemptionByMachineId,
  exemptionMutating,
  exemptionsError,
  loadingExemptions,
  enrollModalLoadingToken,
  onOpenNewModal,
  onOpenDeleteDialog,
  onRequestActiveGroupChange,
  onDefaultGroupChange,
  onOpenEnrollModal,
  onCreateExemption,
  onCreateOperationalExemption,
  onDeleteExemption,
  onOpenScheduleCreate,
  onOpenScheduleEdit,
  onRequestScheduleDelete,
  onOpenOneOffScheduleCreate,
  onOpenOneOffScheduleEdit,
  onRequestOneOffScheduleDelete,
}: ClassroomDetailPaneProps) {
  if (!selectedClassroom) {
    return (
      <div
        data-testid="classrooms-empty-state"
        className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm"
      >
        <h2 className="text-2xl font-bold text-slate-900 mb-1">No classrooms</h2>
        <p className="text-slate-500 text-sm">
          {admin
            ? 'Create a classroom to view its settings and status.'
            : 'Select a classroom to view its settings and status.'}
        </p>
        {admin && (
          <button
            onClick={onOpenNewModal}
            className="mt-6 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm inline-flex items-center gap-2 transition-colors shadow-sm font-medium"
          >
            <Plus size={16} /> Create classroom
          </button>
        )}
      </div>
    );
  }

  return (
    <>
      <ClassroomConfigCard
        admin={admin}
        allowedGroups={allowedGroups}
        classroomConfigError={classroomConfigError}
        activeGroupSelectValue={activeGroupSelectValue}
        defaultGroupSelectValue={defaultGroupSelectValue}
        classroom={selectedClassroom}
        classroomSource={selectedClassroomSource}
        groupById={groupById}
        onOpenDeleteDialog={onOpenDeleteDialog}
        onRequestActiveGroupChange={onRequestActiveGroupChange}
        onDefaultGroupChange={onDefaultGroupChange}
      />

      <ClassroomMachinesCard
        admin={admin}
        classroom={selectedClassroom}
        hasActiveSchedule={activeSchedule !== null}
        exemptionByMachineId={exemptionByMachineId}
        exemptionMutating={exemptionMutating}
        exemptionsError={exemptionsError}
        loadingExemptions={loadingExemptions}
        enrollModalLoadingToken={enrollModalLoadingToken}
        onOpenEnrollModal={onOpenEnrollModal}
        onCreateExemption={onCreateExemption}
        onCreateOperationalExemption={onCreateOperationalExemption}
        onDeleteExemption={onDeleteExemption}
      />

      <ClassroomScheduleCard
        admin={admin}
        calendarGroupsForDisplay={calendarGroupsForDisplay}
        groupById={groupById}
        schedules={schedules}
        sortedOneOffSchedules={sortedOneOffSchedules}
        loadingSchedules={loadingSchedules}
        scheduleError={scheduleError}
        onOpenScheduleCreate={onOpenScheduleCreate}
        onOpenScheduleEdit={onOpenScheduleEdit}
        onRequestScheduleDelete={onRequestScheduleDelete}
        onOpenOneOffScheduleCreate={onOpenOneOffScheduleCreate}
        onOpenOneOffScheduleEdit={onOpenOneOffScheduleEdit}
        onRequestOneOffScheduleDelete={onRequestOneOffScheduleDelete}
      />
    </>
  );
}
