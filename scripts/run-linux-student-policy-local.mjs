#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import process from 'node:process';

const allowedSuites = new Set(['full', 'request-lifecycle', 'path-blocking', 'exemptions']);

const defaultArtifactDir = 'tests/e2e/artifacts/linux-student-policy-local';
const defaultApiPort = 3101 + (process.pid % 1000);
const defaultFixturePort = 18081 + (process.pid % 1000);

function usage() {
  return [
    'Usage: node scripts/run-linux-student-policy-local.mjs [options]',
    '',
    'Options:',
    '  --suite <full|request-lifecycle|path-blocking|exemptions>',
    '  --artifact-dir <path>',
    '  --api-port <port>',
    '  --fixture-port <port>',
    '  --image-tag <tag>',
    '  --dry-run',
  ].join('\n');
}

function readOption(args, index, name) {
  const value = args[index + 1];
  if (!value || value.startsWith('--')) {
    throw new Error(`${name} requires a value`);
  }
  return value;
}

function parseArgs(args) {
  const options = {
    artifactDir: defaultArtifactDir,
    apiPort: String(defaultApiPort),
    fixturePort: String(defaultFixturePort),
    dryRun: process.env.OPENPATH_LINUX_STUDENT_LOCAL_DRY_RUN === '1',
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];

    if (arg === '--suite') {
      options.suite = readOption(args, index, arg);
      index += 1;
      continue;
    }

    if (arg === '--artifact-dir') {
      options.artifactDir = readOption(args, index, arg);
      index += 1;
      continue;
    }

    if (arg === '--api-port') {
      options.apiPort = readOption(args, index, arg);
      index += 1;
      continue;
    }

    if (arg === '--fixture-port') {
      options.fixturePort = readOption(args, index, arg);
      index += 1;
      continue;
    }

    if (arg === '--image-tag') {
      options.imageTag = readOption(args, index, arg);
      index += 1;
      continue;
    }

    if (arg === '--dry-run') {
      options.dryRun = true;
      continue;
    }

    if (arg === '--help' || arg === '-h') {
      options.help = true;
      continue;
    }

    throw new Error(`Unknown option: ${arg}`);
  }

  if (options.suite && !allowedSuites.has(options.suite)) {
    throw new Error(`Unsupported suite: ${options.suite}`);
  }

  return options;
}

function buildEnv(options) {
  const env = {
    OPENPATH_STUDENT_ARTIFACTS_DIR: options.artifactDir,
    OPENPATH_STUDENT_API_PORT: options.apiPort,
    OPENPATH_STUDENT_FIXTURE_PORT: options.fixturePort,
  };

  if (options.suite && options.suite !== 'full') {
    env.OPENPATH_STUDENT_SCENARIO_GROUP = options.suite;
  }

  if (options.imageTag) {
    env.OPENPATH_STUDENT_E2E_IMAGE_TAG = options.imageTag;
  }

  return env;
}

function printPlan(env) {
  for (const [key, value] of Object.entries(env)) {
    console.log(`${key}=${value}`);
  }
  console.log('npm run test:student-policy:linux');
}

try {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    process.exit(0);
  }

  const env = buildEnv(options);

  if (options.dryRun) {
    printPlan(env);
    process.exit(0);
  }

  const result = spawnSync('npm', ['run', 'test:student-policy:linux'], {
    stdio: 'inherit',
    env: {
      ...process.env,
      ...env,
    },
    shell: process.platform === 'win32',
  });

  if (result.error) {
    throw result.error;
  }

  process.exit(result.status ?? 1);
} catch (error) {
  console.error(error.message);
  console.error('');
  console.error(usage());
  process.exit(1);
}
