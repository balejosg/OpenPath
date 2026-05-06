#!/usr/bin/env node

import { deriveAmoVersionFromPayloadHash } from './sign-firefox-release.mjs';

function parseCliArgs(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? '';
    const next = argv[index + 1] ?? '';

    switch (arg) {
      case '--payload-hash':
        return next;
      case '--help':
      case '-h':
        console.log(`Usage:
  node firefox-release-amo-version.mjs --payload-hash <sha256>
`);
        process.exit(0);
        break;
      default:
        if (!arg.startsWith('-')) {
          return arg;
        }
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return '';
}

try {
  process.stdout.write(deriveAmoVersionFromPayloadHash(parseCliArgs(process.argv.slice(2))));
} catch (error) {
  console.error(
    `[firefox-release-amo-version] ${error instanceof Error ? error.message : String(error)}`
  );
  process.exitCode = 1;
}
