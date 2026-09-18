import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const phases = ['prepare', 'observe', 'afterReboot', 'cleanup'];
const sha40 = /^[0-9a-f]{40}$/i;
const sha64 = /^[0-9a-f]{64}$/i;

function fail(message) {
  throw new Error('PolicyConverter contrast evidence rejected: ' + message);
}

function required(value, field) {
  if (typeof value !== 'string' || value.length === 0) fail(field + ' is required');
}

function requiredTimestamp(value, field) {
  required(value, field);
  if (Number.isNaN(Date.parse(value))) fail(field + ' is invalid');
}

function hashFile(root, reference, expected, field) {
  required(reference, field);
  if (
    reference.includes('\\') ||
    reference.includes('..') ||
    reference.startsWith('/') ||
    /^[A-Za-z]:/.test(reference) ||
    reference.includes(':')
  )
    fail(field + ' must be a safe relative path');
  const absolute = path.resolve(root, reference);
  const rel = path.relative(root, absolute);
  if (!rel || rel.startsWith('..' + path.sep) || path.isAbsolute(rel))
    fail(field + ' escapes evidence root');
  if (lstatSync(absolute).isSymbolicLink()) fail(field + ' may not be a symlink');
  const realRoot = realpathSync(root);
  const realFile = realpathSync(absolute);
  const realRelative = path.relative(realRoot, realFile);
  if (!realRelative || realRelative.startsWith('..' + path.sep) || path.isAbsolute(realRelative))
    fail(field + ' resolves outside evidence root');
  const bytes = readFileSync(absolute);
  const actual = createHash('sha256').update(bytes).digest('hex');
  if (expected !== actual) fail(field + ' hash mismatch');
  return { bytes, size: statSync(absolute).size, actual };
}

export function validateContrastEvidence(aggregate, expected, evidenceRoot) {
  if (!aggregate || typeof aggregate !== 'object' || Array.isArray(aggregate))
    fail('aggregate must be an object');
  if (aggregate.schemaVersion !== 2) fail('schemaVersion must be 2');
  if (aggregate.suiteKind !== 'PolicyConverterContrast') fail('suiteKind mismatch');
  if (aggregate.policyConverterMode !== expected.mode) fail('policyConverterMode mismatch');
  if (aggregate.sourceCommitSha !== expected.sourceSha || !sha40.test(aggregate.sourceCommitSha))
    fail('sourceCommitSha mismatch');
  if (aggregate.runId !== expected.runId || aggregate.runAttempt !== expected.runAttempt)
    fail('run identity mismatch');
  if (!sha64.test(aggregate.templateSha256) || !sha64.test(aggregate.personalizedExeSha256))
    fail('binary hashes are invalid');
  if (
    aggregate.templateSha256 !== expected.templateSha256 ||
    aggregate.personalizedExeSha256 !== expected.personalizedExeSha256
  )
    fail('binary hash mismatch');
  if (!sha64.test(String(aggregate.evidenceManifestSha256 ?? ''))) fail('manifest hash is invalid');
  requiredTimestamp(aggregate.generatedAt, 'generatedAt');
  if (aggregate.synthetic !== false) fail('synthetic aggregate is not publishable');
  required(aggregate.scenarioId, 'scenarioId');
  const requiredScenario = 'win11-policy-converter-' + expected.mode.toLowerCase();
  if (aggregate.scenarioId !== requiredScenario) fail('scenarioId mismatch');
  if (!aggregate.phases || typeof aggregate.phases !== 'object' || Array.isArray(aggregate.phases))
    fail('phases are required');
  if (Object.keys(aggregate.phases).sort().join(',') !== phases.slice().sort().join(','))
    fail('phase matrix is incomplete');
  const manifestPath = path.join(evidenceRoot, expected.manifestName);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  if (
    manifest.schemaVersion !== 2 ||
    manifest.suiteKind !== 'PolicyConverterContrast' ||
    manifest.policyConverterMode !== expected.mode
  )
    fail('manifest identity mismatch');
  if (
    manifest.sourceCommitSha !== expected.sourceSha ||
    manifest.runId !== expected.runId ||
    manifest.runAttempt !== expected.runAttempt
  )
    fail('manifest run identity mismatch');
  if (!Array.isArray(manifest.files) || manifest.files.length === 0)
    fail('manifest files are required');
  requiredTimestamp(manifest.generatedAt, 'manifest.generatedAt');
  const declared = new Set();
  for (const [index, file] of manifest.files.entries()) {
    if (
      !file ||
      typeof file.path !== 'string' ||
      !Number.isInteger(file.size) ||
      file.size < 0 ||
      !sha64.test(file.sha256)
    )
      fail('manifest entry ' + index + ' is invalid');
    const record = hashFile(evidenceRoot, file.path, file.sha256, 'manifest.files[' + index + ']');
    if (file.path === expected.manifestName || record.size !== file.size || declared.has(file.path))
      fail('manifest entry ' + index + ' size/duplicate mismatch');
    declared.add(file.path);
  }
  const manifestBytes = readFileSync(manifestPath);
  const manifestHash = createHash('sha256').update(manifestBytes).digest('hex');
  if (manifestHash !== aggregate.evidenceManifestSha256) fail('manifest hash mismatch');
  const phaseReferences = new Set();
  for (const phase of phases) {
    const record = aggregate.phases[phase];
    if (
      !record ||
      record.status !== 'passed' ||
      typeof record.evidenceRef !== 'string' ||
      !sha64.test(record.sha256) ||
      typeof record.correlationNonce !== 'string' ||
      record.correlationNonce.length === 0
    )
      fail(phase + ' record invalid');
    requiredTimestamp(record.startedAt, phase + '.startedAt');
    requiredTimestamp(record.endedAt, phase + '.endedAt');
    if (Date.parse(record.endedAt) < Date.parse(record.startedAt))
      fail(phase + ' chronology is invalid');
    if (!declared.has(record.evidenceRef)) fail(phase + ' is not declared by manifest');
    if (phaseReferences.has(record.evidenceRef)) fail(phase + ' evidence reference is shared');
    phaseReferences.add(record.evidenceRef);
    const file = hashFile(evidenceRoot, record.evidenceRef, record.sha256, phase + '.evidenceRef');
    const observation = JSON.parse(file.bytes.toString('utf8'));
    if (
      observation.status !== 'passed' ||
      observation.synthetic !== false ||
      observation.runId !== expected.runId ||
      observation.runAttempt !== expected.runAttempt ||
      observation.sourceCommitSha !== expected.sourceSha ||
      observation.scenarioId !== aggregate.scenarioId ||
      observation.phase !== phase ||
      observation.correlationNonce !== record.correlationNonce
    )
      fail(phase + ' observation mismatch');
  }
  return { status: 'passed', mode: expected.mode, scenarioId: aggregate.scenarioId };
}

function parseArgs(argv) {
  const allowed = new Set([
    'evidence',
    'evidence-root',
    'source-sha',
    'template-sha256',
    'personalized-exe-sha256',
    'run-id',
    'run-attempt',
    'mode',
  ]);
  const values = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    if (!key?.startsWith('--') || !allowed.has(key.slice(2)) || values[key.slice(2)] !== undefined)
      fail('unknown or duplicate argument ' + key);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) fail('missing value for ' + key);
    values[key.slice(2)] = value;
  }
  for (const key of allowed) if (!values[key]) fail('--' + key + ' is required');
  if (
    !['Untouched', 'Started'].includes(values.mode) ||
    !/^[1-9][0-9]*$/.test(values['run-attempt'])
  )
    fail('invalid mode or run-attempt');
  values['run-attempt'] = Number(values['run-attempt']);
  if (
    !Number.isSafeInteger(values['run-attempt']) ||
    !sha40.test(values['source-sha']) ||
    !sha64.test(values['template-sha256']) ||
    !sha64.test(values['personalized-exe-sha256'])
  )
    fail('invalid identity or hash');
  return values;
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const aggregate = JSON.parse(readFileSync(options.evidence, 'utf8'));
  const manifestName = `contrast-${options.mode.toLowerCase()}-manifest.json`;
  validateContrastEvidence(
    aggregate,
    {
      mode: options.mode,
      sourceSha: options['source-sha'],
      templateSha256: options['template-sha256'],
      personalizedExeSha256: options['personalized-exe-sha256'],
      runId: options['run-id'],
      runAttempt: options['run-attempt'],
      manifestName,
    },
    options['evidence-root']
  );
  console.log('Windows PolicyConverter contrast evidence validated.');
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
