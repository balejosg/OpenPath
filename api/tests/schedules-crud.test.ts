import { describe, test } from 'node:test';
import assert from 'node:assert';

import * as scheduleStorage from '../src/lib/schedule-storage.js';
import {
  registerSchedulesLifecycle,
  secondaryGroupId,
  testClassroomId,
  testGroupId,
  testTeacherId,
} from './schedules-test-harness.js';

registerSchedulesLifecycle();

void describe('Schedule storage - CRUD operations', () => {
  void test('should create a schedule', async () => {
    const schedule = await scheduleStorage.createSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:00',
    });

    assert.ok(schedule.id !== '');
    assert.strictEqual(schedule.classroomId, testClassroomId);
    assert.strictEqual(schedule.teacherId, testTeacherId);
    assert.strictEqual(schedule.recurrence, 'weekly');
  });

  void test('should create a one-off schedule', async () => {
    const schedule = await scheduleStorage.createOneOffSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      startAt: new Date(2026, 1, 23, 11, 0, 0, 0),
      endAt: new Date(2026, 1, 23, 12, 0, 0, 0),
    });

    assert.ok(schedule.id !== '');
    assert.strictEqual(schedule.classroomId, testClassroomId);
    assert.strictEqual(schedule.teacherId, testTeacherId);
    assert.strictEqual(schedule.recurrence, 'one_off');
    assert.strictEqual(schedule.dayOfWeek, null);
    assert.strictEqual(schedule.startTime, null);
    assert.strictEqual(schedule.endTime, null);
    assert.ok(schedule.startAt);
    assert.ok(schedule.endAt);
  });

  void test('should reject one-off schedules with seconds or ms', async () => {
    await assert.rejects(async () => {
      await scheduleStorage.createOneOffSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: testGroupId,
        startAt: new Date(2026, 1, 23, 11, 0, 1, 0),
        endAt: new Date(2026, 1, 23, 12, 0, 0, 0),
      });
    }, /must not include seconds/i);
  });

  void test('should reject one-off schedules not in 5-minute increments', async () => {
    await assert.rejects(async () => {
      await scheduleStorage.createOneOffSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: testGroupId,
        startAt: new Date(2026, 1, 23, 11, 13, 0, 0),
        endAt: new Date(2026, 1, 23, 12, 0, 0, 0),
      });
    }, /\b5-minute increments/i);
  });

  void test('should accept one-off schedules on a 5-minute boundary', async () => {
    await assert.doesNotReject(async () => {
      await scheduleStorage.createOneOffSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: testGroupId,
        startAt: new Date(2026, 1, 23, 11, 20, 0, 0),
        endAt: new Date(2026, 1, 23, 11, 55, 0, 0),
      });
    });
  });

  void test('should reject one-off schedule when endAt <= startAt', async () => {
    await assert.rejects(async () => {
      await scheduleStorage.createOneOffSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: testGroupId,
        startAt: new Date(2026, 1, 23, 12, 0, 0, 0),
        endAt: new Date(2026, 1, 23, 12, 0, 0, 0),
      });
    }, /endAt must be after startAt/i);
  });

  void test('should detect conflicts for one-off schedules', async () => {
    await scheduleStorage.createOneOffSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      startAt: new Date(2026, 1, 23, 11, 0, 0, 0),
      endAt: new Date(2026, 1, 23, 12, 0, 0, 0),
    });

    await assert.rejects(async () => {
      await scheduleStorage.createOneOffSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: secondaryGroupId,
        startAt: new Date(2026, 1, 23, 11, 30, 0, 0),
        endAt: new Date(2026, 1, 23, 12, 30, 0, 0),
      });
    }, /Schedule conflict/);
  });

  void test('should update a one-off schedule', async () => {
    const schedule = await scheduleStorage.createOneOffSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      startAt: new Date(2026, 1, 23, 11, 0, 0, 0),
      endAt: new Date(2026, 1, 23, 12, 0, 0, 0),
    });

    const updated = await scheduleStorage.updateOneOffSchedule(schedule.id, {
      groupId: secondaryGroupId,
    });

    assert.ok(updated);
    assert.strictEqual(updated.groupId, secondaryGroupId);
    assert.strictEqual(updated.recurrence, 'one_off');
  });

  void test('should reject updating one-off schedule with weekly updater', async () => {
    const schedule = await scheduleStorage.createOneOffSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      startAt: new Date(2026, 1, 23, 11, 0, 0, 0),
      endAt: new Date(2026, 1, 23, 12, 0, 0, 0),
    });

    await assert.rejects(async () => {
      await scheduleStorage.updateSchedule(schedule.id, {
        startTime: '08:30',
      });
    }, /Cannot update one-off schedule with weekly updater/);
  });

  void test('should reject updating weekly schedule with one-off updater', async () => {
    const schedule = await scheduleStorage.createSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:00',
    });

    await assert.rejects(async () => {
      await scheduleStorage.updateOneOffSchedule(schedule.id, {
        groupId: secondaryGroupId,
      });
    }, /Cannot update weekly schedule with one-off updater/);
  });

  void test('should reject invalid day of week', async () => {
    await assert.rejects(async () => {
      await scheduleStorage.createSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: testGroupId,
        dayOfWeek: 6,
        startTime: '08:00',
        endTime: '09:00',
      });
    }, /dayOfWeek must be between 1.*and 5/);
  });

  void test('should reject invalid time format', async () => {
    await assert.rejects(async () => {
      await scheduleStorage.createSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: testGroupId,
        dayOfWeek: 1,
        startTime: '8:00',
        endTime: '09:00',
      });
    }, /Invalid time format/);
  });

  void test('should reject times not in 5-minute increments', async () => {
    await assert.rejects(async () => {
      await scheduleStorage.createSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: testGroupId,
        dayOfWeek: 1,
        startTime: '08:13',
        endTime: '09:00',
      });
    }, /\b5-minute increments/);
  });

  void test('should accept weekly times on a 5-minute boundary', async () => {
    await assert.doesNotReject(async () => {
      await scheduleStorage.createSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: testGroupId,
        dayOfWeek: 1,
        startTime: '08:20',
        endTime: '09:35',
      });
    });
  });

  void test('should reject startTime >= endTime', async () => {
    await assert.rejects(async () => {
      await scheduleStorage.createSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: testGroupId,
        dayOfWeek: 1,
        startTime: '09:00',
        endTime: '08:00',
      });
    }, /startTime must be before endTime/);
  });

  void test('should detect conflicts', async () => {
    await scheduleStorage.createSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:00',
    });

    await assert.rejects(async () => {
      await scheduleStorage.createSchedule({
        classroomId: testClassroomId,
        teacherId: testTeacherId,
        groupId: secondaryGroupId,
        dayOfWeek: 1,
        startTime: '08:30',
        endTime: '09:30',
      });
    }, /Schedule conflict/);
  });

  void test('should allow non-overlapping schedules', async () => {
    await scheduleStorage.createSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:00',
    });

    const schedule2 = await scheduleStorage.createSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: secondaryGroupId,
      dayOfWeek: 1,
      startTime: '09:00',
      endTime: '10:00',
    });

    assert.ok(schedule2.id !== '');
  });

  void test('should update a schedule', async () => {
    const schedule = await scheduleStorage.createSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:00',
    });

    const updated = await scheduleStorage.updateSchedule(schedule.id, {
      startTime: '08:30',
      endTime: '09:30',
    });

    assert.ok(updated);
    assert.strictEqual(updated.startTime, '08:30:00');
    assert.strictEqual(updated.endTime, '09:30:00');
  });

  void test('should delete a schedule', async () => {
    const schedule = await scheduleStorage.createSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:00',
    });

    const deleted = await scheduleStorage.deleteSchedule(schedule.id);
    assert.strictEqual(deleted, true);

    const retrieved = await scheduleStorage.getScheduleById(schedule.id);
    assert.strictEqual(retrieved, null);
  });

  void test('should reject update with weekend dayOfWeek', async () => {
    const schedule = await scheduleStorage.createSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:00',
    });

    await assert.rejects(async () => {
      await scheduleStorage.updateSchedule(schedule.id, {
        dayOfWeek: 6,
      });
    }, /dayOfWeek must be between 1.*and 5/);
  });

  void test('should reject update with non-5-minute times', async () => {
    const schedule = await scheduleStorage.createSchedule({
      classroomId: testClassroomId,
      teacherId: testTeacherId,
      groupId: testGroupId,
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:00',
    });

    await assert.rejects(async () => {
      await scheduleStorage.updateSchedule(schedule.id, {
        startTime: '08:13',
        endTime: '09:00',
      });
    }, /\b5-minute increments/);
  });
});
