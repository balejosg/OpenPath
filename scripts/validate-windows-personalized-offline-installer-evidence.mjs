#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import {
  parseArgs,
  validateEvidence,
} from './lib/windows-personalized-offline-installer-evidence.mjs';

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  let evidence;
  try {
    evidence = JSON.parse(readFileSync(options.evidence, 'utf8'));
  } catch {
    throw new Error(
      'Windows personalized offline installer evidence rejected: evidence is not valid JSON'
    );
  }
  const result = validateEvidence(evidence);
  process.stdout.write('Windows personalized offline installer evidence valid\n');
  return result;
}

try {
  main();
} catch (error) {
  process.stderr.write(String(error?.message ?? error) + '\n');
  process.exitCode = 1;
}

export { main };
