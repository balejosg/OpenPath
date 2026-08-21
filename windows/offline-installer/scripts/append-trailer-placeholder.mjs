#!/usr/bin/env node
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
  appendFileSync,
} from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SLOT_LENGTH = 65536;

function stripExistingTrailer(exeBuffer) {
  if (exeBuffer.length < 68) {
    return exeBuffer;
  }

  const epilogueStart = exeBuffer.length - 16;
  if (exeBuffer.toString('latin1', epilogueStart, epilogueStart + 4) !== 'OPWS') {
    return exeBuffer;
  }

  const slotLength = exeBuffer.readUInt32LE(epilogueStart + 4);
  const headerSize = exeBuffer.readUInt32LE(epilogueStart + 8);
  const epilogueSize = exeBuffer.readUInt32LE(epilogueStart + 12);
  return exeBuffer.subarray(0, exeBuffer.length - headerSize - slotLength - epilogueSize);
}

function main() {
  const scriptDir = resolve(dirname(fileURLToPath(import.meta.url)));
  const offlineRoot = resolve(scriptDir, '..');
  const buildDir = join(offlineRoot, 'build');
  const compiledExe = process.argv[2] ?? join(buildDir, 'OpenPath-Windows-Setup.exe');
  const placeholderBin = process.argv[3] ?? join(buildDir, 'trailer-placeholder.bin');
  const outputExe = process.argv[4] ?? join(buildDir, 'OpenPath-Windows-Setup-Template.exe');

  for (const [label, path] of [
    ['compiled NSIS executable', compiledExe],
    ['trailer placeholder', placeholderBin],
  ]) {
    if (!existsSync(path)) {
      console.error(`Missing ${label}: ${path}`);
      process.exit(1);
    }
  }

  const exe = readFileSync(compiledExe);
  const trailer = readFileSync(placeholderBin);

  if (trailer.length !== 52 + SLOT_LENGTH + 16) {
    console.error(`Trailer placeholder has unexpected size ${trailer.length}`);
    process.exit(1);
  }

  const baseExe = stripExistingTrailer(exe);
  mkdirSync(dirname(outputExe), { recursive: true });
  writeFileSync(outputExe, Buffer.concat([baseExe, trailer]));

  const finalHash = createHash('sha256').update(readFileSync(outputExe)).digest('hex');
  const verifyBuffer = readFileSync(outputExe);
  const verifyHash = createHash('sha256').update(verifyBuffer).digest('hex');
  if (verifyHash !== finalHash) {
    console.error('Template hash changed between write and verification');
    process.exit(1);
  }

  appendFileSync(`${outputExe}.sha256`, `${finalHash}  ${outputExe.split(/[\\/]/).pop()}\n`);

  console.log(`Appended trailer; template at ${outputExe} with sha256 ${finalHash}`);
}

main();
