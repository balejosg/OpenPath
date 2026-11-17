import { describe, it } from 'node:test';
import assert from 'node:assert';

import {
  CLASSROOM_MACHINE_ONLINE_THRESHOLD_MINUTES,
  CLASSROOM_MACHINE_STALE_THRESHOLD_MINUTES,
  calculateClassroomMachineStatus,
  calculateClassroomStatus,
  resolveCurrentGroup,
} from '../src/classroom-status.js';

void describe('classroom-status', () => {
  void describe('calculateClassroomMachineStatus', () => {
    it('returns offline for null lastSeen', () => {
      const now = new Date('2025-01-01T00:00:00.000Z');
      assert.strictEqual(calculateClassroomMachineStatus(null, now), 'offline');
    });

    it('returns online for machine seen within the online threshold', () => {
      const now = new Date('2025-01-01T00:00:00.000Z');
      const lastSeen = new Date(now.getTime() - 2 * 60 * 1000);
      assert.strictEqual(calculateClassroomMachineStatus(lastSeen, now), 'online');
    });

    it('returns online for machine seen exactly at the online threshold', () => {
      const now = new Date('2025-01-01T00:00:00.000Z');
      const lastSeen = new Date(
        now.getTime() - CLASSROOM_MACHINE_ONLINE_THRESHOLD_MINUTES * 60 * 1000
      );
      assert.strictEqual(calculateClassroomMachineStatus(lastSeen, now), 'online');
    });

    it('returns stale for machine seen between online and stale thresholds', () => {
      const now = new Date('2025-01-01T00:00:00.000Z');
      const lastSeen = new Date(
        now.getTime() - (CLASSROOM_MACHINE_ONLINE_THRESHOLD_MINUTES + 1) * 60 * 1000
      );
      assert.strictEqual(calculateClassroomMachineStatus(lastSeen, now), 'stale');
    });

    it('returns stale for machine seen exactly at the stale threshold', () => {
      const now = new Date('2025-01-01T00:00:00.000Z');
      const lastSeen = new Date(
        now.getTime() - CLASSROOM_MACHINE_STALE_THRESHOLD_MINUTES * 60 * 1000
      );
      assert.strictEqual(calculateClassroomMachineStatus(lastSeen, now), 'stale');
    });

    it('returns offline for machine seen after the stale threshold', () => {
      const now = new Date('2025-01-01T00:00:00.000Z');
      const lastSeen = new Date(
        now.getTime() - (CLASSROOM_MACHINE_STALE_THRESHOLD_MINUTES + 1) * 60 * 1000
      );
      assert.strictEqual(calculateClassroomMachineStatus(lastSeen, now), 'offline');
    });
  });

  void describe('calculateClassroomStatus', () => {
    it('returns operational for classroom with no machines', () => {
      assert.strictEqual(calculateClassroomStatus([]), 'operational');
    });

    it('returns operational when all machines are online', () => {
      assert.strictEqual(
        calculateClassroomStatus([{ status: 'online' }, { status: 'online' }]),
        'operational'
      );
    });

    it('returns offline when all machines are offline', () => {
      assert.strictEqual(
        calculateClassroomStatus([{ status: 'offline' }, { status: 'offline' }]),
        'offline'
      );
    });

    it('returns degraded when there is a mix of statuses', () => {
      assert.strictEqual(
        calculateClassroomStatus([{ status: 'online' }, { status: 'offline' }]),
        'degraded'
      );
      assert.strictEqual(
        calculateClassroomStatus([{ status: 'online' }, { status: 'stale' }]),
        'degraded'
      );
      assert.strictEqual(
        calculateClassroomStatus([{ status: 'stale' }, { status: 'stale' }]),
        'degraded'
      );
    });
  });

  void describe('resolveCurrentGroup', () => {
    it('prefers activeGroupId over scheduleGroupId and defaultGroupId', () => {
      assert.deepStrictEqual(
        resolveCurrentGroup({
          activeGroupId: 'g-manual',
          scheduleGroupId: 'g-schedule',
          defaultGroupId: 'g-default',
        }),
        { id: 'g-manual', source: 'manual' }
      );
    });

    it('returns manual unrestricted before schedule and default fallbacks', () => {
      assert.deepStrictEqual(
        resolveCurrentGroup({
          activeGroupId: null,
          activeUnrestricted: true,
          scheduleGroupId: 'g-schedule',
          defaultGroupId: 'g-default',
        }),
        { id: null, source: 'manual' }
      );
    });

    it('uses scheduleGroupId when no activeGroupId is set', () => {
      assert.deepStrictEqual(
        resolveCurrentGroup({
          activeGroupId: null,
          scheduleGroupId: 'g-schedule',
          defaultGroupId: 'g-default',
        }),
        { id: 'g-schedule', source: 'schedule' }
      );
    });

    it('uses defaultGroupId when neither activeGroupId nor scheduleGroupId are set', () => {
      assert.deepStrictEqual(
        resolveCurrentGroup({
          activeGroupId: null,
          scheduleGroupId: null,
          defaultGroupId: 'g-default',
        }),
        { id: 'g-default', source: 'default' }
      );
    });

    it('returns none when no group ids are available', () => {
      assert.deepStrictEqual(
        resolveCurrentGroup({
          activeGroupId: null,
          scheduleGroupId: null,
          defaultGroupId: null,
        }),
        { id: null, source: 'none' }
      );
    });
  });
});
