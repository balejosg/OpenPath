import React, { useState, useEffect } from 'react';
import { Loader2, AlertCircle } from 'lucide-react';
import type { ScheduleWithPermissions } from '../types';
import {
  buildTimeOfDayOptions,
  compareTimeOfDay,
  formatMinutesToTimeOfDay,
  parseTimeOfDayToMinutes,
  roundTimeOfDayDown,
} from '../lib/time-of-day';
import { GroupSelect } from './groups/GroupSelect';
import { isGroupEnabled, type GroupLike } from './groups/GroupLabel';
import { Modal } from './ui/Modal';
import { useT } from '../i18n/product-i18n';

const TIME_OPTIONS = buildTimeOfDayOptions({ startHour: 7, endHour: 21, stepMinutes: 15 });

function normalizeDayOfWeek(value: unknown): number | null {
  const n = typeof value === 'number' ? value : typeof value === 'string' ? Number(value) : NaN;
  if (!Number.isInteger(n)) return null;
  if (n < 1 || n > 5) return null;
  return n;
}

interface ScheduleFormModalProps {
  /** null = create mode; populated = edit mode */
  schedule: ScheduleWithPermissions | null;
  /** Pre-filled day when creating from calendar click */
  defaultDay?: number;
  /** Pre-filled start time when creating from calendar click */
  defaultStartTime?: string;
  groups: GroupLike[];
  saving: boolean;
  error: string;
  onSave: (data: {
    dayOfWeek: number;
    startTime: string;
    endTime: string;
    groupId: string;
  }) => void;
  onClose: () => void;
}

const ScheduleFormModal: React.FC<ScheduleFormModalProps> = ({
  schedule,
  defaultDay,
  defaultStartTime,
  groups,
  saving,
  error,
  onSave,
  onClose,
}) => {
  const t = useT();
  const isEdit = schedule !== null;

  const DAY_OPTIONS = [
    { value: 1 as const, label: t('teacher.day.monday') },
    { value: 2 as const, label: t('teacher.day.tuesday') },
    { value: 3 as const, label: t('teacher.day.wednesday') },
    { value: 4 as const, label: t('teacher.day.thursday') },
    { value: 5 as const, label: t('teacher.day.friday') },
  ];

  const roundedDefaultStart = defaultStartTime
    ? (roundTimeOfDayDown(defaultStartTime, 15) ?? defaultStartTime)
    : null;
  const defaultStart = schedule?.startTime ?? roundedDefaultStart ?? '08:00';
  const defaultStartMinutes = parseTimeOfDayToMinutes(defaultStart) ?? 8 * 60;
  const defaultEnd = formatMinutesToTimeOfDay(Math.min(defaultStartMinutes + 60, 21 * 60));

  const [dayOfWeek, setDayOfWeek] = useState<number | null>(
    normalizeDayOfWeek(schedule?.dayOfWeek) ?? normalizeDayOfWeek(defaultDay) ?? null
  );
  const [startTime, setStartTime] = useState<string>(
    schedule?.startTime ?? roundedDefaultStart ?? '08:00'
  );
  const [endTime, setEndTime] = useState<string>(schedule?.endTime ?? defaultEnd);
  const [groupId, setGroupId] = useState<string>(
    schedule?.groupId ?? groups.find((g) => isGroupEnabled(g))?.id ?? ''
  );
  const [localError, setLocalError] = useState('');

  // Sync error prop
  useEffect(() => {
    if (error) setLocalError(error);
  }, [error]);

  useEffect(() => {
    if (schedule?.groupId) return;
    if (groupId) return;
    const firstEnabled = groups.find((g) => isGroupEnabled(g));
    if (firstEnabled) setGroupId(firstEnabled.id);
  }, [groups, groupId, schedule?.groupId]);

  const handleSubmit = () => {
    setLocalError('');
    if (dayOfWeek === null) {
      setLocalError(t('scheduleForm.errorSelectDay'));
      return;
    }
    if (!groupId) {
      setLocalError(t('scheduleForm.errorSelectGroup'));
      return;
    }

    const cmp = compareTimeOfDay(startTime, endTime);
    if (cmp === null || cmp >= 0) {
      setLocalError(t('scheduleForm.errorEndTime'));
      return;
    }
    onSave({ dayOfWeek, startTime, endTime, groupId });
  };

  const handleClose = () => {
    if (saving) return;
    onClose();
  };

  return (
    <Modal
      isOpen
      onClose={handleClose}
      title={isEdit ? t('scheduleForm.titleEdit') : t('scheduleForm.titleNew')}
      className="max-w-md"
    >
      <div className="space-y-4">
        {/* Day */}
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            {t('scheduleForm.labelDay')}
          </label>
          <div className="flex gap-1.5">
            {DAY_OPTIONS.map((d) => (
              <button
                key={d.value}
                type="button"
                onClick={() => setDayOfWeek(d.value)}
                className={`flex-1 py-2 rounded-lg text-sm font-medium border transition-colors ${
                  dayOfWeek === d.value
                    ? 'bg-blue-600 text-white border-blue-600'
                    : 'bg-white text-slate-600 border-slate-200 hover:border-blue-300 hover:bg-blue-50'
                }`}
              >
                {d.label.slice(0, 3)}
              </button>
            ))}
          </div>
        </div>

        {/* Time range */}
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label
              htmlFor="schedule-start"
              className="block text-sm font-medium text-slate-700 mb-1"
            >
              {t('scheduleForm.labelStartTime')}
            </label>
            <select
              id="schedule-start"
              value={startTime}
              onChange={(e) => setStartTime(e.target.value)}
              className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
            >
              {TIME_OPTIONS.map((time) => (
                <option key={time} value={time}>
                  {time}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="schedule-end" className="block text-sm font-medium text-slate-700 mb-1">
              {t('scheduleForm.labelEndTime')}
            </label>
            <select
              id="schedule-end"
              value={endTime}
              onChange={(e) => setEndTime(e.target.value)}
              className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
            >
              {TIME_OPTIONS.filter((time) => time > startTime).map((time) => (
                <option key={time} value={time}>
                  {time}
                </option>
              ))}
            </select>
          </div>
        </div>

        {/* Group */}
        <div>
          <label htmlFor="schedule-group" className="block text-sm font-medium text-slate-700 mb-1">
            {t('scheduleForm.labelRuleGroup')}
          </label>
          <GroupSelect
            id="schedule-group"
            value={groupId}
            onChange={setGroupId}
            groups={groups}
            includeNoneOption={false}
            inactiveBehavior={schedule ? 'disable' : 'hide'}
            disabled={saving || groups.length === 0}
            emptyLabel={t('scheduleForm.emptyGroups')}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none disabled:bg-slate-50 disabled:text-slate-500"
          />
        </div>

        {/* Error */}
        {localError && (
          <p className="text-red-500 text-sm flex items-center gap-1">
            <AlertCircle size={14} /> {localError}
          </p>
        )}

        {/* Actions */}
        <div className="flex gap-3 pt-2">
          <button
            onClick={handleClose}
            disabled={saving}
            className="flex-1 px-4 py-2 border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50 transition-colors disabled:opacity-50"
          >
            {t('common.cancel')}
          </button>
          <button
            onClick={handleSubmit}
            disabled={saving}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors font-medium disabled:opacity-50 flex items-center justify-center gap-2"
          >
            {saving && <Loader2 size={16} className="animate-spin" />}
            {isEdit ? t('common.saveChanges') : t('scheduleForm.createSchedule')}
          </button>
        </div>
      </div>
    </Modal>
  );
};

export default ScheduleFormModal;
