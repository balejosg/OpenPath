#!/usr/bin/env tsx

import 'dotenv/config';

import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  formatProvisionResult,
  provisionWindowsOfflineInstallerTemplate,
} from '../src/services/windows-offline-installer-provision.service.js';

function isEntrypoint(): boolean {
  return (
    process.argv[1] !== undefined &&
    path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
  );
}

async function main(): Promise<void> {
  const verifyOnly = process.argv.slice(2).includes('--verify-only');
  try {
    const result = await provisionWindowsOfflineInstallerTemplate({ verifyOnly });
    console.log(formatProvisionResult(result));
  } catch (error) {
    const code =
      error instanceof Error && 'code' in error ? String(error.code) : 'PROVISION_FAILED';
    console.error(JSON.stringify({ status: 'failed', code }));
    process.exitCode = 1;
  }
}

if (isEntrypoint()) {
  await main();
}
