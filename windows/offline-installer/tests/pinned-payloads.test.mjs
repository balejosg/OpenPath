import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import { downloadPinnedPayloads } from '../scripts/download-pinned-payloads.mjs';

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

async function withPins(run) {
  const root = await mkdtemp(path.join(tmpdir(), 'openpath-pinned-payloads-'));
  try {
    const pinsPath = path.join(root, 'payload-pins.json');
    const payloadsDir = path.join(root, 'payloads');
    await run({ root, pinsPath, payloadsDir });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test('downloads only the exact HTTPS pin and skips a verified cached file', async () => {
  await withPins(async ({ pinsPath, payloadsDir }) => {
    const bytes = Buffer.from('pinned-payload');
    await writeFile(
      pinsPath,
      JSON.stringify({
        acrylic: {
          manifestPath: 'payloads/acrylic/Acrylic-Portable.zip',
          sha256: sha256(bytes),
          downloadUrls: ['https://github.com/example/release/download/v1/payload.zip'],
        },
      })
    );
    const calls = [];
    const fetchImpl = async (url, init) => {
      calls.push({ url, init });
      return new Response(bytes, { status: 200 });
    };

    const first = await downloadPinnedPayloads({ pinsPath, payloadsDir, fetchImpl });
    const second = await downloadPinnedPayloads({ pinsPath, payloadsDir, fetchImpl });

    assert.equal(first[0].status, 'downloaded');
    assert.equal(second[0].status, 'cached');
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, 'https://github.com/example/release/download/v1/payload.zip');
    assert.equal(calls[0].init.redirect, 'follow');
    assert.deepEqual(
      await readFile(path.join(payloadsDir, 'payloads/acrylic/Acrylic-Portable.zip')),
      bytes
    );
  });
});

test('does not publish bytes whose digest differs from the pin', async () => {
  await withPins(async ({ pinsPath, payloadsDir }) => {
    const expected = Buffer.from('expected');
    await writeFile(
      pinsPath,
      JSON.stringify({
        firefox: {
          manifestPath: 'payloads/firefox/Firefox.exe',
          sha256: sha256(expected),
          downloadUrls: ['https://download.mozilla.org/releases/v1/Firefox.exe'],
        },
      })
    );

    await assert.rejects(
      () =>
        downloadPinnedPayloads({
          pinsPath,
          payloadsDir,
          fetchImpl: () => Promise.resolve(new Response('wrong bytes', { status: 200 })),
        }),
      /sha256 mismatch/u
    );
  });
});

test('rejects mutable latest or branch payload URLs', async () => {
  await withPins(async ({ pinsPath, payloadsDir }) => {
    const bytes = Buffer.from('payload');
    await writeFile(
      pinsPath,
      JSON.stringify({
        mutable: {
          manifestPath: 'payload.exe',
          sha256: sha256(bytes),
          downloadUrls: ['https://github.com/example/repo/archive/main/payload.exe'],
        },
      })
    );

    await assert.rejects(
      () => downloadPinnedPayloads({ pinsPath, payloadsDir, fetchImpl: () => Promise.resolve() }),
      /immutable release asset/u
    );
  });
});
