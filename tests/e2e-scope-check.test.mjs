import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { E2E_IRRELEVANT_RULES, classifyFile, decideE2eScope } from '../scripts/lib/e2e-scope.mjs';

/**
 * Fake gitExec for decideE2eScope() tests: no live repo dependency.
 * `responses` is an ordered list of [matcher, outcome] pairs matched against the
 * space-joined git args (same pattern as tests/check-new-file-coverage.test.mjs).
 * `outcome` is either a string (stdout) or an Error to throw.
 */
function makeGitExec(responses) {
  const calls = [];
  const gitExec = (args) => {
    const key = args.join(' ');
    calls.push(key);

    for (const [matcher, outcome] of responses) {
      if (matcher.test(key)) {
        if (outcome instanceof Error) {
          throw outcome;
        }
        return outcome;
      }
    }

    throw new Error(`Unexpected git invocation in test: ${key}`);
  };
  gitExec.calls = calls;
  return gitExec;
}

const SHA_A = 'a'.repeat(40);
const SHA_B = 'b'.repeat(40);
const ZERO_SHA = '0'.repeat(40);

function rangeResponses(nulSeparatedNames) {
  return [
    [/^cat-file -e/, ''],
    [/^diff --name-only --no-renames -z/, nulSeparatedNames],
  ];
}

describe('classifyFile (scripts/lib/e2e-scope.mjs)', () => {
  const cases = [
    ['docs/HOWTO.txt', 'docs/**'],
    ['docs/testing/wedu-captive-portal-lab.md', 'docs/**'],
    ['README.md', '**/*.md'],
    ['api/README.md', '**/*.md'],
    ['linux/lib/dns-dnsmasq.sh', 'linux/**'],
    ['windows/lib/internal/Common.System.ps1', 'windows/**'],
    ['.github/workflows/ci.yml', '.github/**'],
    ['react-spa/src/App.tsx', null],
    ['api/src/index.ts', null],
    ['shared/src/index.ts', null],
    ['scripts/e2e-setup.sh', null],
    ['scripts/start-api-e2e.sh', null],
    ['package.json', null],
    ['package-lock.json', null],
    ['docker-compose.test.yml', null],
    ['patches/multimatch+6.0.0.patch', null],
    ['docs2/evil-prefix.txt', null],
    ['linux-notes.txt', null],
  ];

  for (const [file, expectedRule] of cases) {
    test(`classifies ${file} -> ${expectedRule ?? 'e2e-relevant'}`, () => {
      assert.deepEqual(classifyFile(file), { file, matchedRule: expectedRule });
    });
  }

  test('first match wins: docs/README.md matches docs/** before **/*.md', () => {
    assert.equal(classifyFile('docs/README.md').matchedRule, 'docs/**');
    assert.equal(E2E_IRRELEVANT_RULES[0].rule, 'docs/**');
    assert.equal(E2E_IRRELEVANT_RULES[1].rule, '**/*.md');
  });

  test('allowlist stays exactly the five evidence-derived rules', () => {
    assert.deepEqual(
      E2E_IRRELEVANT_RULES.map((entry) => entry.rule),
      ['docs/**', '**/*.md', 'linux/**', 'windows/**', '.github/**']
    );
  });
});

describe('decideE2eScope (scripts/lib/e2e-scope.mjs)', () => {
  test('requires an injected gitExec', () => {
    assert.throws(() => decideE2eScope({ remoteSha: SHA_A, localSha: SHA_B }), {
      message: /gitExec/,
    });
  });

  test('OPENPATH_VERIFY_E2E force flag -> run without consulting git', () => {
    const gitExec = () => {
      throw new Error('gitExec should not be called when e2e is forced');
    };

    const result = decideE2eScope({ remoteSha: SHA_A, localSha: SHA_B, forceE2e: true, gitExec });

    assert.equal(result.decision, 'run');
    assert.match(result.reason, /OPENPATH_VERIFY_E2E=1/);
  });

  test('missing range -> run', () => {
    const gitExec = makeGitExec([]);

    assert.equal(decideE2eScope({ remoteSha: '', localSha: SHA_B, gitExec }).decision, 'run');
    assert.equal(decideE2eScope({ remoteSha: SHA_A, localSha: '', gitExec }).decision, 'run');
    assert.equal(gitExec.calls.length, 0, 'no git calls without a full range');
  });

  test('malformed SHAs -> run', () => {
    const gitExec = makeGitExec([]);

    const result = decideE2eScope({ remoteSha: 'origin/main', localSha: 'HEAD', gitExec });

    assert.equal(result.decision, 'run');
    assert.match(result.reason, /not a pair of full SHAs/);
  });

  test('zero remote SHA (new remote ref) -> run', () => {
    const result = decideE2eScope({
      remoteSha: ZERO_SHA,
      localSha: SHA_B,
      gitExec: makeGitExec([]),
    });

    assert.equal(result.decision, 'run');
    assert.match(result.reason, /new remote ref/);
  });

  test('zero local SHA (ref deletion) -> run', () => {
    const result = decideE2eScope({
      remoteSha: SHA_A,
      localSha: ZERO_SHA,
      gitExec: makeGitExec([]),
    });

    assert.equal(result.decision, 'run');
    assert.match(result.reason, /deletion/);
  });

  test('remote SHA unknown locally (cat-file fails) -> run', () => {
    const gitExec = makeGitExec([[/^cat-file -e/, new Error('fatal: Not a valid object name')]]);

    const result = decideE2eScope({ remoteSha: SHA_A, localSha: SHA_B, gitExec });

    assert.equal(result.decision, 'run');
    assert.match(result.reason, /not present locally/);
  });

  test('git diff failure -> run', () => {
    const gitExec = makeGitExec([
      [/^cat-file -e/, ''],
      [/^diff /, new Error('fatal: bad revision')],
    ]);

    const result = decideE2eScope({ remoteSha: SHA_A, localSha: SHA_B, gitExec });

    assert.equal(result.decision, 'run');
    assert.match(result.reason, /diff failed/);
  });

  test('empty diff -> run (conservative)', () => {
    const gitExec = makeGitExec(rangeResponses(''));

    const result = decideE2eScope({ remoteSha: SHA_A, localSha: SHA_B, gitExec });

    assert.equal(result.decision, 'run');
    assert.match(result.reason, /empty diff/);
  });

  test('uses --no-renames and -z on the exact remote..local range', () => {
    const gitExec = makeGitExec(rangeResponses('docs/a.md\0'));

    decideE2eScope({ remoteSha: SHA_A, localSha: SHA_B, gitExec });

    assert.ok(gitExec.calls.includes(`cat-file -e ${SHA_A}^{commit}`));
    assert.ok(
      gitExec.calls.includes(`diff --name-only --no-renames -z ${SHA_A}..${SHA_B}`),
      `expected exact diff invocation, got: ${gitExec.calls.join(' | ')}`
    );
  });

  test('all files allowlisted -> skip, with per-file matched rules', () => {
    const gitExec = makeGitExec(
      rangeResponses(
        'docs/HOWTO.txt\0README.md\0linux/lib/dns.sh\0windows/agent.ps1\0.github/workflows/ci.yml\0'
      )
    );

    const result = decideE2eScope({ remoteSha: SHA_A, localSha: SHA_B, gitExec });

    assert.equal(result.decision, 'skip');
    assert.match(result.reason, /all 5 changed file\(s\) matched/);
    assert.deepEqual(result.classified, [
      { file: 'docs/HOWTO.txt', matchedRule: 'docs/**' },
      { file: 'README.md', matchedRule: '**/*.md' },
      { file: 'linux/lib/dns.sh', matchedRule: 'linux/**' },
      { file: 'windows/agent.ps1', matchedRule: 'windows/**' },
      { file: '.github/workflows/ci.yml', matchedRule: '.github/**' },
    ]);
  });

  test('one e2e-relevant file (even a deletion) poisons the skip -> run naming that file', () => {
    // --no-renames + --name-only lists deleted paths too, so a deleted SPA file lands here.
    const gitExec = makeGitExec(rangeResponses('docs/a.md\0react-spa/src/App.tsx\0docs/b.md\0'));

    const result = decideE2eScope({ remoteSha: SHA_A, localSha: SHA_B, gitExec });

    assert.equal(result.decision, 'run');
    assert.match(result.reason, /e2e-relevant: react-spa\/src\/App\.tsx/);
    assert.equal(result.classified.length, 3, 'classification is reported for every changed file');
  });
});
