import React from 'react';
import { Loader2 } from 'lucide-react';

import { useT } from '../../i18n/product-i18n';
import type { TeacherScheduleEntry, TeacherScheduleFocus } from './teacher-schedule-model';

interface TeacherTodayFocusPanelProps {
  focus: TeacherScheduleFocus;
  loading: boolean;
  error: string | null;
  onRetry: () => void;
  onOpenClassroom: (entry: TeacherScheduleEntry) => void;
  onOpenRules: (entry: TeacherScheduleEntry) => void;
  onTakeControl: (entry: TeacherScheduleEntry) => void;
  onReleaseClassroom: (entry: TeacherScheduleEntry) => void;
  onSelectEntry: (entry: TeacherScheduleEntry) => void;
}

export const TeacherTodayFocusPanel: React.FC<TeacherTodayFocusPanelProps> = ({
  focus,
  loading,
  error,
  onRetry,
  onOpenClassroom,
  onOpenRules,
  onTakeControl,
  onReleaseClassroom,
  onSelectEntry,
}) => {
  const t = useT();

  if (loading) {
    return (
      <section className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm">
        <div className="flex items-center gap-2 text-sm text-slate-500">
          <Loader2 size={16} className="animate-spin text-slate-400" />
          <span>{t('teacher.schedule.loading')}</span>
        </div>
      </section>
    );
  }

  if (error) {
    return (
      <section className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-sm text-red-600">{error}</p>
          <button
            type="button"
            onClick={onRetry}
            className="inline-flex items-center justify-center rounded-lg border border-red-200 px-3 py-2 text-sm font-medium text-red-700 hover:bg-red-50"
          >
            {t('common.retry')}
          </button>
        </div>
      </section>
    );
  }

  const focusEntry = focus.currentEntry ?? focus.nextEntry;
  const headline = focus.currentEntry
    ? t('teacher.today.currentClass')
    : t('teacher.today.nextClass');
  const remainingEntries = focus.todayEntries.filter((entry) => entry.id !== focusEntry?.id);

  return (
    <section className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm">
      <div className="flex flex-col gap-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h3 className="text-lg font-semibold text-slate-800">{t('teacher.today.title')}</h3>
            <p className="mt-1 text-sm text-slate-500">{t('teacher.today.body')}</p>
          </div>
        </div>

        {focusEntry ? (
          <div className="rounded-xl border border-slate-200 bg-slate-50 p-4 sm:p-5">
            <p className="text-sm font-medium uppercase tracking-wide text-slate-500">{headline}</p>
            <div className="mt-3 flex flex-col gap-3">
              <div className="flex flex-wrap items-center gap-2">
                <h4 className="text-xl font-semibold text-slate-900">{focusEntry.label}</h4>
                {focusEntry.kind === 'one_off' ? (
                  <span className="rounded-full border border-amber-200 bg-amber-50 px-2.5 py-1 text-xs font-medium text-amber-700">
                    {t('teacher.schedule.oneOff')}
                  </span>
                ) : null}
              </div>
              <p className="text-sm font-medium text-slate-600">
                {focusEntry.startTime}-{focusEntry.endTime}
              </p>
              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={() => onOpenClassroom(focusEntry)}
                  className="inline-flex items-center justify-center rounded-lg bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700"
                >
                  {t('teacher.today.goToClassroom')}
                </button>
                <button
                  type="button"
                  onClick={() => onOpenRules(focusEntry)}
                  className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
                >
                  {t('teacher.today.viewRules')}
                </button>
                <button
                  type="button"
                  onClick={() => onTakeControl(focusEntry)}
                  className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
                >
                  {t('teacher.today.takeControl')}
                </button>
                <button
                  type="button"
                  onClick={() => onReleaseClassroom(focusEntry)}
                  className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
                >
                  {t('teacher.today.releaseClassroom')}
                </button>
                <button
                  type="button"
                  onClick={() => onSelectEntry(focusEntry)}
                  className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
                >
                  {t('teacher.today.viewDetails')}
                </button>
              </div>
            </div>
          </div>
        ) : (
          <div className="rounded-xl border border-dashed border-slate-300 bg-slate-50 p-4 text-sm text-slate-600">
            {t('teacher.today.noMoreClasses')}
          </div>
        )}

        <div>
          <h4 className="text-sm font-semibold uppercase tracking-wide text-slate-500">
            {t('teacher.today.today')}
          </h4>
          {remainingEntries.length > 0 ? (
            <ul className="mt-3 space-y-2">
              {remainingEntries.map((entry) => (
                <li key={entry.id} className="rounded-lg border border-slate-200 px-3 py-3">
                  <button
                    type="button"
                    onClick={() => onSelectEntry(entry)}
                    className="flex w-full items-start justify-between gap-3 text-left"
                  >
                    <span className="text-sm font-medium text-slate-700">
                      {entry.startTime}-{entry.endTime}
                    </span>
                    <span className="flex-1 text-sm text-slate-800">{entry.label}</span>
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <p className="mt-3 text-sm text-slate-500">{t('teacher.today.noPending')}</p>
          )}
        </div>
      </div>
    </section>
  );
};
