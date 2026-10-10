import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  SIGNED_EXECUTABLE_NAME,
  SIGNED_METADATA_NAME,
  fetchSignedNativeHost,
  sha256File,
  signedAssetNames,
  validateSigningMetadata,
} from '../scripts/fetch-native-host-signed-artifact.mjs';
import { resolveNativeHostSigning } from '../scripts/build-payload-manifest.mjs';

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function withRepo(run) {
  const root = mkdtempSync(path.join(tmpdir(), 'openpath-native-host-signed-'));
  mkdirSync(path.join(root, 'windows', 'native-host'), { recursive: true });
  const sourcePath = path.join(root, 'windows', 'native-host', 'OpenPathNativeHost.cs');
  writeFileSync(sourcePath, '// native host source\n');
  try {
    run({ root, sourcePath });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('names the signed assets by source hash and validates a consistent pair', () => {
  withRepo(({ sourcePath }) => {
    const sourceSha256 = sha256File(sourcePath);
    const assets = signedAssetNames(sourceSha256);
    assert.equal(assets.executable, `OpenPath-NativeHost-${sourceSha256}.exe`);
    assert.equal(assets.metadata, `OpenPath-NativeHost-${sourceSha256}.signing.json`);

    const executableBytes = Buffer.from('signed-exe');
    const executablePath = path.join(path.dirname(sourcePath), 'signed-test.exe');
    const metadataPath = path.join(path.dirname(sourcePath), 'signed-test.json');
    writeFileSync(executablePath, executableBytes);
    writeFileSync(
      metadataPath,
      JSON.stringify({ sourceSha256, executableSha256: sha256(executableBytes) })
    );
    assert.equal(validateSigningMetadata({ sourceSha256, executablePath, metadataPath }).ok, true);

    writeFileSync(metadataPath, JSON.stringify({ sourceSha256, executableSha256: 'deadbeef' }));
    assert.equal(validateSigningMetadata({ sourceSha256, executablePath, metadataPath }).ok, false);

    writeFileSync(
      metadataPath,
      JSON.stringify({ sourceSha256: 'other', executableSha256: sha256(executableBytes) })
    );
    assert.equal(validateSigningMetadata({ sourceSha256, executablePath, metadataPath }).ok, false);
  });
});

test('fetchSignedNativeHost is a no-op when the release or the hash assets are missing', () => {
  withRepo(({ root, sourcePath }) => {
    const missingRelease = fetchSignedNativeHost({
      repoRoot: root,
      runGh: () => {
        throw new Error('HTTP 404');
      },
      log: () => {},
    });
    assert.equal(missingRelease.signed, false);
    assert.equal(missingRelease.sourceSha256, sha256File(sourcePath));

    const missingAssets = fetchSignedNativeHost({
      repoRoot: root,
      runGh: () => 'OpenPath-NativeHost-otherhash.exe\n',
      log: () => {},
    });
    assert.equal(missingAssets.signed, false);
    assert.equal(existsSync(path.join(root, 'windows', 'native-host', 'signed')), false);
  });
});

test('fetchSignedNativeHost stages a validated pair into windows/native-host/signed', () => {
  withRepo(({ root, sourcePath }) => {
    const sourceSha256 = sha256File(sourcePath);
    const assets = signedAssetNames(sourceSha256);
    const executableBytes = Buffer.from('signed-exe-bytes');
    const metadata = {
      sourceSha256,
      executableSha256: sha256(executableBytes),
      signerSubject: 'CN=SignPath Foundation',
      signerIssuer: 'CN=SignPath Issuing CA',
      timestamped: true,
    };
    const runGh = (args) => {
      if (args[0] === 'api') {
        return `${assets.executable}\n${assets.metadata}\n`;
      }
      if (args[0] === 'release' && args[1] === 'download') {
        const dir = args[args.indexOf('--dir') + 1];
        writeFileSync(path.join(dir, assets.executable), executableBytes);
        writeFileSync(path.join(dir, assets.metadata), JSON.stringify(metadata));
        return '';
      }
      throw new Error(`unexpected gh args: ${args.join(' ')}`);
    };

    const result = fetchSignedNativeHost({ repoRoot: root, runGh, log: () => {} });
    assert.equal(result.signed, true);
    assert.equal(result.executableSha256, sha256(executableBytes));
    const signedRoot = path.join(root, 'windows', 'native-host', 'signed');
    assert.equal(
      sha256File(path.join(signedRoot, SIGNED_EXECUTABLE_NAME)),
      sha256(executableBytes)
    );
    const stagedMetadata = JSON.parse(
      readFileSync(path.join(signedRoot, SIGNED_METADATA_NAME), 'utf8')
    );
    assert.equal(stagedMetadata.signerSubject, metadata.signerSubject);
  });
});

test('fetchSignedNativeHost rejects a tampered pair instead of staging it', () => {
  withRepo(({ root, sourcePath }) => {
    const sourceSha256 = sha256File(sourcePath);
    const assets = signedAssetNames(sourceSha256);
    const runGh = (args) => {
      if (args[0] === 'api') {
        return `${assets.executable}\n${assets.metadata}\n`;
      }
      const dir = args[args.indexOf('--dir') + 1];
      writeFileSync(path.join(dir, assets.executable), Buffer.from('tampered-exe'));
      writeFileSync(
        path.join(dir, assets.metadata),
        JSON.stringify({ sourceSha256, executableSha256: sha256(Buffer.from('original-exe')) })
      );
      return '';
    };

    assert.throws(
      () => fetchSignedNativeHost({ repoRoot: root, runGh, log: () => {} }),
      /does not match its metadata/
    );
    assert.equal(existsSync(path.join(root, 'windows', 'native-host', 'signed')), false);
  });
});

test('resolveNativeHostSigning reports nativeHostSigned for a consistent staged pair', () => {
  withRepo(({ root, sourcePath }) => {
    const sourceSha256 = sha256File(sourcePath);
    const signedRoot = path.join(root, 'windows', 'native-host', 'signed');
    mkdirSync(signedRoot, { recursive: true });

    assert.deepEqual(resolveNativeHostSigning(root), {
      nativeHostSigned: false,
      nativeHostSourceSha256: sourceSha256,
    });

    const executableBytes = Buffer.from('signed-exe');
    writeFileSync(path.join(signedRoot, SIGNED_EXECUTABLE_NAME), executableBytes);
    writeFileSync(
      path.join(signedRoot, SIGNED_METADATA_NAME),
      JSON.stringify({
        sourceSha256,
        executableSha256: sha256(executableBytes),
        signerSubject: 'CN=SignPath Foundation',
        signerIssuer: 'CN=SignPath Issuing CA',
        timestamped: true,
      })
    );
    const signed = resolveNativeHostSigning(root);
    assert.equal(signed.nativeHostSigned, true);
    assert.equal(signed.nativeHostExecutableSha256, sha256(executableBytes));
    assert.equal(signed.nativeHostSignerSubject, 'CN=SignPath Foundation');
    assert.equal(signed.nativeHostTimestamped, true);

    writeFileSync(
      path.join(signedRoot, SIGNED_METADATA_NAME),
      JSON.stringify({ sourceSha256: 'other', executableSha256: sha256(executableBytes) })
    );
    const mismatched = resolveNativeHostSigning(root);
    assert.equal(mismatched.nativeHostSigned, false);
    assert.match(mismatched.error, /was built from other/);
  });
});
