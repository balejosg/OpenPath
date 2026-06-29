interface TimeParts {
  hours: number;
  minutes: number;
  seconds: number;
}

/**
 * Granularity (in minutes) that schedule start/end times must align to.
 *
 * This is the single source of truth for the allowed minute step across the
 * SPA time inputs and the backend validators. Classes may start/end on any
 * multiple of this value (e.g. :00, :05, :20, :35).
 */
export const SCHEDULE_TIME_STEP_MINUTES = 5;

/**
 * Normalize a time string to HH:MM.
 *
 * Accepts values like "09:30" or "09:30:00" (DB may include seconds).
 * For unknown formats, returns the input unchanged.
 */
export function normalizeTimeHHMM(time: string): string {
  const match = /^([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$/.exec(time);
  if (!match) return time;
  const hh = match[1];
  const mm = match[2];
  if (hh === undefined || mm === undefined) return time;
  return `${hh}:${mm}`;
}

/**
 * Parse a time string (HH:MM) to minutes since midnight.
 *
 * Returns NaN for invalid input.
 */
export function parseTimeToMinutes(time: string): number {
  const parts = time.split(':');
  const hh = parts[0];
  const mm = parts[1];
  const h = Number(hh);
  const m = Number(mm);
  if (!Number.isInteger(h) || !Number.isInteger(m)) return Number.NaN;
  if (h < 0 || h > 23 || m < 0 || m > 59) return Number.NaN;
  return h * 60 + m;
}

/**
 * Strict time parser used for validation.
 *
 * Accepts HH:MM or HH:MM:SS.
 */
export function parseTimeParts(time: string): TimeParts {
  const match = /^([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$/.exec(time);
  if (!match) {
    throw new Error('Invalid time format. Use HH:MM (24h)');
  }

  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3] ?? '0');

  return { hours, minutes, seconds };
}

// Name kept for historical/back-compat reasons; the allowed step is now
// SCHEDULE_TIME_STEP_MINUTES (5), not a quarter hour.
export function assertQuarterHourTime(time: string): void {
  const { minutes, seconds } = parseTimeParts(time);
  if (seconds !== 0) {
    throw new Error('Time must not include seconds');
  }
  if (minutes % SCHEDULE_TIME_STEP_MINUTES !== 0) {
    throw new Error(`Time must be in ${String(SCHEDULE_TIME_STEP_MINUTES)}-minute increments`);
  }
}

// Name kept for historical/back-compat reasons; the allowed step is now
// SCHEDULE_TIME_STEP_MINUTES (5), not a quarter hour.
export function assertQuarterHourInstant(date: Date): void {
  if (!Number.isFinite(date.getTime())) {
    throw new Error('Invalid date');
  }

  if (date.getUTCSeconds() !== 0 || date.getUTCMilliseconds() !== 0) {
    throw new Error('Time must not include seconds');
  }

  if (date.getUTCMinutes() % SCHEDULE_TIME_STEP_MINUTES !== 0) {
    throw new Error(`Time must be in ${String(SCHEDULE_TIME_STEP_MINUTES)}-minute increments`);
  }
}
