#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { parseArgs, validateEvidence } from './lib/windows-desktop-survival-evidence.mjs';

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const aggregate = JSON.parse(readFileSync(options.evidence, 'utf8'));
  const result = validateEvidence(
    aggregate,
    {
      sourceSha: options['source-sha'],
      templateSha256: options['template-sha256'],
      personalizedExeSha256: options['personalized-exe-sha256'],
      runId: options['run-id'],
      runAttempt: options['run-attempt'],
    },
    { evidenceRoot: options['evidence-root'] }
  );
  process.stdout.write('Windows Desktop Survival evidence valid (schema v2)\n');
  return result;
}

try {
  main();
} catch (error) {
  process.stderr.write(String(error?.message ?? error) + '\n');
  process.exitCode = 1;
}

export { main };
