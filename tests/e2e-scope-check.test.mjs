import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { describe, test } from 'node:test';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { E2E_IRRELEVANT_RULES, classifyFile, decideE2eScope } from '../scripts/lib/e2e-scope.mjs';
import { runCli } from '../scripts/e2e-scope-check.mjs';

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

describe('runCli (scripts/e2e-scope-check.mjs)', () => {
  function makeStream() {
    return {
      data: '',
      write(chunk) {
        this.data += chunk;
        return true;
      },
    };
  }

  test('docs-only range -> prints report to stderr and exactly "skip" to stdout', () => {
    const stdout = makeStream();
    const stderr = makeStream();
    // docs/a.md hits docs/** (first match wins); README.md falls through to **/*.md
    const gitExec = makeGitExec(rangeResponses('docs/a.md\0README.md\0'));

    const decision = runCli({
      env: { OPENPATH_PREPUSH_REMOTE_SHA: SHA_A, OPENPATH_PREPUSH_LOCAL_SHA: SHA_B },
      gitExec,
      stdout,
      stderr,
    });

    assert.equal(decision, 'skip');
    assert.equal(stdout.data, 'skip\n', 'stdout must carry only the machine-readable word');
    assert.match(stderr.data, /e2e scope: SKIP -- all 2 changed file\(s\) matched/);
    assert.match(stderr.data, /docs\/\*\* {2}docs\/a\.md/);
    assert.match(stderr.data, /\*\*\/\*\.md {2}README\.md/);
  });

  test('mixed range -> "run" naming the first e2e-relevant file', () => {
    const stdout = makeStream();
    const stderr = makeStream();
    const gitExec = makeGitExec(rangeResponses('docs/a.md\0api/src/index.ts\0'));

    const decision = runCli({
      env: { OPENPATH_PREPUSH_REMOTE_SHA: SHA_A, OPENPATH_PREPUSH_LOCAL_SHA: SHA_B },
      gitExec,
      stdout,
      stderr,
    });

    assert.equal(decision, 'run');
    assert.equal(stdout.data, 'run\n');
    assert.match(
      stderr.data,
      /e2e scope: RUN -- changed file is e2e-relevant: api\/src\/index\.ts/
    );
    assert.match(stderr.data, /e2e-relevant {2}api\/src\/index\.ts/);
  });

  test('OPENPATH_VERIFY_E2E=1 -> "run" without touching git', () => {
    const stdout = makeStream();
    const stderr = makeStream();
    const gitExec = () => {
      throw new Error('gitExec should not be called when e2e is forced');
    };

    const decision = runCli({
      env: {
        OPENPATH_PREPUSH_REMOTE_SHA: SHA_A,
        OPENPATH_PREPUSH_LOCAL_SHA: SHA_B,
        OPENPATH_VERIFY_E2E: '1',
      },
      gitExec,
      stdout,
      stderr,
    });

    assert.equal(decision, 'run');
    assert.match(stderr.data, /forced by OPENPATH_VERIFY_E2E=1/);
  });

  test('no range in env (manual invocation) -> "run"', () => {
    const stdout = makeStream();
    const stderr = makeStream();

    const decision = runCli({ env: {}, gitExec: makeGitExec([]), stdout, stderr });

    assert.equal(decision, 'run');
    assert.match(stderr.data, /no pushed range provided/);
  });

  test('whitespace around env SHAs is trimmed', () => {
    const stdout = makeStream();
    const stderr = makeStream();
    const gitExec = makeGitExec(rangeResponses('docs/a.md\0'));

    const decision = runCli({
      env: {
        OPENPATH_PREPUSH_REMOTE_SHA: ` ${SHA_A}\n`,
        OPENPATH_PREPUSH_LOCAL_SHA: `${SHA_B} `,
      },
      gitExec,
      stdout,
      stderr,
    });

    assert.equal(decision, 'skip');
  });
});

describe('e2e-scope-check.mjs CLI integration (scratch git repo, real git)', () => {
  const CLI_PATH = fileURLToPath(new URL('../scripts/e2e-scope-check.mjs', import.meta.url));

  function initScratchRepo() {
    const repo = mkdtempSync(join(tmpdir(), 'e2e-scope-'));
    const git = (...args) =>
      execFileSync(
        'git',
        ['-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', ...args],
        { cwd: repo, encoding: 'utf8' }
      );
    git('init', '-q');
    mkdirSync(join(repo, 'docs'));
    mkdirSync(join(repo, 'react-spa'));
    writeFileSync(join(repo, 'docs', 'a.md'), 'base\n');
    writeFileSync(join(repo, 'react-spa', 'app.ts'), 'export const x = 1;\n');
    git('add', '.');
    git('commit', '-q', '-m', 'base');
    return { repo, git };
  }

  function runCliProcess(repo, remoteSha, localSha) {
    return execFileSync(process.execPath, [CLI_PATH], {
      cwd: repo,
      encoding: 'utf8',
      env: {
        ...process.env,
        OPENPATH_VERIFY_E2E: '0',
        OPENPATH_PREPUSH_REMOTE_SHA: remoteSha,
        OPENPATH_PREPUSH_LOCAL_SHA: localSha,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  }

  test('docs-only commit -> skip; SPA commit -> run', () => {
    const { repo, git } = initScratchRepo();
    try {
      const baseSha = git('rev-parse', 'HEAD').trim();

      writeFileSync(join(repo, 'docs', 'a.md'), 'docs change\n');
      git('add', '.');
      git('commit', '-q', '-m', 'docs only');
      const docsSha = git('rev-parse', 'HEAD').trim();

      writeFileSync(join(repo, 'react-spa', 'app.ts'), 'export const x = 2;\n');
      git('add', '.');
      git('commit', '-q', '-m', 'spa change');
      const spaSha = git('rev-parse', 'HEAD').trim();

      assert.equal(runCliProcess(repo, baseSha, docsSha).trim(), 'skip');
      assert.equal(runCliProcess(repo, baseSha, spaSha).trim(), 'run');
      assert.equal(runCliProcess(repo, docsSha, spaSha).trim(), 'run');
    } finally {
      rmSync(repo, { recursive: true, force: true });
    }
  });

  test('remote SHA missing from the local object store -> run', () => {
    const { repo, git } = initScratchRepo();
    try {
      const localSha = git('rev-parse', 'HEAD').trim();
      const unknownSha = 'f'.repeat(40);

      assert.equal(runCliProcess(repo, unknownSha, localSha).trim(), 'run');
    } finally {
      rmSync(repo, { recursive: true, force: true });
    }
  });
});
