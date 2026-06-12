import { describe, it } from 'node:test';
import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import {
  GroupVisibility,
  HealthStatus,
  MachineStatus,
  RequestStatus,
  UserRole,
} from '../src/schemas/index.js';

describe('Enum Schemas', () => {
  describe('RequestStatus', () => {
    it('accepts valid values', () => {
      assert.doesNotThrow(() => RequestStatus.parse('pending'));
      assert.doesNotThrow(() => RequestStatus.parse('approved'));
      assert.doesNotThrow(() => RequestStatus.parse('rejected'));
    });

    it('rejects invalid values', () => {
      assert.throws(() => RequestStatus.parse('invalid'));
      assert.throws(() => RequestStatus.parse(''));
      assert.throws(() => RequestStatus.parse(null));
    });
  });

  describe('UserRole', () => {
    it('accepts valid values', () => {
      assert.doesNotThrow(() => UserRole.parse('admin'));
      assert.doesNotThrow(() => UserRole.parse('teacher'));
      assert.doesNotThrow(() => UserRole.parse('student'));
    });

    it('rejects invalid values', () => {
      assert.throws(() => UserRole.parse('superadmin'));
      assert.throws(() => UserRole.parse('guest'));
    });
  });

  describe('GroupVisibility', () => {
    it('accepts valid values', () => {
      assert.doesNotThrow(() => GroupVisibility.parse('private'));
      assert.doesNotThrow(() => GroupVisibility.parse('instance_public'));
    });

    it('rejects invalid values', () => {
      assert.throws(() => GroupVisibility.parse('public'));
      assert.throws(() => GroupVisibility.parse('org_public'));
    });
  });

  describe('MachineStatus', () => {
    it('accepts valid values', () => {
      assert.doesNotThrow(() => MachineStatus.parse('online'));
      assert.doesNotThrow(() => MachineStatus.parse('offline'));
      assert.doesNotThrow(() => MachineStatus.parse('unknown'));
    });

    it('rejects invalid values', () => {
      assert.throws(() => MachineStatus.parse('maintenance'));
    });
  });

  describe('HealthStatus', () => {
    it('matches shared contract fixture', () => {
      const fixturePath = new URL('../../tests/contracts/health-statuses.txt', import.meta.url);
      const expected = readFileSync(fixturePath, 'utf8')
        .split(/\r?\n/u)
        .map((line) => line.trim())
        .filter((line) => line.length > 0 && !line.startsWith('#'));

      assert.deepStrictEqual(HealthStatus.options, expected);
    });

    it('accepts valid values', () => {
      assert.doesNotThrow(() => HealthStatus.parse('HEALTHY'));
      assert.doesNotThrow(() => HealthStatus.parse('DEGRADED'));
      assert.doesNotThrow(() => HealthStatus.parse('CRITICAL'));
      assert.doesNotThrow(() => HealthStatus.parse('FAIL_OPEN'));
      assert.doesNotThrow(() => HealthStatus.parse('STALE_FAILSAFE'));
      assert.doesNotThrow(() => HealthStatus.parse('TAMPERED'));
      assert.doesNotThrow(() => HealthStatus.parse('PROTECTED'));
    });

    it('rejects invalid values', () => {
      assert.throws(() => HealthStatus.parse('healthy'));
      assert.throws(() => HealthStatus.parse('warning'));
      assert.throws(() => HealthStatus.parse('OK'));
      assert.throws(() => HealthStatus.parse('FAILED'));
    });
  });
});
