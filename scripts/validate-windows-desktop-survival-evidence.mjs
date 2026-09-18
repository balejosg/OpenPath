#!/usr/bin/env node

import { readFileSync } from 'node:fs';

const SHA40 = /^[0-9a-f]{40}$/i;
const SHA64 = /^[0-9a-f]{64}$/i;
const REQUIRED_PHASES = ['prepare', 'observe', 'afterReboot', 'cleanup'];
const REQUIRED_PASSED_FIELDS = [
  'preRebootAdminDesktop',
  'firstStudentInteractiveLogon',
  'preRebootStudentBoundary',
  'loginScreenAfterReboot',
  'postRebootAdminDesktop',
  'postRebootStudentDesktop',
  'postRebootStudentBoundary',
  'uninstallOrRollback',
  'cleanup',
];

function fail(message) {
  throw new Error(`Windows Desktop Survival evidence rejected: ${message}`);
}

function requiredString(value, field) {
  if (typeof value !== 'string' || value.trim() === '') fail(`${field} must be a non-empty string`);
  return value;
}

function requiredPass(value, field) {
  if (value !== 'passed') fail(`${field} must be "passed"`);
}

function validateScenario(scenario, expected, index = null) {
  const label = index === null ? '' : `scenario[${index}].`;
  if (!scenario || typeof scenario !== 'object' || Array.isArray(scenario))
    fail(`${label}must be an object`);
  if (scenario.schemaVersion !== 1) fail(`${label}schemaVersion must be 1`);
  if (scenario.sourceCommitSha !== expected.sourceSha) fail(`${label}sourceCommitSha mismatch`);
  if (scenario.templateSha256 !== expected.templateSha256) fail(`${label}templateSha256 mismatch`);
  if (scenario.personalizedExeSha256 !== expected.personalizedExeSha256)
    fail(`${label}personalizedExeSha256 mismatch`);
  if (scenario.runId !== expected.runId) fail(`${label}runId mismatch`);
  for (const [field, pattern] of [
    ['sourceCommitSha', SHA40],
    ['templateSha256', SHA64],
    ['personalizedExeSha256', SHA64],
    ['policyBeforeSha256', SHA64],
    ['policyAfterSha256', SHA64],
  ]) {
    requiredString(scenario[field], `${label}${field}`);
    if (!pattern.test(scenario[field])) fail(`${label}${field} is not a complete SHA`);
  }
  if (typeof scenario.generatedAt !== 'string' || Number.isNaN(Date.parse(scenario.generatedAt)))
    fail(`${label}generatedAt is invalid`);
  const generatedAt = Date.parse(scenario.generatedAt);
  if (
    generatedAt > Date.now() + 5 * 60 * 1000 ||
    generatedAt < Date.now() - 7 * 24 * 60 * 60 * 1000
  )
    fail(`${label}evidence run is too old or from the future`);
  if (!scenario.os || scenario.os.productType !== 'client')
    fail(`${label}OS must be Windows client`);
  for (const field of ['edition', 'build', 'architecture'])
    requiredString(scenario.os[field], `${label}os.${field}`);
  if (scenario.appControlProfile !== 'StrictApplicationAllowlist')
    fail(`${label}appControlProfile is not strict`);
  if (
    typeof scenario.catalogApplicationCount !== 'number' ||
    !Number.isInteger(scenario.catalogApplicationCount) ||
    scenario.catalogApplicationCount < 0
  )
    fail(`${label}catalogApplicationCount must be an integer`);
  if (typeof scenario.initialProfileExisted !== 'boolean')
    fail(`${label}initialProfileExisted must be boolean`);
  requiredString(scenario.bootIdBefore, `${label}bootIdBefore`);
  requiredString(scenario.bootIdAfter, `${label}bootIdAfter`);
  if (scenario.bootIdBefore === scenario.bootIdAfter)
    fail(`${label}boot ids must differ after reboot`);
  for (const field of REQUIRED_PASSED_FIELDS) requiredPass(scenario[field], `${label}${field}`);
  if (
    !Array.isArray(scenario.criticalUnexpectedDenials) ||
    scenario.criticalUnexpectedDenials.length !== 0
  )
    fail(`${label}criticalUnexpectedDenials must be empty`);
  const fixtures = scenario.fixtures;
  if (!fixtures || typeof fixtures !== 'object') fail(`${label}fixtures are required`);
  for (const field of ['exeAndDll', 'msiAndScript', 'packagedAppExecution'])
    requiredPass(fixtures[field], `${label}fixtures.${field}`);
  const phases = scenario.phases;
  if (!phases || typeof phases !== 'object') fail(`${label}phases are required`);
  for (const phase of REQUIRED_PHASES) {
    const record = phases[phase];
    if (
      !record ||
      record.status !== 'passed' ||
      typeof record.evidenceRef !== 'string' ||
      record.evidenceRef.trim() === ''
    )
      fail(`${label}phase ${phase} lacks passed evidence`);
  }
  if (scenario.artifacts !== undefined) {
    if (!Array.isArray(scenario.artifacts) || scenario.artifacts.length === 0)
      fail(`${label}artifacts must be non-empty`);
    for (const artifact of scenario.artifacts) {
      requiredString(artifact.name, `${label}artifact.name`);
      if (!SHA64.test(artifact.sha256 ?? '')) fail(`${label}artifact hash is invalid`);
      if (
        artifact.name.toLowerCase().includes('template') &&
        artifact.sha256 !== scenario.templateSha256
      )
        fail(`${label}template artifact hash mismatch`);
      if (
        artifact.name.toLowerCase().includes('exe') &&
        artifact.sha256 !== scenario.personalizedExeSha256
      )
        fail(`${label}EXE artifact hash mismatch`);
    }
  }
  return { edition: scenario.os.edition, status: 'passed' };
}

export function validateEvidence(evidence, expected) {
  if (!evidence || typeof evidence !== 'object') fail('root evidence must be an object');
  const scenarios = Array.isArray(evidence.scenarios) ? evidence.scenarios : [evidence];
  if (scenarios.length === 0) fail('at least one scenario is required');
  const results = scenarios.map((scenario, index) =>
    validateScenario(scenario, expected, Array.isArray(evidence.scenarios) ? index : null)
  );
  if (Array.isArray(evidence.scenarios)) {
    const editions = new Set(results.map((result) => result.edition.toLowerCase()));
    if (
      !(
        [...editions].some((edition) => edition.includes('pro')) &&
        [...editions].some((edition) => edition.includes('education'))
      )
    )
      fail('the client edition matrix must include Pro and Education');
  }
  return { status: 'passed', scenarios: results };
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key.startsWith('--') || value === undefined) fail(`invalid argument ${key}`);
    options[key.slice(2)] = value;
    index += 1;
  }
  for (const key of [
    'evidence',
    'source-sha',
    'template-sha256',
    'personalized-exe-sha256',
    'run-id',
  ])
    if (!options[key]) fail(`--${key} is required`);
  return options;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const evidence = JSON.parse(readFileSync(options.evidence, 'utf8'));
    validateEvidence(evidence, {
      sourceSha: options['source-sha'],
      templateSha256: options['template-sha256'],
      personalizedExeSha256: options['personalized-exe-sha256'],
      runId: options['run-id'],
    });
    console.log('Windows Desktop Survival evidence valid');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
