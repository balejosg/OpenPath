import { describe, it } from 'node:test';
import assert from 'node:assert';

import {
  SCHEDULE_TIME_STEP_MINUTES,
  normalizeTimeHHMM,
  parseTimeToMinutes,
  parseTimeParts,
  assertQuarterHourTime,
  assertQuarterHourInstant,
} from '../src/schedule-time.js';

describe('schedule-time', () => {
  describe('normalizeTimeHHMM', () => {
    it('keeps HH:MM unchanged', () => {
      assert.strictEqual(normalizeTimeHHMM('09:30'), '09:30');
    });

    it('trims seconds from HH:MM:SS', () => {
      assert.strictEqual(normalizeTimeHHMM('09:30:00'), '09:30');
    });

    it('returns unknown formats unchanged', () => {
      assert.strictEqual(normalizeTimeHHMM('not-a-time'), 'not-a-time');
    });
  });

  describe('parseTimeToMinutes', () => {
    it('parses valid HH:MM', () => {
      assert.strictEqual(parseTimeToMinutes('00:00'), 0);
      assert.strictEqual(parseTimeToMinutes('10:15'), 10 * 60 + 15);
      assert.strictEqual(parseTimeToMinutes('23:59'), 23 * 60 + 59);
    });

    it('returns NaN for invalid input', () => {
      assert.ok(Number.isNaN(parseTimeToMinutes('not-a-time')));
      assert.ok(Number.isNaN(parseTimeToMinutes('24:00')));
      assert.ok(Number.isNaN(parseTimeToMinutes('10:60')));
    });
  });

  describe('parseTimeParts', () => {
    it('accepts HH:MM', () => {
      assert.deepStrictEqual(parseTimeParts('10:15'), { hours: 10, minutes: 15, seconds: 0 });
    });

    it('accepts HH:MM:SS', () => {
      assert.deepStrictEqual(parseTimeParts('10:15:30'), { hours: 10, minutes: 15, seconds: 30 });
    });

    it('throws for invalid input', () => {
      assert.throws(
        () => parseTimeParts('99:99'),
        (err: unknown) => {
          assert.ok(err instanceof Error);
          assert.match(err.message, /Invalid time format/i);
          return true;
        }
      );
    });
  });

  describe('SCHEDULE_TIME_STEP_MINUTES', () => {
    it('is the 5-minute granularity used across schedule validation', () => {
      assert.strictEqual(SCHEDULE_TIME_STEP_MINUTES, 5);
    });
  });

  describe('assertQuarterHourTime', () => {
    it('accepts times aligned to the 5-minute step without seconds', () => {
      assert.doesNotThrow(() => {
        assertQuarterHourTime('10:00');
      });
      assert.doesNotThrow(() => {
        assertQuarterHourTime('10:05');
      });
      assert.doesNotThrow(() => {
        assertQuarterHourTime('10:20');
      });
      assert.doesNotThrow(() => {
        assertQuarterHourTime('10:35');
      });
    });

    it('rejects minutes that are not on the 5-minute step', () => {
      assert.throws(
        () => {
          assertQuarterHourTime('10:03');
        },
        (err: unknown) => {
          assert.ok(err instanceof Error);
          assert.match(err.message, /5-minute/i);
          return true;
        }
      );
    });

    it('rejects seconds', () => {
      assert.throws(
        () => {
          assertQuarterHourTime('10:15:01');
        },
        (err: unknown) => {
          assert.ok(err instanceof Error);
          assert.match(err.message, /must not include seconds/i);
          return true;
        }
      );
    });
  });

  describe('assertQuarterHourInstant', () => {
    it('accepts instants aligned to the 5-minute step', () => {
      assert.doesNotThrow(() => {
        assertQuarterHourInstant(new Date('2025-01-01T10:20:00.000Z'));
      });
    });

    it('rejects invalid date', () => {
      assert.throws(
        () => {
          assertQuarterHourInstant(new Date('not-a-date'));
        },
        (err: unknown) => {
          assert.ok(err instanceof Error);
          assert.match(err.message, /Invalid date/i);
          return true;
        }
      );
    });

    it('rejects seconds/milliseconds', () => {
      assert.throws(
        () => {
          assertQuarterHourInstant(new Date('2025-01-01T10:15:01.000Z'));
        },
        (err: unknown) => {
          assert.ok(err instanceof Error);
          assert.match(err.message, /must not include seconds/i);
          return true;
        }
      );
    });

    it('rejects minutes that are not on the 5-minute step', () => {
      assert.throws(
        () => {
          assertQuarterHourInstant(new Date('2025-01-01T10:16:00.000Z'));
        },
        (err: unknown) => {
          assert.ok(err instanceof Error);
          assert.match(err.message, /5-minute/i);
          return true;
        }
      );
    });
  });
});
