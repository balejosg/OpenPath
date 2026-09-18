import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';

export const REQUIRED_PHASES = Object.freeze(['prepare', 'observe', 'afterReboot', 'cleanup']);
export const REQUIRED_SCENARIOS = Object.freeze([
  'win11-pro-profileless-empty',
  'win11-pro-existing-empty',
  'win11-education-profileless-empty',
  'win11-education-existing-empty',
]);
const SCENARIO_EXPECTATIONS = Object.freeze({
  'win11-pro-profileless-empty': { editionId: 'Professional', initialProfileExisted: false },
  'win11-pro-existing-empty': { editionId: 'Professional', initialProfileExisted: true },
  'win11-education-profileless-empty': { editionId: 'Education', initialProfileExisted: false },
  'win11-education-existing-empty': { editionId: 'Education', initialProfileExisted: true },
});
const SHA40 = /^[0-9a-f]{40}$/i;
const SHA64 = /^[0-9a-f]{64}$/i;
const SAFE_SEGMENT = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const REQUIRED_OBSERVATIONS = Object.freeze([
  'preRebootAdminDesktop',
  'firstStudentInteractiveLogon',
  'preRebootStudentBoundary',
  'loginScreenAfterReboot',
  'postRebootAdminDesktop',
  'postRebootStudentDesktop',
  'postRebootStudentBoundary',
  'uninstallOrRollback',
  'cleanup',
]);
const REQUIRED_FIXTURES = Object.freeze(['exeAndDll', 'msiAndScript', 'packagedAppExecution']);

function fail(message) {
  throw new Error('Windows Desktop Survival evidence rejected: ' + message);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function requiredString(value, field) {
  if (typeof value !== 'string' || value.trim() === '') fail(field + ' must be a non-empty string');
  return value;
}

function requiredSha(value, field, pattern = SHA64) {
  requiredString(value, field);
  if (!pattern.test(value)) fail(field + ' is not a complete SHA');
}

function requiredPassed(value, field) {
  if (value !== 'passed') fail(field + ' must be "passed"');
}

function hasPassed(container, field) {
  if (!isObject(container)) return false;
  if (container[field] === 'passed') return true;
  for (const parent of ['observations', 'requiredEvidence', 'checks']) {
    if (isObject(container[parent]) && container[parent][field] === 'passed') return true;
    if (
      isObject(container[parent]) &&
      isObject(container[parent][field]) &&
      container[parent][field].status === 'passed'
    )
      return true;
  }
  return false;
}

function nowValue(now) {
  return typeof now === 'function' ? now() : now instanceof Date ? now.getTime() : Date.now();
}

function validateFreshTimestamp(value, field, now) {
  requiredString(value, field);
  const parsed = Date.parse(value);
  if (Number.isNaN(parsed)) fail(field + ' is invalid');
  const current = nowValue(now);
  if (parsed > current + 5 * 60 * 1000 || parsed < current - 7 * 24 * 60 * 60 * 1000) {
    fail(field + ' is outside the accepted evidence window');
  }
}

function normalizeRelativeReference(reference, field) {
  requiredString(reference, field);
  if (reference.includes('\0')) fail(field + ' contains a NUL');
  const rawSegments = reference.split('/');
  if (rawSegments.some((segment) => segment === '..')) fail(field + ' contains a parent segment');
  if (
    reference.includes('\\') ||
    reference.includes('//') ||
    reference.startsWith('/') ||
    /^[A-Za-z]:/.test(reference) ||
    reference.startsWith('//')
  ) {
    fail(field + ' must be a relative POSIX path');
  }
  const normalized = path.posix.normalize(reference);
  if (
    normalized === '.' ||
    normalized.startsWith('../') ||
    normalized.includes('/../') ||
    normalized.startsWith('./') ||
    normalized.includes(':')
  ) {
    fail(field + ' escapes evidence root');
  }
  return normalized;
}

function hashBytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function fileRecord(root, relative, expectedHash, expectedSize, field) {
  const normalized = normalizeRelativeReference(relative, field);
  const rootReal = realpathSync(root);
  const absolute = path.resolve(rootReal, ...normalized.split('/'));
  const relativeCheck = path.relative(rootReal, absolute);
  if (
    relativeCheck === '' ||
    relativeCheck.startsWith('..' + path.sep) ||
    path.isAbsolute(relativeCheck)
  ) {
    fail(field + ' is outside evidence root');
  }
  let stat;
  try {
    if (lstatSync(absolute).isSymbolicLink()) fail(field + ' may not be a symlink');
    stat = statSync(absolute);
  } catch {
    fail(field + ' references a missing file');
  }
  if (!stat.isFile()) fail(field + ' must reference a regular file');
  const real = realpathSync(absolute);
  const realRelative = path.relative(rootReal, real);
  if (realRelative.startsWith('..' + path.sep) || path.isAbsolute(realRelative))
    fail(field + ' resolves outside evidence root');
  const bytes = readFileSync(absolute);
  if (
    expectedSize !== undefined &&
    (!Number.isInteger(expectedSize) || expectedSize < 0 || bytes.length !== expectedSize)
  ) {
    fail(field + ' size mismatch');
  }
  const actualHash = hashBytes(bytes);
  if (expectedHash !== undefined && actualHash !== expectedHash.toLowerCase())
    fail(field + ' hash mismatch');
  return { normalized, absolute, bytes, actualHash, size: bytes.length };
}

function validateManifest(manifest, expected, evidenceRoot, now) {
  if (!isObject(manifest)) fail('manifest must be an object');
  if (manifest.schemaVersion !== 2) fail('manifest schemaVersion must be 2');
  if (manifest.sourceCommitSha !== expected.sourceSha) fail('manifest sourceCommitSha mismatch');
  if (manifest.runId !== expected.runId) fail('manifest runId mismatch');
  if (manifest.runAttempt !== expected.runAttempt) fail('manifest runAttempt mismatch');
  validateFreshTimestamp(manifest.generatedAt, 'manifest.generatedAt', now);
  if (!Array.isArray(manifest.files) || manifest.files.length === 0)
    fail('manifest.files is required');
  const seen = new Set();
  for (const [index, entry] of manifest.files.entries()) {
    if (!isObject(entry)) fail('manifest.files[' + index + '] must be an object');
    const relative = entry.path ?? entry.relativePath;
    if (!Number.isInteger(entry.size) || entry.size < 0)
      fail('manifest.files[' + index + '].size is required');
    if (!SHA64.test(String(entry.sha256 ?? '')))
      fail('manifest.files[' + index + '].sha256 is invalid');
    const record = fileRecord(
      evidenceRoot,
      relative,
      entry.sha256,
      entry.size,
      'manifest.files[' + index + '].path'
    );
    if (seen.has(record.normalized)) fail('manifest contains duplicate file references');
    seen.add(record.normalized);
    if (record.normalized === 'manifest.json') fail('manifest must not include itself');
  }
  return seen;
}

function validatePhase(record, scenario, phase, expected, evidenceRoot, seenReferences, now) {
  const label = 'scenario[' + scenario.scenarioId + '].phases.' + phase;
  if (!isObject(record)) fail(label + ' must be an object');
  requiredPassed(record.status, label + '.status');
  requiredString(record.evidenceRef, label + '.evidenceRef');
  requiredSha(record.sha256, label + '.sha256');
  requiredString(record.correlationNonce, label + '.correlationNonce');
  validateFreshTimestamp(record.startedAt, label + '.startedAt', now);
  validateFreshTimestamp(record.endedAt, label + '.endedAt', now);
  if (Date.parse(record.endedAt) < Date.parse(record.startedAt))
    fail(label + ' chronology is invalid');
  const reference = fileRecord(
    evidenceRoot,
    record.evidenceRef,
    record.sha256,
    undefined,
    label + '.evidenceRef'
  );
  if (seenReferences.has(reference.normalized))
    fail(label + '.evidenceRef is shared by multiple records');
  seenReferences.add(reference.normalized);
  let observation;
  try {
    observation = JSON.parse(reference.bytes.toString('utf8'));
  } catch {
    fail(label + ' observation is not valid JSON');
  }
  if (!isObject(observation)) fail(label + ' observation must be an object');
  for (const [key, value] of [
    ['runId', expected.runId],
    ['runAttempt', expected.runAttempt],
    ['sourceCommitSha', expected.sourceSha],
    ['scenarioId', scenario.scenarioId],
    ['phase', phase],
  ]) {
    if (observation[key] !== value) fail(label + ' observation ' + key + ' mismatch');
  }
  if (observation.correlationNonce !== record.correlationNonce) fail(label + ' nonce mismatch');
  if (observation.status !== 'passed') fail(label + ' observation must be passed');
  if (observation.synthetic !== false || record.synthetic === true)
    fail(label + ' synthetic observations are not publishable');
  return observation;
}

function validateScenario(scenario, expected, evidenceRoot, seenReferences, now) {
  if (!isObject(scenario)) fail('scenario must be an object');
  requiredString(scenario.scenarioId, 'scenario.scenarioId');
  if (!SAFE_SEGMENT.test(scenario.scenarioId)) fail('scenarioId is unsafe');
  if (!REQUIRED_SCENARIOS.includes(scenario.scenarioId))
    fail('unexpected scenarioId ' + scenario.scenarioId);
  if (scenario.sourceCommitSha !== expected.sourceSha)
    fail(scenario.scenarioId + ' sourceCommitSha mismatch');
  if (scenario.templateSha256 !== expected.templateSha256)
    fail(scenario.scenarioId + ' templateSha256 mismatch');
  if (scenario.personalizedExeSha256 !== expected.personalizedExeSha256)
    fail(scenario.scenarioId + ' personalizedExeSha256 mismatch');
  requiredSha(scenario.sourceCommitSha, scenario.scenarioId + '.sourceCommitSha', SHA40);
  requiredSha(scenario.templateSha256, scenario.scenarioId + '.templateSha256');
  requiredSha(scenario.personalizedExeSha256, scenario.scenarioId + '.personalizedExeSha256');
  requiredSha(scenario.policyBeforeSha256, scenario.scenarioId + '.policyBeforeSha256');
  requiredSha(scenario.policyAfterSha256, scenario.scenarioId + '.policyAfterSha256');
  if (!isObject(scenario.os) || scenario.os.productType !== 'client')
    fail(scenario.scenarioId + ' OS must be a Windows client');
  if (!['Professional', 'Education'].includes(scenario.os.editionId))
    fail(scenario.scenarioId + ' editionId is not in the release matrix');
  const scenarioExpectation = SCENARIO_EXPECTATIONS[scenario.scenarioId];
  for (const field of ['version', 'build', 'architecture'])
    requiredString(scenario.os[field], scenario.scenarioId + '.os.' + field);
  requiredString(scenario.imageIdentity, scenario.scenarioId + '.imageIdentity');
  requiredString(scenario.snapshotIdentity, scenario.scenarioId + '.snapshotIdentity');
  if (/[/\\\\]|@|:/.test(scenario.snapshotIdentity))
    fail(scenario.scenarioId + ' snapshotIdentity is not sanitized');
  if (scenario.appControlProfile !== 'StrictApplicationAllowlist')
    fail(scenario.scenarioId + ' appControlProfile is not strict');
  if (scenario.catalogApplicationCount !== 0)
    fail(scenario.scenarioId + ' initial catalog must be empty');
  if (scenario.initialProfileExisted !== true && scenario.initialProfileExisted !== false)
    fail(scenario.scenarioId + ' initialProfileExisted must be boolean');
  if (scenario.os.editionId !== scenarioExpectation.editionId)
    fail(scenario.scenarioId + ' editionId does not match its scenario id');
  if (scenario.initialProfileExisted !== scenarioExpectation.initialProfileExisted)
    fail(scenario.scenarioId + ' profile-existence state does not match its scenario id');
  requiredString(scenario.bootIdBefore, scenario.scenarioId + '.bootIdBefore');
  requiredString(scenario.bootIdAfter, scenario.scenarioId + '.bootIdAfter');
  if (scenario.bootIdBefore === scenario.bootIdAfter)
    fail(scenario.scenarioId + ' boot ids must differ after reboot');
  if (scenario.synthetic !== false) fail(scenario.scenarioId + ' synthetic must be false');
  for (const field of REQUIRED_OBSERVATIONS)
    if (!hasPassed(scenario, field)) fail(scenario.scenarioId + '.' + field + ' must be passed');
  if (
    !Array.isArray(scenario.criticalUnexpectedDenials) ||
    scenario.criticalUnexpectedDenials.length !== 0
  )
    fail(scenario.scenarioId + '.criticalUnexpectedDenials must be empty');
  if (!isObject(scenario.fixtures)) fail(scenario.scenarioId + '.fixtures are required');
  for (const field of REQUIRED_FIXTURES)
    requiredPassed(scenario.fixtures[field], scenario.scenarioId + '.fixtures.' + field);
  if (!isObject(scenario.phases)) fail(scenario.scenarioId + '.phases are required');
  const phaseKeys = Object.keys(scenario.phases).sort();
  if (
    phaseKeys.length !== REQUIRED_PHASES.length ||
    REQUIRED_PHASES.some((phase) => !Object.prototype.hasOwnProperty.call(scenario.phases, phase))
  )
    fail(scenario.scenarioId + '.phases must contain exactly the canonical phases');
  const observations = {};
  for (const phase of REQUIRED_PHASES)
    observations[phase] = validatePhase(
      scenario.phases[phase],
      scenario,
      phase,
      expected,
      evidenceRoot,
      seenReferences,
      now
    );
  return {
    scenarioId: scenario.scenarioId,
    editionId: scenario.os.editionId,
    initialProfileExisted: scenario.initialProfileExisted,
    observations,
  };
}

export function validateEvidence(evidence, expected, options = {}) {
  if (!isObject(evidence)) fail('aggregate must be an object');
  if (evidence.schemaVersion !== 2)
    fail('schemaVersion 1 is historical and cannot qualify publication');
  if (evidence.sourceCommitSha !== expected.sourceSha) fail('sourceCommitSha mismatch');
  if (evidence.runId !== expected.runId) fail('runId mismatch');
  if (evidence.runAttempt !== expected.runAttempt) fail('runAttempt mismatch');
  requiredSha(evidence.sourceCommitSha, 'sourceCommitSha', SHA40);
  requiredSha(evidence.templateSha256, 'templateSha256');
  requiredSha(evidence.personalizedExeSha256, 'personalizedExeSha256');
  if (
    evidence.templateSha256 !== expected.templateSha256 ||
    evidence.personalizedExeSha256 !== expected.personalizedExeSha256
  )
    fail('aggregate binary hash mismatch');
  requiredSha(evidence.evidenceManifestSha256, 'evidenceManifestSha256');
  validateFreshTimestamp(evidence.generatedAt, 'generatedAt', options.now);
  if (evidence.synthetic !== false) fail('synthetic aggregate is not publishable');
  if (!Array.isArray(evidence.scenarios) || evidence.scenarios.length !== REQUIRED_SCENARIOS.length)
    fail('the complete four-scenario matrix is required');
  if (!options.evidenceRoot) fail('evidenceRoot is required for publication validation');
  const manifestPath = path.join(options.evidenceRoot, 'manifest.json');
  const manifestRecord = fileRecord(
    options.evidenceRoot,
    'manifest.json',
    evidence.evidenceManifestSha256,
    undefined,
    'manifest'
  );
  const manifest = (() => {
    try {
      return JSON.parse(manifestRecord.bytes.toString('utf8'));
    } catch {
      fail('manifest is not valid JSON');
    }
  })();
  const manifestFiles = validateManifest(manifest, expected, options.evidenceRoot, options.now);
  const seenIds = new Set();
  const seenReferences = new Set(['manifest.json']);
  const results = evidence.scenarios.map((scenario) => {
    const result = validateScenario(
      scenario,
      expected,
      options.evidenceRoot,
      seenReferences,
      options.now
    );
    if (seenIds.has(result.scenarioId)) fail('duplicate scenarioId ' + result.scenarioId);
    seenIds.add(result.scenarioId);
    return result;
  });
  for (const scenarioId of REQUIRED_SCENARIOS)
    if (!seenIds.has(scenarioId)) fail('missing scenario ' + scenarioId);
  for (const reference of seenReferences) {
    if (reference !== 'manifest.json' && !manifestFiles.has(reference)) {
      fail('manifest does not declare referenced file ' + reference);
    }
  }
  return { status: 'passed', schemaVersion: 2, manifestPath, scenarios: results };
}

export function parseArgs(argv) {
  const options = {};
  const allowed = new Set([
    'evidence',
    'evidence-root',
    'source-sha',
    'template-sha256',
    'personalized-exe-sha256',
    'run-id',
    'run-attempt',
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith('--') || !allowed.has(key.slice(2))) fail('unknown argument ' + key);
    const name = key.slice(2);
    if (Object.prototype.hasOwnProperty.call(options, name)) fail('duplicate argument ' + key);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) fail('missing value for ' + key);
    options[name] = value;
    index += 1;
  }
  for (const key of allowed) if (!options[key]) fail('--' + key + ' is required');
  if (!SHA40.test(options['source-sha'])) fail('--source-sha must be a complete SHA');
  for (const key of ['template-sha256', 'personalized-exe-sha256'])
    if (!SHA64.test(options[key])) fail('--' + key + ' must be a complete SHA');
  if (!/^[1-9][0-9]*$/.test(options['run-attempt']))
    fail('--run-attempt must be a positive integer');
  options['run-attempt'] = Number(options['run-attempt']);
  if (!Number.isSafeInteger(options['run-attempt'])) fail('--run-attempt is out of range');
  return options;
}

export function validateEvidenceBundleFromFiles(options, now = Date.now) {
  const aggregate = JSON.parse(readFileSync(options.evidence, 'utf8'));
  return validateEvidence(
    aggregate,
    {
      sourceSha: options['source-sha'],
      templateSha256: options['template-sha256'],
      personalizedExeSha256: options['personalized-exe-sha256'],
      runId: options['run-id'],
      runAttempt: options['run-attempt'],
    },
    { evidenceRoot: options['evidence-root'], now }
  );
}
