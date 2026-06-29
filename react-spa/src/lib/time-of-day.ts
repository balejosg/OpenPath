/**
 * Allowed minute step for schedule times in the SPA.
 *
 * Mirror of `SCHEDULE_TIME_STEP_MINUTES` in `@openpath/shared` (the backend
 * source of truth). Kept as a local literal to avoid pulling the shared barrel
 * (zod schemas, etc.) into the SPA bundle just for one constant. A unit test
 * asserts this stays equal to the shared value.
 */
export const SCHEDULE_TIME_STEP_MINUTES = 5;

export function parseTimeOfDayToMinutes(value: string): number | null {
  const [hRaw, mRaw] = value.split(':');
  const h = Number(hRaw);
  const m = Number(mRaw);
  if (!Number.isInteger(h) || !Number.isInteger(m)) return null;
  if (h < 0 || h > 23) return null;
  if (m < 0 || m > 59) return null;
  return h * 60 + m;
}

export function formatMinutesToTimeOfDay(totalMinutes: number): string {
  const minutes = Math.max(0, Math.floor(totalMinutes));
  const h = Math.floor(minutes / 60) % 24;
  const m = minutes % 60;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
}

export function compareTimeOfDay(a: string, b: string): number | null {
  const am = parseTimeOfDayToMinutes(a);
  const bm = parseTimeOfDayToMinutes(b);
  if (am === null || bm === null) return null;
  return am - bm;
}

/** Round down to the nearest step (minutes). Returns null on invalid input. */
export function roundTimeOfDayDown(value: string, stepMinutes: number): string | null {
  const minutes = parseTimeOfDayToMinutes(value);
  if (minutes === null) return null;
  if (!Number.isInteger(stepMinutes) || stepMinutes <= 0) return null;

  const rounded = Math.floor(minutes / stepMinutes) * stepMinutes;
  return formatMinutesToTimeOfDay(rounded);
}

export function buildTimeOfDayOptions(params: {
  startHour: number;
  endHour: number;
  stepMinutes: number;
}): string[] {
  const startHour = params.startHour;
  const endHour = params.endHour;
  const stepMinutes = params.stepMinutes;

  if (!Number.isInteger(startHour) || !Number.isInteger(endHour)) return [];
  if (!Number.isInteger(stepMinutes) || stepMinutes <= 0) return [];
  if (startHour < 0 || startHour > 23) return [];
  if (endHour < 0 || endHour > 23) return [];
  if (endHour < startHour) return [];

  const opts: string[] = [];
  for (let h = startHour; h <= endHour; h++) {
    for (let m = 0; m < 60; m += stepMinutes) {
      if (h === endHour && m > 0) break;
      opts.push(`${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`);
    }
  }
  return opts;
}
