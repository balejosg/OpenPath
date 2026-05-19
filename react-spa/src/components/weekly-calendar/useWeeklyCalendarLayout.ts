import { useMemo } from 'react';
import type { ScheduleWithPermissions } from '../../types';
import { useOpenPathI18n } from '../../i18n/product-i18n';
import type { WeeklyCalendarGroupInfo } from './shared';
import { DAYS, GROUP_COLORS } from './shared';

export function useWeeklyCalendarLayout(
  schedules: ScheduleWithPermissions[],
  groups: WeeklyCalendarGroupInfo[]
) {
  const { locale } = useOpenPathI18n();
  const groupColorMap = useMemo(() => {
    const uniqueIds = [...new Set(schedules.map((s) => s.groupId))];
    const map = new Map<string, number>();
    uniqueIds.forEach((id, i) => map.set(id, i % GROUP_COLORS.length));
    return map;
  }, [schedules]);

  const groupNameMap = useMemo(() => {
    const map = new Map<string, string>();
    groups.forEach((g) => map.set(g.id, g.displayName));
    return map;
  }, [groups]);

  const byDay = useMemo(() => {
    const map = new Map<number, ScheduleWithPermissions[]>();
    for (const s of schedules) {
      const list = map.get(s.dayOfWeek) ?? [];
      list.push(s);
      map.set(s.dayOfWeek, list);
    }
    return map;
  }, [schedules]);

  const weekDates = useMemo(() => {
    const today = new Date();
    const dow = today.getDay();
    const mondayOffset = dow === 0 ? -6 : 1 - dow;
    const monday = new Date(today);
    monday.setDate(today.getDate() + mondayOffset);
    return DAYS.map((_, i) => {
      const d = new Date(monday);
      d.setDate(monday.getDate() + i);
      return d.getDate();
    });
  }, []);

  const weekMonthLabel = useMemo(() => {
    const today = new Date();
    const dow = today.getDay();
    const mondayOffset = dow === 0 ? -6 : 1 - dow;
    const monday = new Date(today);
    monday.setDate(today.getDate() + mondayOffset);
    const friday = new Date(monday);
    friday.setDate(monday.getDate() + 4);
    const fmt = new Intl.DateTimeFormat(locale, { month: 'long' });
    const mon = fmt.format(monday);
    const fri = fmt.format(friday);
    const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
    return mon === fri ? cap(mon) : `${cap(mon)} – ${cap(fri)}`;
  }, [locale]);

  const todayKey = useMemo(() => {
    const d = new Date().getDay();
    return d >= 1 && d <= 5 ? d : null;
  }, []);

  return {
    groupColorMap,
    groupNameMap,
    byDay,
    weekDates,
    weekMonthLabel,
    todayKey,
  };
}
