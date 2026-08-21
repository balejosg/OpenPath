import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  MAX_WINDOWS_OFFLINE_INSTALLER_API_URL_LENGTH,
  MAX_WINDOWS_OFFLINE_INSTALLER_APPROVED_STUDENT_BROWSERS,
  MAX_WINDOWS_OFFLINE_INSTALLER_APPROVED_STUDENT_BROWSER_LENGTH,
  MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAINS,
  MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAIN_LENGTH,
  MAX_WINDOWS_OFFLINE_INSTALLER_CLASSROOM_ID_LENGTH,
  MAX_WINDOWS_OFFLINE_INSTALLER_ENROLLMENT_TOKEN_LENGTH,
  WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA,
  WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE,
  WINDOWS_OFFLINE_INSTALLER_HEADER_MAGIC,
  WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE,
  WINDOWS_OFFLINE_INSTALLER_PAYLOAD_SCHEMA,
  WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION,
  WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH,
  WINDOWS_OFFLINE_INSTALLER_TRAILER_SIZE,
} from '../src/windows-offline-installer.js';

const validConfig = {
  schemaVersion: WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION,
  apiUrl: 'https://example.invalid/api',
  classroomId: 'classroom-123',
  enrollmentToken: 'header.payload.signature',
  enrollmentTokenExpiresAt: '2026-08-22T10:00:00.000Z',
  captivePortalDomains: ['login.example.invalid'],
  options: {
    approvedStudentBrowsers: ['Firefox'],
    installFirefoxIfMissing: true,
    enforceManagedBrowserBoundary: true,
  },
} as const;

void describe('windows offline installer contract', () => {
  void it('parses a valid config payload', () => {
    assert.deepEqual(WINDOWS_OFFLINE_INSTALLER_PAYLOAD_SCHEMA.parse(validConfig), validConfig);
    assert.deepEqual(WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse(validConfig), validConfig);
  });

  void it('rejects a non-https apiUrl and an oversized apiUrl', () => {
    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        apiUrl: 'http://example.invalid/api',
      })
    );

    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        apiUrl: `https://example.invalid/${'a'.repeat(MAX_WINDOWS_OFFLINE_INSTALLER_API_URL_LENGTH)}`,
      })
    );
  });

  void it('rejects oversized classroom ids and enrollment tokens', () => {
    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        classroomId: 'c'.repeat(MAX_WINDOWS_OFFLINE_INSTALLER_CLASSROOM_ID_LENGTH + 1),
      })
    );

    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        enrollmentToken: 't'.repeat(MAX_WINDOWS_OFFLINE_INSTALLER_ENROLLMENT_TOKEN_LENGTH + 1),
      })
    );
  });

  void it('rejects non-utc and invalid enrollment token expiry timestamps', () => {
    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        enrollmentTokenExpiresAt: '2026-08-22T10:00:00.000+02:00',
      })
    );

    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        enrollmentTokenExpiresAt: '2026-02-30T10:00:00.000Z',
      })
    );
  });

  void it('rejects oversized arrays and oversized array members', () => {
    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        captivePortalDomains: Array.from(
          { length: MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAINS + 1 },
          (_, index) => `portal-${index}.example.invalid`
        ),
      })
    );

    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        captivePortalDomains: [
          `${'a'.repeat(MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAIN_LENGTH - 8)}.invalid`,
        ],
      })
    );

    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        options: {
          ...validConfig.options,
          approvedStudentBrowsers: Array.from(
            { length: MAX_WINDOWS_OFFLINE_INSTALLER_APPROVED_STUDENT_BROWSERS + 1 },
            (_, index) => `Browser-${index}`
          ),
        },
      })
    );

    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        options: {
          ...validConfig.options,
          approvedStudentBrowsers: [
            'B'.repeat(MAX_WINDOWS_OFFLINE_INSTALLER_APPROVED_STUDENT_BROWSER_LENGTH + 1),
          ],
        },
      })
    );
  });

  void it('rejects unknown keys at the root and options levels', () => {
    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        extra: true,
      })
    );

    assert.throws(() =>
      WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        options: {
          ...validConfig.options,
          extra: true,
        },
      })
    );
  });

  void it('exports sane trailer constants', () => {
    assert.equal(WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION, 1);
    assert.equal(WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH, 65_536);
    assert.equal(WINDOWS_OFFLINE_INSTALLER_HEADER_MAGIC.length, 8);
    assert.equal(WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE, 52);
    assert.equal(WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE, 16);
    assert.equal(
      WINDOWS_OFFLINE_INSTALLER_TRAILER_SIZE,
      WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE +
        WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH +
        WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE
    );
  });
});
