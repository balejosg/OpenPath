import React from 'react';

import { Modal } from '../ui/Modal';
import type { TeacherScheduleEntry } from './teacher-schedule-model';

export interface TeacherScheduleDetailPanelProps {
  entry: TeacherScheduleEntry | null;
  isSaving: boolean;
  error: string;
  onClose: () => void;
  onOpenClassroom: (entry: TeacherScheduleEntry) => void;
  onOpenRules: (entry: TeacherScheduleEntry) => void;
  onTakeControl: (entry: TeacherScheduleEntry) => void;
  onReleaseClassroom: (entry: TeacherScheduleEntry) => void;
  onEditSchedule: (entry: TeacherScheduleEntry) => void;
  onDeleteSchedule: (entry: TeacherScheduleEntry) => void;
}

const DAY_LABELS: Record<1 | 2 | 3 | 4 | 5, string> = {
  1: 'Lunes',
  2: 'Martes',
  3: 'Wednesday',
  4: 'Jueves',
  5: 'Viernes',
};

export const TeacherScheduleDetailPanel: React.FC<TeacherScheduleDetailPanelProps> = ({
  entry,
  isSaving,
  error,
  onClose,
  onOpenClassroom,
  onOpenRules,
  onTakeControl,
  onReleaseClassroom,
  onEditSchedule,
  onDeleteSchedule,
}) => {
  if (entry === null) {
    return null;
  }

  const scheduleType = entry.kind === 'one_off' ? 'One-off' : 'Weekly';
  const dayLabel = entry.kind === 'weekly' ? DAY_LABELS[entry.dayOfWeek] : null;
  const timeRange = `${entry.startTime}-${entry.endTime}`;
  const secondaryDisabled = isSaving || !entry.canEdit;

  return (
    <Modal isOpen onClose={onClose} title="Schedule details" className="max-w-2xl">
      <div className="space-y-6">
        <div className="space-y-3">
          <h3 className="text-xl font-semibold text-slate-900">{entry.label}</h3>
          <dl className="grid gap-3 text-sm text-slate-700 sm:grid-cols-2">
            <div>
              <dt className="font-medium text-slate-500">Classroom</dt>
              <dd className="mt-1">{entry.classroomName}</dd>
            </div>
            <div>
              <dt className="font-medium text-slate-500">Group</dt>
              <dd className="mt-1">{entry.groupName}</dd>
            </div>
            <div>
              <dt className="font-medium text-slate-500">Type</dt>
              <dd className="mt-1">{scheduleType}</dd>
            </div>
            {dayLabel ? (
              <div>
                <dt className="font-medium text-slate-500">Day</dt>
                <dd className="mt-1">{dayLabel}</dd>
              </div>
            ) : null}
            <div>
              <dt className="font-medium text-slate-500">Schedule</dt>
              <dd className="mt-1">{timeRange}</dd>
            </div>
          </dl>
        </div>

        <div className="space-y-3">
          <h4 className="text-sm font-semibold uppercase tracking-wide text-slate-500">
            Class actions
          </h4>
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              disabled={isSaving}
              onClick={() => onOpenClassroom(entry)}
              className="inline-flex items-center justify-center rounded-lg bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
            >
              Go to classroom
            </button>
            <button
              type="button"
              disabled={isSaving}
              onClick={() => onOpenRules(entry)}
              className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50"
            >
              View rules
            </button>
            <button
              type="button"
              disabled={isSaving}
              onClick={() => onTakeControl(entry)}
              className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50"
            >
              Take control
            </button>
            <button
              type="button"
              disabled={isSaving}
              onClick={() => onReleaseClassroom(entry)}
              className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50"
            >
              Release classroom
            </button>
          </div>
        </div>

        <div className="space-y-3 border-t border-slate-100 pt-4">
          <h4 className="text-sm font-semibold uppercase tracking-wide text-slate-500">
            Schedule management
          </h4>
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              disabled={secondaryDisabled}
              onClick={() => onEditSchedule(entry)}
              className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50"
            >
              Edit schedule
            </button>
            <button
              type="button"
              disabled={secondaryDisabled}
              onClick={() => onDeleteSchedule(entry)}
              className="inline-flex items-center justify-center rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm font-medium text-red-700 hover:bg-red-100 disabled:opacity-50"
            >
              Delete schedule
            </button>
          </div>
          {error ? <p className="text-sm text-red-600">{error}</p> : null}
        </div>
      </div>
    </Modal>
  );
};
