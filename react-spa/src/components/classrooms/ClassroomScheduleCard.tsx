import React from 'react';
import { AlertCircle, Clock, Loader2, Plus } from 'lucide-react';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../types';
import WeeklyCalendar from '../WeeklyCalendar';
import { resolveGroupLike, type GroupLike } from '../groups/GroupLabel';

interface CalendarGroupDisplay {
  id: string;
  displayName: string;
}

interface ClassroomScheduleCardProps {
  admin: boolean;
  calendarGroupsForDisplay: CalendarGroupDisplay[];
  groupById: ReadonlyMap<string, GroupLike>;
  schedules: ScheduleWithPermissions[];
  sortedOneOffSchedules: OneOffScheduleWithPermissions[];
  loadingSchedules: boolean;
  scheduleError: string;
  onOpenScheduleCreate: (dayOfWeek?: number, startTime?: string) => void;
  onOpenScheduleEdit: (schedule: ScheduleWithPermissions) => void;
  onRequestScheduleDelete: (schedule: ScheduleWithPermissions) => void;
  onOpenOneOffScheduleCreate: () => void;
  onOpenOneOffScheduleEdit: (schedule: OneOffScheduleWithPermissions) => void;
  onRequestOneOffScheduleDelete: (schedule: OneOffScheduleWithPermissions) => void;
}

function formatOneOffDateLabel(value: string): string {
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) {
    return value;
  }

  return parsed.toLocaleString(undefined, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export default function ClassroomScheduleCard({
  admin,
  calendarGroupsForDisplay,
  groupById,
  schedules,
  sortedOneOffSchedules,
  loadingSchedules,
  scheduleError,
  onOpenScheduleCreate,
  onOpenScheduleEdit,
  onRequestScheduleDelete,
  onOpenOneOffScheduleCreate,
  onOpenOneOffScheduleEdit,
  onRequestOneOffScheduleDelete,
}: ClassroomScheduleCardProps) {
  return (
    <div className="bg-white border border-slate-200 rounded-lg p-6 flex-1 flex flex-col shadow-sm">
      <div className="flex justify-between items-center mb-4">
        <h3 className="font-semibold text-slate-900 flex items-center gap-2">
          <Clock size={18} className="text-slate-500" />
          Classroom Schedule
        </h3>
        <div className="flex gap-2">
          <button
            onClick={onOpenOneOffScheduleCreate}
            className="bg-slate-100 hover:bg-slate-200 text-slate-800 px-3 py-1.5 rounded-lg text-sm flex items-center gap-2 transition-colors shadow-sm font-medium border border-slate-200"
          >
            <Plus size={16} /> One-off
          </button>
          <button
            onClick={() => onOpenScheduleCreate()}
            className="bg-blue-600 hover:bg-blue-700 text-white px-3 py-1.5 rounded-lg text-sm flex items-center gap-2 transition-colors shadow-sm font-medium"
          >
            <Plus size={16} /> Weekly
          </button>
        </div>
      </div>

      {loadingSchedules ? (
        <div className="flex items-center justify-center py-10 text-slate-500 text-sm">
          <Loader2 className="w-5 h-5 animate-spin text-slate-400" />
          <span className="ml-2">Loading schedules...</span>
        </div>
      ) : (
        <>
          {scheduleError && (
            <div className="mb-3 p-3 bg-red-50 text-red-600 text-sm rounded-lg border border-red-100 flex items-center gap-2">
              <AlertCircle size={16} />
              <span>{scheduleError}</span>
            </div>
          )}
          <WeeklyCalendar
            schedules={schedules}
            groups={calendarGroupsForDisplay}
            onAddClick={(dayOfWeek, startTime) => onOpenScheduleCreate(dayOfWeek, startTime)}
            onEditClick={onOpenScheduleEdit}
            onDeleteClick={onRequestScheduleDelete}
          />
          <p className="mt-3 text-xs text-slate-500">
            Tip: click a cell to create a block. You can edit or delete your blocks on hover.
          </p>

          <div className="mt-5 pt-4 border-t border-slate-200">
            <div className="flex items-center justify-between mb-3">
              <h4 className="text-sm font-semibold text-slate-900">One-off assignments</h4>
              <button
                onClick={onOpenOneOffScheduleCreate}
                className="text-xs font-semibold text-slate-700 hover:text-slate-900 bg-slate-100 hover:bg-slate-200 border border-slate-200 px-2.5 py-1.5 rounded-lg transition-colors"
              >
                <span className="inline-flex items-center gap-1">
                  <Plus size={14} /> New
                </span>
              </button>
            </div>

            {sortedOneOffSchedules.length === 0 ? (
              <p className="text-xs text-slate-500">No one-off assignments.</p>
            ) : (
              <div className="space-y-2">
                {sortedOneOffSchedules.map((schedule) => {
                  const group = resolveGroupLike({
                    groupId: schedule.groupId,
                    groupById,
                    displayName: schedule.groupDisplayName,
                  });
                  const groupName = group
                    ? (group.displayName ?? group.name)
                    : schedule.canEdit || admin
                      ? schedule.groupId
                      : schedule.teacherName
                        ? `Reserved by ${schedule.teacherName}`
                        : 'Reserved by another teacher';

                  return (
                    <div
                      key={schedule.id}
                      className="flex items-center justify-between gap-3 p-3 rounded-lg border border-slate-200 bg-slate-50/50"
                    >
                      <div className="min-w-0">
                        <p className="text-sm font-semibold text-slate-900 truncate">{groupName}</p>
                        <p className="text-xs text-slate-500 truncate">
                          {formatOneOffDateLabel(schedule.startAt)} –{' '}
                          {formatOneOffDateLabel(schedule.endAt)}
                          {schedule.teacherName ? ` · ${schedule.teacherName}` : ''}
                        </p>
                      </div>

                      {schedule.canEdit && (
                        <div className="flex items-center gap-2 shrink-0">
                          <button
                            onClick={() => onOpenOneOffScheduleEdit(schedule)}
                            className="text-xs font-semibold text-slate-700 hover:text-slate-900 px-2 py-1 rounded-lg hover:bg-white border border-transparent hover:border-slate-200 transition-colors"
                          >
                            Edit
                          </button>
                          <button
                            onClick={() => onRequestOneOffScheduleDelete(schedule)}
                            className="text-xs font-semibold text-red-600 hover:text-red-700 px-2 py-1 rounded-lg hover:bg-red-50 border border-transparent hover:border-red-100 transition-colors"
                          >
                            Delete
                          </button>
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}
