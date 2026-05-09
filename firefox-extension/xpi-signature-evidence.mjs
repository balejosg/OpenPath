import fs from 'node:fs';

const localFileHeaderSignature = 0x04034b50;
const centralDirectoryHeaderSignature = 0x02014b50;

export function readZipEntryNames(filePath) {
  const buffer = fs.readFileSync(filePath);
  const names = [];

  for (let offset = 0; offset <= buffer.length - 30; ) {
    const signature = buffer.readUInt32LE(offset);
    if (signature === localFileHeaderSignature) {
      const fileNameLength = buffer.readUInt16LE(offset + 26);
      const extraFieldLength = buffer.readUInt16LE(offset + 28);
      const fileNameStart = offset + 30;
      const fileNameEnd = fileNameStart + fileNameLength;
      if (fileNameEnd > buffer.length) break;
      names.push(buffer.subarray(fileNameStart, fileNameEnd).toString('utf8'));
      offset = fileNameEnd + extraFieldLength;
      continue;
    }

    if (signature === centralDirectoryHeaderSignature) {
      const fileNameLength = buffer.readUInt16LE(offset + 28);
      const extraFieldLength = buffer.readUInt16LE(offset + 30);
      const fileCommentLength = buffer.readUInt16LE(offset + 32);
      const fileNameStart = offset + 46;
      const fileNameEnd = fileNameStart + fileNameLength;
      if (fileNameEnd > buffer.length) break;
      names.push(buffer.subarray(fileNameStart, fileNameEnd).toString('utf8'));
      offset = fileNameEnd + extraFieldLength + fileCommentLength;
      continue;
    }

    offset += 1;
  }

  return [...new Set(names)];
}

export function hasFirefoxAmoSignatureEvidence(filePath) {
  const entryNames = readZipEntryNames(filePath).map((name) => name.toUpperCase());
  return (
    entryNames.includes('META-INF/MANIFEST.MF') &&
    (entryNames.includes('META-INF/MOZILLA.RSA') || entryNames.includes('META-INF/MOZILLA.SF'))
  );
}

export function assertFirefoxAmoSignedXpi(filePath) {
  if (!hasFirefoxAmoSignatureEvidence(filePath)) {
    throw new Error(
      `Firefox Release XPI must include AMO signature files under META-INF: ${filePath}`
    );
  }
}
