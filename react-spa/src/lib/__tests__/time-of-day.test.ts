import { describe, expect, it } from 'vitest';
import { SCHEDULE_TIME_STEP_MINUTES as SHARED_STEP } from '@openpath/shared/schedule-time';
import {
  SCHEDULE_TIME_STEP_MINUTES,
  buildTimeOfDayOptions,
  compareTimeOfDay,
  formatMinutesToTimeOfDay,
  parseTimeOfDayToMinutes,
  roundTimeOfDayDown,
} from '../time-of-day';

describe('time-of-day', () => {
  it('keeps the SPA time step in sync with @openpath/shared', () => {
    // The SPA mirrors the constant locally to avoid pulling the shared barrel
    // into the bundle; this test (not shipped) guards they stay equal.
    expect(SCHEDULE_TIME_STEP_MINUTES).toBe(SHARED_STEP);
  });

  it('parses HH:MM to minutes and validates bounds', () => {
    expect(parseTimeOfDayToMinutes('00:00')).toBe(0);
    expect(parseTimeOfDayToMinutes('23:59')).toBe(23 * 60 + 59);
    expect(parseTimeOfDayToMinutes('24:00')).toBeNull();
    expect(parseTimeOfDayToMinutes('12:60')).toBeNull();
    expect(parseTimeOfDayToMinutes('xx')).toBeNull();
  });

  it('formats minutes to HH:MM', () => {
    expect(formatMinutesToTimeOfDay(0)).toBe('00:00');
    expect(formatMinutesToTimeOfDay(9 * 60 + 5)).toBe('09:05');
  });

  it('compares times by minute values', () => {
    expect(compareTimeOfDay('09:00', '10:00')).toBeLessThan(0);
    expect(compareTimeOfDay('10:00', '09:00')).toBeGreaterThan(0);
    expect(compareTimeOfDay('bad', '09:00')).toBeNull();
  });

  it('rounds down to a step', () => {
    expect(roundTimeOfDayDown('10:07', 15)).toBe('10:00');
    expect(roundTimeOfDayDown('10:59', 15)).toBe('10:45');
    expect(roundTimeOfDayDown('bad', 15)).toBeNull();
  });

  it('builds selectable time options', () => {
    const opts = buildTimeOfDayOptions({ startHour: 7, endHour: 8, stepMinutes: 30 });
    expect(opts).toEqual(['07:00', '07:30', '08:00']);
  });
});
