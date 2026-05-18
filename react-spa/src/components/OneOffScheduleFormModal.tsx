import React, { useEffect, useMemo, useState } from 'react';
import { AlertCircle, Loader2 } from 'lucide-react';

import type { OneOffScheduleWithPermissions } from '../types';
import { isGroupEnabled, type GroupLike } from './groups/GroupLabel';
import { GroupSelect } from './groups/GroupSelect';
import { Modal } from './ui/Modal';

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

function roundUpToQuarterHour(date: Date): Date {
  const d = new Date(date);
  d.setSeconds(0, 0);
  const minutes = d.getMinutes();
  const remainder = minutes % 15;
  if (remainder !== 0) {
    d.setMinutes(minutes + (15 - remainder));
  }
  return d;
}

function toDateTimeLocalValue(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}T${pad2(
    date.getHours()
  )}:${pad2(date.getMinutes())}`;
}

function parseDateTimeLocalValue(value: string): Date | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value.trim()) ?? null;
  if (!match) return null;

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);

  if (!Number.isInteger(year) || year < 1970 || year > 9999) return null;
  if (!Number.isInteger(month) || month < 1 || month > 12) return null;
  if (!Number.isInteger(day) || day < 1 || day > 31) return null;
  if (!Number.isInteger(hour) || hour < 0 || hour > 23) return null;
  if (!Number.isInteger(minute) || minute < 0 || minute > 59) return null;

  const d = new Date(year, month - 1, day, hour, minute, 0, 0);
  if (!Number.isFinite(d.getTime())) return null;
  return d;
}

interface OneOffScheduleFormModalProps {
  /** null = create mode; populated = edit mode */
  schedule: OneOffScheduleWithPermissions | null;
  groups: GroupLike[];
  saving: boolean;
  error: string;
  onSave: (data: { startAt: string; endAt: string; groupId: string }) => void;
  onClose: () => void;
}

const OneOffScheduleFormModal: React.FC<OneOffScheduleFormModalProps> = ({
  schedule,
  groups,
  saving,
  error,
  onSave,
  onClose,
}) => {
  const isEdit = schedule !== null;

  const defaults = useMemo(() => {
    if (schedule) {
      const start = new Date(schedule.startAt);
      const end = new Date(schedule.endAt);
      return {
        start: Number.isFinite(start.getTime()) ? start : roundUpToQuarterHour(new Date()),
        end: Number.isFinite(end.getTime()) ? end : new Date(Date.now() + 60 * 60 * 1000),
      };
    }

    const start = roundUpToQuarterHour(new Date());
    const end = new Date(start.getTime() + 60 * 60 * 1000);
    return { start, end };
  }, [schedule]);

  const [startAt, setStartAt] = useState<string>(toDateTimeLocalValue(defaults.start));
  const [endAt, setEndAt] = useState<string>(toDateTimeLocalValue(defaults.end));
  const [groupId, setGroupId] = useState<string>(
    schedule?.groupId ?? groups.find((g) => isGroupEnabled(g))?.id ?? ''
  );
  const [localError, setLocalError] = useState('');

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

    if (!groupId) {
      setLocalError('Select a group');
      return;
    }

    const start = parseDateTimeLocalValue(startAt);
    const end = parseDateTimeLocalValue(endAt);
    if (!start) {
      setLocalError('Select a start date/time');
      return;
    }
    if (!end) {
      setLocalError('Select an end date/time');
      return;
    }

    if (end.getTime() <= start.getTime()) {
      setLocalError('End date/time must be after start date/time');
      return;
    }

    onSave({ startAt: start.toISOString(), endAt: end.toISOString(), groupId });
  };

  const handleClose = () => {
    if (saving) return;
    onClose();
  };

  return (
    <Modal
      isOpen
      onClose={handleClose}
      title={isEdit ? 'Edit One-Off Assignment' : 'New One-Off Assignment'}
      className="max-w-md"
    >
      <div className="space-y-4">
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label htmlFor="oneoff-start" className="block text-sm font-medium text-slate-700 mb-1">
              Start
            </label>
            <input
              id="oneoff-start"
              type="datetime-local"
              step={900}
              value={startAt}
              onChange={(e) => setStartAt(e.target.value)}
              className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
            />
          </div>
          <div>
            <label htmlFor="oneoff-end" className="block text-sm font-medium text-slate-700 mb-1">
              End
            </label>
            <input
              id="oneoff-end"
              type="datetime-local"
              step={900}
              value={endAt}
              onChange={(e) => setEndAt(e.target.value)}
              className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
            />
          </div>
        </div>

        <div>
          <label htmlFor="oneoff-group" className="block text-sm font-medium text-slate-700 mb-1">
            Rule Group
          </label>
          <GroupSelect
            id="oneoff-group"
            value={groupId}
            onChange={setGroupId}
            groups={groups}
            includeNoneOption={false}
            inactiveBehavior={schedule ? 'disable' : 'hide'}
            disabled={saving || groups.length === 0}
            emptyLabel="No groups available"
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none disabled:bg-slate-50 disabled:text-slate-500"
          />
        </div>

        {localError && (
          <p className="text-red-500 text-sm flex items-center gap-1">
            <AlertCircle size={14} /> {localError}
          </p>
        )}

        <div className="flex gap-3 pt-2">
          <button
            onClick={handleClose}
            disabled={saving}
            className="flex-1 px-4 py-2 border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50 transition-colors disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={handleSubmit}
            disabled={saving}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors font-medium disabled:opacity-50 flex items-center justify-center gap-2"
          >
            {saving && <Loader2 size={16} className="animate-spin" />}
            {isEdit ? 'Save Changes' : 'Create Assignment'}
          </button>
        </div>
      </div>
    </Modal>
  );
};

export default OneOffScheduleFormModal;
