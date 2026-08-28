#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const REPLAY_DEADLINE_MS = 2_000;

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

async function parseJson(response) {
  try {
    return await response.json();
  } catch {
    throw new Error('invalid-json');
  }
}

async function generateInstaller({ baseUrl, accessToken, classroomId, fetchImpl = fetch }) {
  let response;
  try {
    response = await fetchImpl(`${baseUrl}/trpc/windowsOfflineInstaller.generate`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ classroomId }),
    });
  } catch {
    throw new Error('generation-network-error');
  }
  const body = await parseJson(response);
  if (!response.ok) {
    const status = Number(response.status);
    if (Number.isInteger(status) && status >= 400 && status <= 599) {
      throw new Error(`generation-status-${String(status)}`);
    }
    throw new Error('generation-failed');
  }
  if (!body.result?.data) throw new Error('generation-invalid-response');
  return body.result.data;
}

async function downloadAndVerify({
  downloadUrl,
  expectedSha256,
  baseUrl,
  downloadBaseUrl,
  outputPath,
  fetchImpl = fetch,
}) {
  const publicUrl = new URL(downloadUrl, `${baseUrl}/`);
  const resolvedUrl = downloadBaseUrl
    ? new URL(
        `${publicUrl.pathname}${publicUrl.search}`,
        `${downloadBaseUrl.replace(/\/+$/u, '')}/`
      ).href
    : publicUrl.href;
  let response;
  try {
    response = await fetchImpl(resolvedUrl);
  } catch {
    throw new Error('download-network-error');
  }
  if (response.status !== 200) throw new Error(`download-status-${String(response.status)}`);
  if (response.headers.get('content-type') !== 'application/octet-stream') {
    throw new Error('download-content-type');
  }
  if (!(response.headers.get('content-disposition') ?? '').toLowerCase().includes('.exe')) {
    throw new Error('download-content-disposition');
  }
  if (response.headers.get('cache-control') !== 'no-store') {
    throw new Error('download-cache-control');
  }
  if (response.headers.get('x-content-type-options') !== 'nosniff') {
    throw new Error('download-nosniff');
  }
  let bytes;
  try {
    bytes = Buffer.from(await response.arrayBuffer());
  } catch {
    throw new Error('download-body-error');
  }
  const contentLength = response.headers.get('content-length');
  if (
    contentLength !== null &&
    (!/^\d+$/u.test(contentLength) || Number(contentLength) !== bytes.length)
  ) {
    throw new Error('download-content-length');
  }
  const actualSha256 = sha256(bytes);
  if (bytes.length === 0 || actualSha256 !== expectedSha256) {
    throw new Error('download-checksum');
  }
  if (outputPath) await writeFile(outputPath, bytes, { mode: 0o600 });
  return {
    bytes,
    contentLength: bytes.length,
    actualSha256,
    resolvedUrl,
  };
}

async function waitForConsumed({
  resolvedUrl,
  fetchImpl = fetch,
  nowImpl = Date.now,
  sleepImpl = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  replayDeadlineMs = REPLAY_DEADLINE_MS,
}) {
  const deadline = nowImpl() + replayDeadlineMs;
  let lastStatus = 0;
  do {
    let response;
    try {
      response = await fetchImpl(resolvedUrl);
    } catch {
      throw new Error('replay-network-error');
    }
    lastStatus = response.status;
    if (response.status === 410) return;
    if (response.status === 200) {
      try {
        await response.arrayBuffer();
      } catch {
        throw new Error('replay-body-error');
      }
    } else {
      throw new Error(`replay-status-${String(response.status)}`);
    }
    if (nowImpl() < deadline) await sleepImpl(100);
  } while (nowImpl() < deadline);

  throw new Error(`replay-not-consumed-${String(lastStatus)}`);
}

export async function runWindowsOfflineInstallerCanary({
  baseUrl,
  accessToken,
  classroomId,
  downloadBaseUrl,
  outputPath,
  fetchImpl = fetch,
  nowImpl = Date.now,
  sleepImpl = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  replayDeadlineMs = REPLAY_DEADLINE_MS,
}) {
  const result = await generateInstaller({ baseUrl, accessToken, classroomId, fetchImpl });
  const { resolvedUrl, contentLength, actualSha256 } = await downloadAndVerify({
    downloadUrl: result.downloadUrl,
    expectedSha256: result.sha256,
    baseUrl,
    downloadBaseUrl,
    outputPath,
    fetchImpl,
  });
  await waitForConsumed({
    resolvedUrl,
    fetchImpl,
    nowImpl,
    sleepImpl,
    replayDeadlineMs,
  });
  return {
    status: 'ok',
    version: result.version,
    fileName: result.fileName,
    bytesVerified: true,
    downloadStatus: 200,
    downloadBytes: contentLength,
    downloadSha256: actualSha256,
    headersVerified: true,
    replayStatus: 410,
  };
}

async function main() {
  const result = await runWindowsOfflineInstallerCanary({
    baseUrl: requiredEnv('OPENPATH_CANARY_BASE_URL').replace(/\/+$/u, ''),
    accessToken: requiredEnv('OPENPATH_CANARY_ACCESS_TOKEN'),
    classroomId: requiredEnv('OPENPATH_CANARY_CLASSROOM_ID'),
    downloadBaseUrl: process.env.OPENPATH_CANARY_DOWNLOAD_BASE_URL?.trim(),
    outputPath: process.env.OPENPATH_CANARY_OUTPUT_PATH?.trim(),
  });
  console.log(JSON.stringify(result));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await main();
  } catch (error) {
    const code =
      error instanceof Error && /^[a-z0-9-]+$/u.test(error.message)
        ? error.message
        : 'canary-failed';
    console.error(JSON.stringify({ status: 'failed', code }));
    process.exitCode = 1;
  }
}
