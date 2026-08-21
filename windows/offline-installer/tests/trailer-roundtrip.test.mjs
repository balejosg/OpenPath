import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test } from 'node:test';

import { parseFromFile, serialize } from '../../../api/src/lib/windows-offline-installer.ts';
import { WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH } from '../../../shared/src/windows-offline-installer.ts';
import { serializeTrailerPlaceholder } from '../scripts/generate-trailer-placeholder.mjs';

const repoRoot = resolve(import.meta.dirname, '..', '..', '..');
const buildDir = join(repoRoot, 'windows', 'offline-installer', 'build');

test('placeholder generator output is byte-compatible with the api trailer parser', async () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'opws-roundtrip-'));
  const placeholderPath = join(tempDir, 'placeholder.bin');
  writeFileSync(
    placeholderPath,
    serializeTrailerPlaceholder(
      JSON.stringify({
        schemaVersion: 1,
        apiUrl: 'https://template-placeholder.invalid',
        classroomId: 'template-placeholder',
        enrollmentToken: 'template-placeholder-token',
        enrollmentTokenExpiresAt: '2036-01-01T00:00:00.000Z',
        captivePortalDomains: [],
        options: {
          approvedStudentBrowsers: ['Firefox'],
          installFirefoxIfMissing: true,
          enforceManagedBrowserBoundary: true,
        },
      })
    )
  );

  const parsed = await parseFromFile(placeholderPath);
  assert.equal(parsed.config.schemaVersion, 1);
  assert.equal(parsed.slotLength, WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH);
  assert.equal(parsed.config.classroomId, 'template-placeholder');
});

test('appended template executable exposes a valid discoverable trailer', async () => {
  const templatePath = join(buildDir, 'OpenPath-Windows-Setup-Template.exe');
  if (!existsSync(templatePath)) {
    console.log(
      `skipping appended-template assertion; ${templatePath} not built in this environment`
    );
    return;
  }

  const exe = readFileSync(templatePath);
  const epilogueStart = exe.length - 16;
  assert.equal(exe.toString('latin1', epilogueStart, epilogueStart + 4), 'OPWS');

  const parsed = await parseFromFile(templatePath);
  assert.equal(parsed.config.schemaVersion, 1);
  assert.equal(parsed.config.classroomId, 'template-placeholder');
});

test('api serializer and the mjs placeholder writer agree on trailer geometry', () => {
  const fromApi = serialize({
    schemaVersion: 1,
    apiUrl: 'https://api.example.test',
    classroomId: 'room',
    enrollmentToken: 'token',
    enrollmentTokenExpiresAt: '2026-08-22T10:00:00.000Z',
    captivePortalDomains: [],
    options: {
      approvedStudentBrowsers: ['Firefox'],
      installFirefoxIfMissing: true,
      enforceManagedBrowserBoundary: true,
    },
  });

  const headerMagic = fromApi.toString('latin1', 0, 8);
  const epilogueOffset = fromApi.length - 16;
  assert.equal(headerMagic, 'OPWSI1\0\0');
  assert.equal(fromApi.toString('latin1', epilogueOffset, epilogueOffset + 4), 'OPWS');
  assert.equal(fromApi.length, 52 + WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH + 16);
});
