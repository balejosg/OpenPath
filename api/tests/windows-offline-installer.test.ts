import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, test } from 'node:test';

import {
  WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA,
  WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE,
  WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE,
  WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION,
  WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH,
} from '@openpath/shared/windows-offline-installer';

import {
  applyOverlay,
  hashFileSha256,
  parseFromFile,
  serialize,
} from '../src/lib/windows-offline-installer.js';

const validConfig = WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
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
});

async function withTempDir(run: (directoryPath: string) => Promise<void>): Promise<void> {
  const directoryPath = await mkdtemp(path.join(tmpdir(), 'openpath-offline-installer-'));
  try {
    await run(directoryPath);
  } finally {
    await rm(directoryPath, { recursive: true, force: true });
  }
}

void describe('windows offline installer trailer', () => {
  void test('serializes, zero-pads, and parses a trailer round trip', async () => {
    const trailer = serialize(validConfig);
    const payload = Buffer.from(JSON.stringify(validConfig), 'utf8');
    const slot = trailer.subarray(
      WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE,
      WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE + WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH
    );

    assert.equal(
      trailer.length,
      WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE +
        WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH +
        WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE
    );
    assert.deepEqual(slot.subarray(0, payload.length), payload);
    assert.ok(slot.subarray(payload.length).every((byte) => byte === 0));

    await withTempDir(async (directoryPath) => {
      const prefix = Buffer.from('MZ-template-prefix', 'utf8');
      const filePath = path.join(directoryPath, 'installer.exe');
      await writeFile(filePath, Buffer.concat([prefix, trailer]));

      const parsed = await parseFromFile(filePath);
      assert.deepEqual(parsed.config, validConfig);
      assert.equal(parsed.payloadLength, payload.length);
      assert.equal(parsed.slotLength, WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH);
      assert.equal(parsed.trailerStart, prefix.length);
    });
  });

  void test('rejects malformed magic values and unsupported schema versions', async () => {
    await withTempDir(async (directoryPath) => {
      const trailer = serialize(validConfig);
      const badEpiloguePath = path.join(directoryPath, 'bad-epilogue.exe');
      const badEpilogue = Buffer.from(trailer);
      badEpilogue.write(
        'FAIL',
        badEpilogue.length - WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE,
        'utf8'
      );
      await writeFile(badEpiloguePath, badEpilogue);
      await assert.rejects(() => parseFromFile(badEpiloguePath), /epilogue magic/i);

      const badHeaderPath = path.join(directoryPath, 'bad-header.exe');
      const badHeader = Buffer.from(trailer);
      badHeader.write('BROKEN!!', 0, 'utf8');
      await writeFile(badHeaderPath, badHeader);
      await assert.rejects(() => parseFromFile(badHeaderPath), /header magic/i);

      const badVersionPath = path.join(directoryPath, 'bad-version.exe');
      const badVersion = Buffer.from(trailer);
      badVersion.writeUInt16LE(WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION + 1, 8);
      await writeFile(badVersionPath, badVersion);
      await assert.rejects(() => parseFromFile(badVersionPath), /schema version/i);
    });
  });

  void test('rejects payload lengths beyond the configured slot length', async () => {
    await withTempDir(async (directoryPath) => {
      const trailer = Buffer.from(serialize(validConfig));
      trailer.writeUInt32LE(WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH + 1, 12);
      const filePath = path.join(directoryPath, 'too-large.exe');
      await writeFile(filePath, trailer);
      await assert.rejects(() => parseFromFile(filePath), /payload length/i);
    });
  });

  void test('rejects non-zero padding and payload hash corruption', async () => {
    await withTempDir(async (directoryPath) => {
      const trailer = Buffer.from(serialize(validConfig));
      const payloadLength = Buffer.byteLength(JSON.stringify(validConfig), 'utf8');

      const badPaddingPath = path.join(directoryPath, 'bad-padding.exe');
      const badPadding = Buffer.from(trailer);
      badPadding[WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE + payloadLength] = 1;
      await writeFile(badPaddingPath, badPadding);
      await assert.rejects(() => parseFromFile(badPaddingPath), /zero padding/i);

      const badHashPath = path.join(directoryPath, 'bad-hash.exe');
      const badHash = Buffer.from(trailer);
      const corruptedPayloadByteIndex = WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE + payloadLength - 1;
      const corruptedPayloadByte = badHash[corruptedPayloadByteIndex];
      if (corruptedPayloadByte === undefined) {
        throw new Error('Expected a payload byte to corrupt in the test fixture');
      }
      badHash[corruptedPayloadByteIndex] = corruptedPayloadByte ^ 1;
      await writeFile(badHashPath, badHash);
      await assert.rejects(() => parseFromFile(badHashPath), /sha-256/i);
    });
  });

  void test('rejects malformed JSON payloads even when the hash matches', async () => {
    await withTempDir(async (directoryPath) => {
      const trailer = Buffer.from(serialize(validConfig));
      const invalidPayload = Buffer.from('{', 'utf8');
      invalidPayload.copy(trailer, WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE);
      trailer.fill(
        0,
        WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE + invalidPayload.length,
        WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE + WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH
      );
      trailer.writeUInt32LE(invalidPayload.length, 12);
      createHash('sha256').update(invalidPayload).digest().copy(trailer, 20);

      const filePath = path.join(directoryPath, 'bad-json.exe');
      await writeFile(filePath, trailer);

      await assert.rejects(() => parseFromFile(filePath), /json/i);
    });
  });

  void test('applies an overlay without changing bytes outside the trailer, keeps the same size, and leaves no temp files', async () => {
    await withTempDir(async (directoryPath) => {
      const templateConfig = WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        classroomId: 'template-classroom',
      });
      const outputConfig = WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse({
        ...validConfig,
        classroomId: 'output-classroom',
        enrollmentToken: 'overlay.payload.signature',
      });
      const prefix = Buffer.from('template-prefix-data', 'utf8');
      const templatePath = path.join(directoryPath, 'template.exe');
      const outputPath = path.join(directoryPath, 'output.exe');
      const templateBody = Buffer.concat([prefix, serialize(templateConfig)]);

      await writeFile(templatePath, templateBody);
      await applyOverlay(templatePath, outputPath, outputConfig);

      const [templateBytes, outputBytes] = await Promise.all([
        readFile(templatePath),
        readFile(outputPath),
      ]);
      assert.deepEqual(
        outputBytes.subarray(0, prefix.length),
        templateBytes.subarray(0, prefix.length)
      );
      assert.equal(outputBytes.length, templateBytes.length);

      const parsed = await parseFromFile(outputPath);
      assert.deepEqual(parsed.config, outputConfig);

      const entries = await readdir(directoryPath);
      assert.deepEqual(
        entries.filter((entry) => entry.includes('.tmp-')),
        []
      );
    });
  });

  void test('hashes the final artifact bytes exactly', async () => {
    await withTempDir(async (directoryPath) => {
      const filePath = path.join(directoryPath, 'artifact.exe');
      await writeFile(
        filePath,
        Buffer.concat([Buffer.from('prefix', 'utf8'), serialize(validConfig)])
      );

      const [fileHash, fileBytes] = await Promise.all([
        hashFileSha256(filePath),
        readFile(filePath),
      ]);

      assert.equal(fileHash, createHash('sha256').update(fileBytes).digest('hex'));
      assert.deepEqual(await stat(filePath), await stat(filePath));
    });
  });
});
