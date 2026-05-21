import React from 'react';
import { AlertCircle, Clock, Loader2, Plus } from 'lucide-react';
import type { OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../../types';
import WeeklyCalendar from '../WeeklyCalendar';
import { resolveGroupLike, type GroupLike } from '../groups/GroupLabel';
import { useOpenPathI18n } from '../../i18n/product-i18n';
import { cn } from '../../lib/utils';

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
  fillAvailable?: boolean;
}

function formatOneOffDateLabel(value: string, locale: string): string {
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) {
    return value;
  }

  return parsed.toLocaleString(locale, {
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
  fillAvailable = false,
}: ClassroomScheduleCardProps) {
  const { locale, t } = useOpenPathI18n();

  return (
    <div
      className={cn(
        'bg-white border border-slate-200 rounded-lg p-6 flex-1 flex flex-col shadow-sm',
        fillAvailable ? 'lg:min-h-0 lg:overflow-hidden' : ''
      )}
    >
      <div className="flex justify-between items-center mb-4">
        <h3 className="font-semibold text-slate-900 flex items-center gap-2">
          <Clock size={18} className="text-slate-500" />
          {t('classrooms.schedule.title')}
        </h3>
        <div className="flex gap-2">
          <button
            onClick={onOpenOneOffScheduleCreate}
            className="bg-slate-100 hover:bg-slate-200 text-slate-800 px-3 py-1.5 rounded-lg text-sm flex items-center gap-2 transition-colors shadow-sm font-medium border border-slate-200"
          >
            <Plus size={16} /> {t('classrooms.schedule.oneOff')}
          </button>
          <button
            onClick={() => onOpenScheduleCreate()}
            className="bg-blue-600 hover:bg-blue-700 text-white px-3 py-1.5 rounded-lg text-sm flex items-center gap-2 transition-colors shadow-sm font-medium"
          >
            <Plus size={16} /> {t('classrooms.schedule.weekly')}
          </button>
        </div>
      </div>

      {loadingSchedules ? (
        <div className="flex items-center justify-center py-10 text-slate-500 text-sm">
          <Loader2 className="w-5 h-5 animate-spin text-slate-400" />
          <span className="ml-2">{t('classrooms.schedule.loading')}</span>
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
            fillAvailable={fillAvailable}
          />
          <p className="mt-3 text-xs text-slate-500">{t('classrooms.schedule.tip')}</p>

          <div
            className={cn(
              'mt-5 pt-4 border-t border-slate-200',
              fillAvailable ? 'lg:max-h-56 lg:overflow-y-auto' : ''
            )}
          >
            <div className="flex items-center justify-between mb-3">
              <h4 className="text-sm font-semibold text-slate-900">
                {t('classrooms.schedule.oneOffAssignments')}
              </h4>
              <button
                onClick={onOpenOneOffScheduleCreate}
                className="text-xs font-semibold text-slate-700 hover:text-slate-900 bg-slate-100 hover:bg-slate-200 border border-slate-200 px-2.5 py-1.5 rounded-lg transition-colors"
              >
                <span className="inline-flex items-center gap-1">
                  <Plus size={14} /> {t('classrooms.schedule.new')}
                </span>
              </button>
            </div>

            {sortedOneOffSchedules.length === 0 ? (
              <p className="text-xs text-slate-500">{t('classrooms.schedule.noneOneOff')}</p>
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
                        ? t('classrooms.schedule.reservedBy', {
                            teacherName: schedule.teacherName,
                          })
                        : t('classrooms.schedule.reservedByAnotherTeacher');

                  return (
                    <div
                      key={schedule.id}
                      className="flex items-center justify-between gap-3 p-3 rounded-lg border border-slate-200 bg-slate-50/50"
                    >
                      <div className="min-w-0">
                        <p className="text-sm font-semibold text-slate-900 truncate">{groupName}</p>
                        <p className="text-xs text-slate-500 truncate">
                          {formatOneOffDateLabel(schedule.startAt, locale)} –{' '}
                          {formatOneOffDateLabel(schedule.endAt, locale)}
                          {schedule.teacherName ? ` · ${schedule.teacherName}` : ''}
                        </p>
                      </div>

                      {schedule.canEdit && (
                        <div className="flex items-center gap-2 shrink-0">
                          <button
                            onClick={() => onOpenOneOffScheduleEdit(schedule)}
                            className="text-xs font-semibold text-slate-700 hover:text-slate-900 px-2 py-1 rounded-lg hover:bg-white border border-transparent hover:border-slate-200 transition-colors"
                          >
                            {t('classrooms.schedule.edit')}
                          </button>
                          <button
                            onClick={() => onRequestOneOffScheduleDelete(schedule)}
                            className="text-xs font-semibold text-red-600 hover:text-red-700 px-2 py-1 rounded-lg hover:bg-red-50 border border-transparent hover:border-red-100 transition-colors"
                          >
                            {t('classrooms.schedule.delete')}
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
