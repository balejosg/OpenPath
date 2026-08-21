import { createHash } from 'node:crypto';
import { copyFile, mkdir, open, readFile, rename, rm } from 'node:fs/promises';
import path from 'node:path';

import {
  WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA,
  WINDOWS_OFFLINE_INSTALLER_EPILOGUE_MAGIC,
  WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE,
  WINDOWS_OFFLINE_INSTALLER_FLAGS,
  WINDOWS_OFFLINE_INSTALLER_HEADER_MAGIC,
  WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE,
  WINDOWS_OFFLINE_INSTALLER_PAYLOAD_SCHEMA,
  WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION,
  WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH,
  type WindowsOfflineInstallerConfig,
} from '@openpath/shared/windows-offline-installer';

const HEADER_MAGIC_BYTES = Buffer.from(WINDOWS_OFFLINE_INSTALLER_HEADER_MAGIC, 'binary');
const EPILOGUE_MAGIC_BYTES = Buffer.from(WINDOWS_OFFLINE_INSTALLER_EPILOGUE_MAGIC, 'ascii');
const SHA256_SIZE = 32;

export interface ParsedWindowsOfflineInstaller {
  config: WindowsOfflineInstallerConfig;
  trailerStart: number;
  payloadLength: number;
  slotLength: number;
  headerSize: number;
  epilogueSize: number;
  payloadSha256: Buffer;
}

function sha256(buffer: Buffer): Buffer {
  return createHash('sha256').update(buffer).digest();
}

function sha256Hex(buffer: Buffer): string {
  return createHash('sha256').update(buffer).digest('hex');
}

function buildHeader(payload: Buffer, slotLength: number): Buffer {
  const header = Buffer.alloc(WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE);
  HEADER_MAGIC_BYTES.copy(header, 0);
  header.writeUInt16LE(WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION, 8);
  header.writeUInt16LE(WINDOWS_OFFLINE_INSTALLER_FLAGS, 10);
  header.writeUInt32LE(payload.length, 12);
  header.writeUInt32LE(slotLength, 16);
  sha256(payload).copy(header, 20);
  return header;
}

function buildEpilogue(slotLength: number): Buffer {
  const epilogue = Buffer.alloc(WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE);
  EPILOGUE_MAGIC_BYTES.copy(epilogue, 0);
  epilogue.writeUInt32LE(slotLength, 4);
  epilogue.writeUInt32LE(WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE, 8);
  epilogue.writeUInt32LE(WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE, 12);
  return epilogue;
}

function serializePayload(config: WindowsOfflineInstallerConfig): Buffer {
  const validated = WINDOWS_OFFLINE_INSTALLER_PAYLOAD_SCHEMA.parse(config);
  const payload = Buffer.from(JSON.stringify(validated), 'utf8');
  if (payload.length > WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH) {
    throw new Error('Payload exceeds offline installer slot length');
  }

  return payload;
}

function buildTrailer(payload: Buffer, slotLength: number): Buffer {
  if (payload.length > slotLength) {
    throw new Error('Payload exceeds offline installer slot length');
  }

  const slot = Buffer.alloc(slotLength);
  payload.copy(slot, 0);
  return Buffer.concat([buildHeader(payload, slotLength), slot, buildEpilogue(slotLength)]);
}

function validateSlotLength(slotLength: number): void {
  if (slotLength !== WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH) {
    throw new Error(
      `Offline installer trailer slot length must be ${String(WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH)} in schema v1`
    );
  }
}

function validateZeroPadding(slot: Buffer, payloadLength: number): void {
  for (let index = payloadLength; index < slot.length; index += 1) {
    if (slot[index] !== 0) {
      throw new Error('Offline installer payload slot contains non-zero padding');
    }
  }
}

function parsePayload(payload: Buffer): WindowsOfflineInstallerConfig {
  let parsed: unknown;
  try {
    parsed = JSON.parse(payload.toString('utf8'));
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown JSON parse error';
    throw new Error(`Offline installer payload contains invalid JSON: ${message}`, {
      cause: error,
    });
  }

  return WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA.parse(parsed);
}

export function serialize(config: WindowsOfflineInstallerConfig): Buffer {
  const payload = serializePayload(config);
  return buildTrailer(payload, WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH);
}

export async function parseFromFile(filePath: string): Promise<ParsedWindowsOfflineInstaller> {
  const handle = await open(filePath, 'r');
  try {
    const { size: fileSize } = await handle.stat();
    if (fileSize < WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE) {
      throw new Error('Offline installer file is too small to contain a trailer epilogue');
    }

    const epilogue = Buffer.alloc(WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE);
    await handle.read(epilogue, 0, epilogue.length, fileSize - epilogue.length);

    if (!epilogue.subarray(0, 4).equals(EPILOGUE_MAGIC_BYTES)) {
      throw new Error('Offline installer trailer epilogue magic is invalid');
    }

    const slotLength = epilogue.readUInt32LE(4);
    const headerSize = epilogue.readUInt32LE(8);
    const epilogueSize = epilogue.readUInt32LE(12);

    validateSlotLength(slotLength);

    if (headerSize !== WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE) {
      throw new Error('Offline installer trailer header size is invalid');
    }
    if (epilogueSize !== WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE) {
      throw new Error('Offline installer trailer epilogue size is invalid');
    }

    const trailerStart = fileSize - headerSize - slotLength - epilogueSize;
    if (trailerStart < 0) {
      throw new Error('Offline installer trailer start is out of bounds');
    }

    const header = Buffer.alloc(headerSize);
    await handle.read(header, 0, header.length, trailerStart);

    if (!header.subarray(0, 8).equals(HEADER_MAGIC_BYTES)) {
      throw new Error('Offline installer trailer header magic is invalid');
    }

    const schemaVersion = header.readUInt16LE(8);
    if (schemaVersion !== WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION) {
      throw new Error(`Unsupported offline installer schema version: ${String(schemaVersion)}`);
    }

    const flags = header.readUInt16LE(10);
    if (flags !== WINDOWS_OFFLINE_INSTALLER_FLAGS) {
      throw new Error('Offline installer trailer uses unsupported flags; schema v1 requires 0');
    }

    const headerSlotLength = header.readUInt32LE(16);
    validateSlotLength(headerSlotLength);
    if (headerSlotLength !== slotLength) {
      throw new Error('Offline installer trailer slot length does not match the epilogue');
    }

    const payloadLength = header.readUInt32LE(12);
    if (payloadLength > slotLength) {
      throw new Error('Offline installer payload length exceeds slot length');
    }

    const slot = Buffer.alloc(slotLength);
    await handle.read(slot, 0, slot.length, trailerStart + headerSize);

    validateZeroPadding(slot, payloadLength);
    const payload = slot.subarray(0, payloadLength);
    const expectedHash = header.subarray(20, 20 + SHA256_SIZE);
    const actualHash = sha256(payload);
    if (!actualHash.equals(expectedHash)) {
      throw new Error('Offline installer payload SHA-256 does not match the header');
    }

    return {
      config: parsePayload(payload),
      trailerStart,
      payloadLength,
      slotLength,
      headerSize,
      epilogueSize,
      payloadSha256: Buffer.from(expectedHash),
    };
  } finally {
    await handle.close();
  }
}

export async function applyOverlay(
  templatePath: string,
  outputPath: string,
  config: WindowsOfflineInstallerConfig
): Promise<void> {
  const payload = serializePayload(config);
  const parsedTemplate = await parseFromFile(templatePath);
  const outputDirectory = path.dirname(outputPath);
  const outputFileName = path.basename(outputPath);
  await mkdir(outputDirectory, { recursive: true });

  const stagedOutputPath = path.join(outputDirectory, `.${outputFileName}.tmp-overlay`);

  try {
    await copyFile(templatePath, stagedOutputPath);
    const handle = await open(stagedOutputPath, 'r+');
    try {
      const header = buildHeader(payload, WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH);
      const slot = Buffer.alloc(WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH);
      payload.copy(slot, 0);
      const epilogue = buildEpilogue(WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH);

      await handle.write(header, 0, header.length, parsedTemplate.trailerStart);
      await handle.write(
        slot,
        0,
        slot.length,
        parsedTemplate.trailerStart + parsedTemplate.headerSize
      );
      await handle.write(
        epilogue,
        0,
        epilogue.length,
        parsedTemplate.trailerStart +
          parsedTemplate.headerSize +
          WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH
      );
    } finally {
      await handle.close();
    }

    await rename(stagedOutputPath, outputPath);
  } finally {
    await rm(stagedOutputPath, { force: true });
  }
}

export async function hashFileSha256(filePath: string): Promise<string> {
  return sha256Hex(await readFile(filePath));
}
