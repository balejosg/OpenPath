import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import process from 'node:process';
import { test } from 'node:test';

import { projectRoot } from './support.mjs';

test('Linux student-policy local wrapper dry-run plans the CI-equivalent npm command', () => {
  const output = execFileSync(
    process.execPath,
    ['scripts/run-linux-student-policy-local.mjs', '--suite', 'path-blocking'],
    {
      cwd: projectRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        OPENPATH_LINUX_STUDENT_LOCAL_DRY_RUN: '1',
      },
    }
  );

  assert.match(
    output,
    /OPENPATH_STUDENT_ARTIFACTS_DIR=tests\/e2e\/artifacts\/linux-student-policy-local/
  );
  assert.match(output, /OPENPATH_STUDENT_API_PORT=\d+/);
  assert.match(output, /OPENPATH_STUDENT_FIXTURE_PORT=\d+/);
  assert.match(output, /OPENPATH_STUDENT_SCENARIO_GROUP=path-blocking/);
  assert.match(output, /npm run test:student-policy:linux/);
  assert.doesNotMatch(output, /docker (compose|run|build)/);
});
