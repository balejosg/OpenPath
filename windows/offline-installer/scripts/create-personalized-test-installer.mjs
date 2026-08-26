#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { applyOverlay } from '../../../api/src/lib/windows-offline-installer.ts';

function parseArgs(argv) {
  const args = {};
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) continue;
    const key = argument.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`${argument} requires a value`);
    args[key] = value;
    index += 1;
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv);
  for (const name of ['template', 'output', 'config']) {
    if (!args[name]) throw new Error(`--${name} is required`);
  }

  const config = JSON.parse(readFileSync(resolve(args.config), 'utf8'));
  await applyOverlay(resolve(args.template), resolve(args.output), config);
  console.log(`Created personalized installer at ${resolve(args.output)}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
