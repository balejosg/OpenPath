import React from 'react';
import { Edit2, Plus, Trash2 } from 'lucide-react';
import { parseTimeOfDayToMinutes } from '../../lib/time-of-day';
import { resolveGroupDisplayName } from '../groups/GroupLabel';
import {
  END_HOUR,
  GROUP_COLORS,
  HOURS,
  RESERVED_COLOR,
  START_HOUR,
  minutesToPx,
  type WeeklyCalendarDayColumnProps,
} from './shared';
import { useT } from '../../i18n/product-i18n';

export const WeeklyCalendarDayColumn: React.FC<WeeklyCalendarDayColumnProps> = ({
  dayKey,
  dayFull,
  daySchedules,
  groupColorMap,
  groupNameMap,
  rowHeight,
  onAddClick,
  onEditClick,
  onDeleteClick,
}) => {
  const t = useT();
  return (
    <div className="relative border-l border-slate-200">
      {HOURS.map((h) => (
        <div
          key={h}
          className="absolute w-full border-t border-slate-100 group/cell cursor-pointer"
          style={{ top: (h - START_HOUR) * rowHeight, height: rowHeight }}
          onClick={() => onAddClick(dayKey, `${String(h).padStart(2, '0')}:00`)}
          role="button"
          tabIndex={0}
          aria-label={t('calendar.cell.addAriaLabel', {
            day: dayFull,
            time: `${String(h).padStart(2, '0')}:00`,
          })}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              onAddClick(dayKey, `${String(h).padStart(2, '0')}:00`);
            }
          }}
        >
          <div className="opacity-0 group-hover/cell:opacity-100 transition-opacity flex items-center justify-center h-full">
            <Plus size={14} className="text-slate-300" />
          </div>
        </div>
      ))}

      {daySchedules.map((s) => {
        const startAbs = parseTimeOfDayToMinutes(s.startTime);
        const endAbs = parseTimeOfDayToMinutes(s.endTime);
        if (startAbs === null || endAbs === null) return null;

        const startMin = startAbs - START_HOUR * 60;
        const endMin = endAbs - START_HOUR * 60;
        const visibleStartMin = Math.max(startMin, 0);
        const visibleEndMin = Math.min(endMin, (END_HOUR - START_HOUR) * 60);
        const durationMin = visibleEndMin - visibleStartMin;
        if (durationMin <= 0) return null;

        const top = minutesToPx(visibleStartMin, rowHeight);
        const height = minutesToPx(durationMin, rowHeight);
        const colorIdx = groupColorMap.get(s.groupId) ?? 0;
        const canEdit = s.canEdit;
        const color = canEdit ? (GROUP_COLORS[colorIdx] ?? GROUP_COLORS[0]) : RESERVED_COLOR;
        const knownGroupName = groupNameMap.get(s.groupId) ?? s.groupDisplayName ?? null;
        const group = knownGroupName
          ? { id: s.groupId, name: knownGroupName, displayName: knownGroupName }
          : null;
        const groupName = resolveGroupDisplayName({
          groupId: s.groupId,
          group,
          source: 'schedule',
          revealUnknownId: canEdit,
          t,
        });

        return (
          <div
            key={s.id}
            className={`absolute inset-x-1 rounded-md border ${color.bg} ${color.border} ${color.hover} overflow-hidden z-10 transition-colors group/block ${
              canEdit ? 'cursor-pointer' : 'cursor-default opacity-90'
            }`}
            style={{ top, height: Math.max(height, 20) }}
            onClick={(e) => {
              e.stopPropagation();
              if (canEdit) onEditClick(s);
            }}
            onKeyDown={(e) => {
              if (!canEdit) return;
              if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                onEditClick(s);
              }
            }}
            role={canEdit ? 'button' : undefined}
            tabIndex={canEdit ? 0 : -1}
            aria-label={
              canEdit
                ? `Edit ${groupName} ${s.startTime}-${s.endTime}`
                : `${groupName} ${s.startTime}-${s.endTime}`
            }
            data-testid={`schedule-block-${s.id}`}
            title={`${groupName}\n${s.startTime} – ${s.endTime}${s.teacherName ? `\n${s.teacherName}` : ''}`}
          >
            <div className="px-1.5 py-0.5 h-full flex flex-col justify-between">
              <div className="flex items-start justify-between gap-0.5">
                <span className={`text-[10px] font-semibold leading-tight truncate ${color.text}`}>
                  {groupName}
                </span>
                {s.canEdit && (
                  <div className="flex gap-0.5 opacity-0 group-hover/block:opacity-100 transition-opacity shrink-0">
                    <button
                      className="p-0.5 rounded hover:bg-white/60"
                      onClick={(e) => {
                        e.stopPropagation();
                        onEditClick(s);
                      }}
                      title={t('common.edit')}
                    >
                      <Edit2 size={10} className={color.text} />
                    </button>
                    <button
                      className="p-0.5 rounded hover:bg-red-100"
                      onClick={(e) => {
                        e.stopPropagation();
                        onDeleteClick(s);
                      }}
                      title={t('common.delete')}
                    >
                      <Trash2 size={10} className="text-red-500" />
                    </button>
                  </div>
                )}
              </div>
              {height >= 32 && (
                <span className={`text-[9px] ${color.text} opacity-70`}>
                  {s.startTime} – {s.endTime}
                </span>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
};
