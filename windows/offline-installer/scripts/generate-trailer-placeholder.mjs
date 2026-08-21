#!/usr/bin/env node
import { mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SLOT_LENGTH = 65536;
const HEADER_SIZE = 52;
const EPILOGUE_SIZE = 16;

function uint16le(value) {
  const buffer = Buffer.alloc(2);
  buffer.writeUInt16LE(value, 0);
  return buffer;
}

function uint32le(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value >>> 0, 0);
  return buffer;
}

export function serializeTrailerPlaceholder(payloadText) {
  const payload = Buffer.from(payloadText, 'utf8');
  if (payload.length > SLOT_LENGTH) {
    throw new Error(`Placeholder payload exceeds the fixed ${SLOT_LENGTH}-byte slot`);
  }

  const payloadSha256 = createHash('sha256').update(payload).digest();

  const header = Buffer.concat([
    Buffer.from('OPWSI1\0\0', 'latin1'),
    uint16le(1),
    uint16le(0),
    uint32le(payload.length),
    uint32le(SLOT_LENGTH),
    payloadSha256,
  ]);

  if (header.length !== HEADER_SIZE) {
    throw new Error(`Header size must be ${HEADER_SIZE} bytes`);
  }

  const slot = Buffer.alloc(SLOT_LENGTH, 0);
  payload.copy(slot, 0);

  const epilogue = Buffer.concat([
    Buffer.from('OPWS', 'latin1'),
    uint32le(SLOT_LENGTH),
    uint32le(HEADER_SIZE),
    uint32le(EPILOGUE_SIZE),
  ]);

  if (epilogue.length !== EPILOGUE_SIZE) {
    throw new Error(`Epilogue size must be ${EPILOGUE_SIZE} bytes`);
  }

  return Buffer.concat([header, slot, epilogue]);
}

export function placeholderPayloadText() {
  return JSON.stringify({
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
  });
}

function main() {
  const scriptDir = resolve(dirname(fileURLToPath(import.meta.url)));
  const outputPath = process.argv[2] ?? join(scriptDir, '..', 'build', 'trailer-placeholder.bin');

  const trailer = serializeTrailerPlaceholder(placeholderPayloadText());
  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, trailer);
  console.log(`Wrote ${trailer.length}-byte trailer placeholder to ${outputPath}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
