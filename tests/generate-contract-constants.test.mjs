import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { test } from 'node:test';

import {
  GENERATED_TARGETS,
  loadContract,
  projectRoot,
} from '../scripts/generate-contract-constants.mjs';

test('contract constants generator matches committed includes', async () => {
  const contract = loadContract(projectRoot);
  for (const target of GENERATED_TARGETS) {
    const expected = await target.build(contract);
    const actual = readFileSync(resolve(projectRoot, target.path), 'utf8');

    assert.equal(actual, expected, `${target.path} should match the generated contract constants`);
  }
});
