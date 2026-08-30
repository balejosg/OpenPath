#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const currentFilePath = fileURLToPath(import.meta.url);
const scriptDir = dirname(currentFilePath);
const projectRoot = resolve(scriptDir, '..');
const FIREFOX_MANIFEST_PATH = resolve(projectRoot, 'firefox-extension/manifest.json');
const BROWSER_POLICY_SPEC_PATH = resolve(projectRoot, 'runtime/browser-policy-spec.json');

const SHA40_PATTERN = /^[0-9a-f]{40}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;

export const PROMOTION_CONTRACT_V2_INTERFACES = Object.freeze({
  wrapperIntegration: 1,
  windowsOfflineInstaller: 1,
  readiness: 1,
});

const V2_COMPONENT_NAMES = Object.freeze([
  'linuxAgent',
  'windowsOfflineInstaller',
  'browserPolicy',
]);

const V2_COMPONENT_FIELDS = Object.freeze({
  linuxAgent: Object.freeze([
    'sourceSha',
    'inputsSha256',
    'packageName',
    'packageVersion',
    'aptSuite',
    'filename',
    'sha256',
  ]),
  windowsOfflineInstaller: Object.freeze([
    'sourceSha',
    'inputsSha256',
    'version',
    'releaseTag',
    'templateAsset',
    'templateSha256',
    'payloadManifestAsset',
    'payloadManifestSha256',
  ]),
  browserPolicy: Object.freeze([
    'sourceSha',
    'inputsSha256',
    'firefoxExtensionVersion',
    'browserPolicySpecSha256',
  ]),
});

/**
 * @typedef {{
 *   version: 1;
 *   openpathSha: string;
 *   packageVersion: string;
 *   linuxAgentVersion: string;
 *   aptSuite: 'stable' | 'unstable';
 *   firefoxExtensionVersion: string;
 *   browserPolicySpecSha256: string;
 * }} OpenPathPromotionContract
 */

function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

export function buildOpenPathPromotionContract({
  openpathSha,
  packageVersion,
  linuxAgentVersion,
  aptSuite,
  firefoxExtensionVersion,
  browserPolicySpecSha256,
}) {
  const normalizedAptSuite = String(aptSuite ?? '').trim();
  if (normalizedAptSuite !== 'stable' && normalizedAptSuite !== 'unstable') {
    throw new Error(`Unsupported aptSuite: ${normalizedAptSuite || 'unset'}`);
  }

  for (const [key, value] of Object.entries({
    openpathSha,
    packageVersion,
    linuxAgentVersion,
    firefoxExtensionVersion,
    browserPolicySpecSha256,
  })) {
    if (!String(value ?? '').trim()) {
      throw new Error(`${key} is required`);
    }
  }

  return /** @type {OpenPathPromotionContract} */ ({
    version: 1,
    openpathSha: String(openpathSha).trim(),
    packageVersion: String(packageVersion).trim(),
    linuxAgentVersion: String(linuxAgentVersion).trim(),
    aptSuite: normalizedAptSuite,
    firefoxExtensionVersion: String(firefoxExtensionVersion).trim(),
    browserPolicySpecSha256: String(browserPolicySpecSha256).trim(),
  });
}

export function serializeOpenPathPromotionContract(contract) {
  return `${JSON.stringify(contract, null, 2)}\n`;
}

function assertRecord(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
}

function assertExactKeys(value, expectedKeys, label) {
  assertRecord(value, label);
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw new Error(`${label} contains unknown property ${key}`);
    }
  }
  for (const key of expectedKeys) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) {
      throw new Error(`${label}.${key} is required`);
    }
  }
}

function assertNonEmptyString(value, label) {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error(`${label} is required`);
  }
  return value.trim();
}

function assertSha40(value, label) {
  if (typeof value !== 'string' || !SHA40_PATTERN.test(value)) {
    throw new Error(`${label} must be a 40-character lowercase SHA`);
  }
  return value;
}

function assertSha256(value, label) {
  if (typeof value !== 'string' || !SHA256_PATTERN.test(value)) {
    throw new Error(`${label} must be a 64-character SHA-256 hex string`);
  }
  return value;
}

function canonicalizeV2Component(componentName, component) {
  assertRecord(component, `components.${componentName}`);
  assertExactKeys(component, V2_COMPONENT_FIELDS[componentName], `components.${componentName}`);

  const sourceSha = assertSha40(component.sourceSha, `components.${componentName}.sourceSha`);
  const inputsSha256 = assertSha256(
    component.inputsSha256,
    `components.${componentName}.inputsSha256`
  );

  if (componentName === 'linuxAgent') {
    const packageName = assertNonEmptyString(
      component.packageName,
      'components.linuxAgent.packageName'
    );
    if (packageName !== 'openpath-dnsmasq') {
      throw new Error('components.linuxAgent.packageName must be openpath-dnsmasq');
    }

    const packageVersion = assertNonEmptyString(
      component.packageVersion,
      'components.linuxAgent.packageVersion'
    );
    const aptSuite = assertNonEmptyString(component.aptSuite, 'components.linuxAgent.aptSuite');
    if (aptSuite !== 'stable' && aptSuite !== 'unstable') {
      throw new Error(`Unsupported components.linuxAgent.aptSuite: ${aptSuite}`);
    }
    const filename = assertNonEmptyString(component.filename, 'components.linuxAgent.filename');
    const sha256 = assertSha256(component.sha256, 'components.linuxAgent.sha256');

    return {
      sourceSha,
      inputsSha256,
      packageName,
      packageVersion,
      aptSuite,
      filename,
      sha256,
    };
  }

  if (componentName === 'windowsOfflineInstaller') {
    const version = assertNonEmptyString(
      component.version,
      'components.windowsOfflineInstaller.version'
    );
    const releaseTag = assertNonEmptyString(
      component.releaseTag,
      'components.windowsOfflineInstaller.releaseTag'
    );
    const releasePrefix = `scripts-v${version}-`;
    const shortSha = releaseTag.startsWith(releasePrefix)
      ? releaseTag.slice(releasePrefix.length)
      : '';
    if (
      !/^[0-9a-f]{7,40}$/.test(shortSha) ||
      !sourceSha.startsWith(shortSha) ||
      releaseTag !== `${releasePrefix}${shortSha}`
    ) {
      throw new Error(
        `components.windowsOfflineInstaller.releaseTag must derive from sourceSha ${sourceSha}`
      );
    }

    const templateAsset = assertNonEmptyString(
      component.templateAsset,
      'components.windowsOfflineInstaller.templateAsset'
    );
    if (templateAsset !== 'OpenPath-Windows-Setup-Template.exe') {
      throw new Error(
        'components.windowsOfflineInstaller.templateAsset must be OpenPath-Windows-Setup-Template.exe'
      );
    }
    const templateSha256 = assertSha256(
      component.templateSha256,
      'components.windowsOfflineInstaller.templateSha256'
    );
    const payloadManifestAsset = assertNonEmptyString(
      component.payloadManifestAsset,
      'components.windowsOfflineInstaller.payloadManifestAsset'
    );
    if (payloadManifestAsset !== 'payload-manifest.json') {
      throw new Error(
        'components.windowsOfflineInstaller.payloadManifestAsset must be payload-manifest.json'
      );
    }
    const payloadManifestSha256 = assertSha256(
      component.payloadManifestSha256,
      'components.windowsOfflineInstaller.payloadManifestSha256'
    );

    return {
      sourceSha,
      inputsSha256,
      version,
      releaseTag,
      templateAsset,
      templateSha256,
      payloadManifestAsset,
      payloadManifestSha256,
    };
  }

  const firefoxExtensionVersion = assertNonEmptyString(
    component.firefoxExtensionVersion,
    'components.browserPolicy.firefoxExtensionVersion'
  );
  const browserPolicySpecSha256 = assertSha256(
    component.browserPolicySpecSha256,
    'components.browserPolicy.browserPolicySpecSha256'
  );

  return {
    sourceSha,
    inputsSha256,
    firefoxExtensionVersion,
    browserPolicySpecSha256,
  };
}

function canonicalizeV2Components(components) {
  assertExactKeys(components, V2_COMPONENT_NAMES, 'components');
  return {
    linuxAgent: canonicalizeV2Component('linuxAgent', components.linuxAgent),
    windowsOfflineInstaller: canonicalizeV2Component(
      'windowsOfflineInstaller',
      components.windowsOfflineInstaller
    ),
    browserPolicy: canonicalizeV2Component('browserPolicy', components.browserPolicy),
  };
}

function canonicalizeV2Interfaces(interfaces) {
  assertExactKeys(interfaces, Object.keys(PROMOTION_CONTRACT_V2_INTERFACES), 'interfaces');
  for (const [name, expectedVersion] of Object.entries(PROMOTION_CONTRACT_V2_INTERFACES)) {
    if (interfaces[name] !== expectedVersion) {
      throw new Error(`interfaces.${name} must be ${expectedVersion}`);
    }
  }
  return { ...PROMOTION_CONTRACT_V2_INTERFACES };
}

function canonicalizeV2Contract(contract) {
  assertExactKeys(
    contract,
    ['schemaVersion', 'openpathSha', 'openpathVersion', 'interfaces', 'components'],
    'v2 contract'
  );
  if (contract.schemaVersion !== 2) {
    throw new Error('v2 contract.schemaVersion must be 2');
  }

  const openpathSha = assertSha40(contract.openpathSha, 'openpathSha');
  const openpathVersion = assertNonEmptyString(contract.openpathVersion, 'openpathVersion');
  const interfaces = canonicalizeV2Interfaces(contract.interfaces);
  const components = canonicalizeV2Components(contract.components);

  return {
    schemaVersion: 2,
    openpathSha,
    openpathVersion,
    interfaces,
    components,
  };
}

export function validateOpenPathPromotionContractV2(contract) {
  return canonicalizeV2Contract(contract);
}

export function buildOpenPathPromotionContractV2({
  openpathSha,
  openpathVersion,
  interfaces = PROMOTION_CONTRACT_V2_INTERFACES,
  components,
}) {
  return canonicalizeV2Contract({
    schemaVersion: 2,
    openpathSha,
    openpathVersion,
    interfaces,
    components,
  });
}

export function serializeOpenPathPromotionContractV2(contract) {
  return `${JSON.stringify(canonicalizeV2Contract(contract), null, 2)}\n`;
}

export function resolvePromotionContractComponents({ currentComponents, previousContract }) {
  const current = canonicalizeV2Components(currentComponents);
  if (previousContract === undefined || previousContract === null) {
    return current;
  }

  const previous = canonicalizeV2Contract(previousContract);
  const resolved = {};
  for (const componentName of V2_COMPONENT_NAMES) {
    const currentComponent = current[componentName];
    const previousComponent = previous.components[componentName];
    resolved[componentName] =
      currentComponent.inputsSha256 === previousComponent.inputsSha256
        ? { ...previousComponent }
        : { ...currentComponent };
  }

  return {
    linuxAgent: resolved.linuxAgent,
    windowsOfflineInstaller: resolved.windowsOfflineInstaller,
    browserPolicy: resolved.browserPolicy,
  };
}

export function publishImmutablePromotionContract({ outputPath, contract }) {
  const resolvedOutputPath = String(outputPath ?? '').trim();
  if (!resolvedOutputPath) {
    throw new Error('outputPath is required');
  }
  const canonicalContract = validateOpenPathPromotionContractV2(contract);
  if (basename(resolvedOutputPath) !== `${canonicalContract.openpathSha}.json`) {
    throw new Error(
      `Immutable promotion contract path must be keyed by ${canonicalContract.openpathSha}`
    );
  }
  const bytes = Buffer.from(serializeOpenPathPromotionContractV2(canonicalContract), 'utf8');
  mkdirSync(dirname(resolvedOutputPath), { recursive: true });

  try {
    writeFileSync(resolvedOutputPath, bytes, { flag: 'wx' });
    return { status: 'created' };
  } catch (error) {
    if (error?.code !== 'EEXIST') throw error;
  }

  const existingBytes = readFileSync(resolvedOutputPath);
  if (Buffer.compare(existingBytes, bytes) === 0) {
    return { status: 'identical' };
  }
  throw new Error(
    `Immutable promotion contract already exists with different bytes: ${resolvedOutputPath}`
  );
}

export function parseDebianStanzas(text) {
  return String(text)
    .replace(/\r\n/g, '\n')
    .split(/\n\n+/)
    .filter((stanza) => stanza.trim().length > 0)
    .map((stanza) => {
      const fields = {};
      let lastField = '';
      for (const line of stanza.split('\n')) {
        if (/^[ \t]/.test(line) && lastField) {
          fields[lastField] += `\n${line.trim()}`;
          continue;
        }
        const match = line.match(/^([^:]+):[ \t]?(.*)$/);
        if (!match) continue;
        lastField = match[1];
        fields[lastField] = match[2];
      }
      return fields;
    });
}

function readPhysicalBytes({ bytes, path, label }) {
  if (bytes !== undefined) {
    if (!Buffer.isBuffer(bytes) && !(bytes instanceof Uint8Array)) {
      throw new Error(`${label} bytes must be a byte array`);
    }
    return Buffer.from(bytes);
  }
  if (path && existsSync(path)) {
    return readFileSync(path);
  }
  throw new Error(`${label} physical bytes are required`);
}

export function verifyLinuxPromotionArtifact({
  sourceSha,
  inputsSha256,
  aptSuite,
  packagesText,
  releaseText,
  filename,
  artifactBytes,
  artifactPath,
  packageName = 'openpath-dnsmasq',
}) {
  const normalizedSourceSha = assertSha40(sourceSha, 'linuxAgent.sourceSha');
  const normalizedInputsSha256 = assertSha256(inputsSha256, 'linuxAgent.inputsSha256');
  const normalizedSuite = assertNonEmptyString(aptSuite, 'linuxAgent.aptSuite');
  if (normalizedSuite !== 'stable' && normalizedSuite !== 'unstable') {
    throw new Error(`Unsupported linuxAgent.aptSuite: ${normalizedSuite}`);
  }
  if (packageName !== 'openpath-dnsmasq') {
    throw new Error('linuxAgent.packageName must be openpath-dnsmasq');
  }
  const normalizedFilename = assertNonEmptyString(filename, 'linuxAgent.filename');

  const releaseFields = parseDebianStanzas(releaseText).find(
    (fields) => fields.Suite || fields.Codename
  );
  if (!releaseFields || releaseFields.Suite !== normalizedSuite) {
    throw new Error(`APT Release metadata does not advertise suite ${normalizedSuite}`);
  }
  if (releaseFields.Codename && releaseFields.Codename !== normalizedSuite) {
    throw new Error(`APT Release metadata does not advertise codename ${normalizedSuite}`);
  }

  const matchingStanzas = parseDebianStanzas(packagesText).filter(
    (fields) => fields.Package === packageName && fields.Filename === normalizedFilename
  );
  if (matchingStanzas.length !== 1) {
    throw new Error(
      `APT Packages metadata must contain exactly one ${packageName} stanza for ${normalizedFilename}`
    );
  }
  const packageFields = matchingStanzas[0];
  const packageVersion = assertNonEmptyString(packageFields.Version, 'linuxAgent.packageVersion');
  const advertisedSha256 = assertSha256(packageFields.SHA256, 'APT Packages SHA256');
  const physicalBytes = readPhysicalBytes({
    bytes: artifactBytes,
    path: artifactPath,
    label: 'Linux package',
  });
  if (artifactPath && basename(artifactPath) !== basename(normalizedFilename)) {
    throw new Error(
      `Linux package path ${artifactPath} does not correspond to Packages Filename ${normalizedFilename}`
    );
  }
  const physicalSha256 = createHash('sha256').update(physicalBytes).digest('hex');
  if (physicalSha256 !== advertisedSha256) {
    throw new Error(
      `Linux package physical SHA256 ${physicalSha256} does not match Packages SHA256 ${advertisedSha256}`
    );
  }

  return {
    sourceSha: normalizedSourceSha,
    inputsSha256: normalizedInputsSha256,
    packageName,
    packageVersion,
    aptSuite: normalizedSuite,
    filename: normalizedFilename,
    sha256: advertisedSha256,
  };
}

export function verifyBrowserPolicyArtifact({
  sourceSha,
  inputsSha256,
  manifestText,
  manifestPath,
  policySpecBytes,
  policySpecPath,
}) {
  const normalizedSourceSha = assertSha40(sourceSha, 'browserPolicy.sourceSha');
  const normalizedInputsSha256 = assertSha256(inputsSha256, 'browserPolicy.inputsSha256');

  let manifest;
  try {
    const manifestBytes =
      manifestText !== undefined
        ? Buffer.from(String(manifestText), 'utf8')
        : readPhysicalBytes({ path: manifestPath, label: 'Firefox manifest' });
    manifest = JSON.parse(manifestBytes.toString('utf8'));
  } catch (error) {
    throw new Error(`Firefox manifest is not valid JSON: ${error.message}`);
  }
  const firefoxExtensionVersion = assertNonEmptyString(
    manifest?.version,
    'browserPolicy.firefoxExtensionVersion'
  );

  const physicalPolicySpecBytes = readPhysicalBytes({
    bytes: policySpecBytes,
    path: policySpecPath,
    label: 'browser policy specification',
  });
  try {
    JSON.parse(physicalPolicySpecBytes.toString('utf8'));
  } catch (error) {
    throw new Error(`Browser policy specification is not valid JSON: ${error.message}`);
  }
  const browserPolicySpecSha256 = createHash('sha256')
    .update(physicalPolicySpecBytes)
    .digest('hex');

  return {
    sourceSha: normalizedSourceSha,
    inputsSha256: normalizedInputsSha256,
    firefoxExtensionVersion,
    browserPolicySpecSha256,
  };
}

export function parseSha256Sidecar(text, expectedAssetName) {
  const normalizedExpectedName = assertNonEmptyString(expectedAssetName, 'expectedAssetName');
  const normalizedText = String(text).replace(/\r\n/g, '\n');
  const lines = normalizedText.split('\n').filter((line) => line.length > 0);
  if (lines.length !== 1) {
    throw new Error(`SHA256 sidecar for ${normalizedExpectedName} must contain one record`);
  }
  const match = lines[0].match(/^([0-9a-f]{64})[ \t]+(\*?)([^\s].*[^\s])$/);
  if (!match || match[3] !== normalizedExpectedName) {
    throw new Error(`SHA256 sidecar does not identify ${normalizedExpectedName}`);
  }
  return match[1];
}

function indexReleaseAssets(releaseAssets) {
  if (!Array.isArray(releaseAssets)) {
    throw new Error('GitHub Release assets are required');
  }
  const indexed = new Map();
  for (const asset of releaseAssets) {
    assertRecord(asset, 'GitHub Release asset');
    const name = assertNonEmptyString(asset.name, 'GitHub Release asset.name');
    if (indexed.has(name)) {
      throw new Error(`GitHub Release contains duplicate asset ${name}`);
    }
    indexed.set(
      name,
      readPhysicalBytes({
        bytes: asset.bytes,
        path: asset.path,
        label: `GitHub Release asset ${name}`,
      })
    );
  }
  return indexed;
}

export function verifyWindowsPromotionArtifact({
  sourceSha,
  inputsSha256,
  version,
  releaseTag,
  tagTargetSha,
  releaseTagName,
  releaseAssets,
  release,
}) {
  const normalizedSourceSha = assertSha40(sourceSha, 'windowsOfflineInstaller.sourceSha');
  const normalizedInputsSha256 = assertSha256(inputsSha256, 'windowsOfflineInstaller.inputsSha256');
  const normalizedVersion = assertNonEmptyString(version, 'windowsOfflineInstaller.version');
  const normalizedReleaseTag = assertNonEmptyString(
    releaseTag,
    'windowsOfflineInstaller.releaseTag'
  );
  canonicalizeV2Component('windowsOfflineInstaller', {
    sourceSha: normalizedSourceSha,
    inputsSha256: normalizedInputsSha256,
    version: normalizedVersion,
    releaseTag: normalizedReleaseTag,
    templateAsset: 'OpenPath-Windows-Setup-Template.exe',
    templateSha256: '0000000000000000000000000000000000000000000000000000000000000000',
    payloadManifestAsset: 'payload-manifest.json',
    payloadManifestSha256: '0000000000000000000000000000000000000000000000000000000000000000',
  });

  const normalizedTagTargetSha = assertSha40(tagTargetSha, 'windowsOfflineInstaller.tagTargetSha');
  if (normalizedTagTargetSha !== normalizedSourceSha) {
    throw new Error(
      `Windows release tag target ${normalizedTagTargetSha} does not match sourceSha ${normalizedSourceSha}`
    );
  }

  const attachedTag = releaseTagName ?? release?.tagName ?? release?.tag_name;
  if (attachedTag !== normalizedReleaseTag) {
    throw new Error(`GitHub Release is not attached to releaseTag ${normalizedReleaseTag}`);
  }
  const assets = indexReleaseAssets(releaseAssets ?? release?.assets);
  const templateAsset = 'OpenPath-Windows-Setup-Template.exe';
  const sidecarAsset = `${templateAsset}.sha256`;
  const payloadManifestAsset = 'payload-manifest.json';
  for (const assetName of [templateAsset, sidecarAsset, payloadManifestAsset]) {
    if (!assets.has(assetName)) {
      throw new Error(`GitHub Release is missing authoritative asset ${assetName}`);
    }
  }

  const templateBytes = assets.get(templateAsset);
  const templateSha256 = createHash('sha256').update(templateBytes).digest('hex');
  const sidecarSha256 = parseSha256Sidecar(
    assets.get(sidecarAsset).toString('utf8'),
    templateAsset
  );
  if (sidecarSha256 !== templateSha256) {
    throw new Error(
      `Windows template sidecar SHA256 ${sidecarSha256} does not match physical bytes ${templateSha256}`
    );
  }

  const payloadManifestBytes = assets.get(payloadManifestAsset);
  let payloadManifest;
  try {
    payloadManifest = JSON.parse(payloadManifestBytes.toString('utf8'));
  } catch (error) {
    throw new Error(`Windows payload manifest is not valid JSON: ${error.message}`);
  }
  if (payloadManifest?.schemaVersion !== 1 || !Array.isArray(payloadManifest?.payloads)) {
    throw new Error('Windows payload manifest has an unsupported schema');
  }
  const payloadManifestSha256 = createHash('sha256').update(payloadManifestBytes).digest('hex');

  return {
    sourceSha: normalizedSourceSha,
    inputsSha256: normalizedInputsSha256,
    version: normalizedVersion,
    releaseTag: normalizedReleaseTag,
    templateAsset,
    templateSha256,
    payloadManifestAsset,
    payloadManifestSha256,
  };
}

export function classifyImmutableTagPublication({ sourceSha, existingTargetSha }) {
  const normalizedSourceSha = assertSha40(sourceSha, 'sourceSha');
  const normalizedExistingTargetSha = String(existingTargetSha ?? '').trim();
  if (!normalizedExistingTargetSha) return 'create';
  if (!SHA40_PATTERN.test(normalizedExistingTargetSha)) {
    throw new Error('Existing tag has a different target');
  }
  if (normalizedExistingTargetSha === normalizedSourceSha) return 'identical';
  throw new Error(
    `Tag has a different target ${normalizedExistingTargetSha}; expected ${normalizedSourceSha}`
  );
}

function parseCliArgs(argv) {
  /** @type {Record<string, string>} */
  const parsed = {};

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const value = argv[index + 1] ?? '';

    switch (arg) {
      case '--output':
        parsed.output = value;
        index += 1;
        break;
      case '--openpath-sha':
        parsed.openpathSha = value;
        index += 1;
        break;
      case '--package-version':
        parsed.packageVersion = value;
        index += 1;
        break;
      case '--linux-agent-version':
        parsed.linuxAgentVersion = value;
        index += 1;
        break;
      case '--apt-suite':
        parsed.aptSuite = value;
        index += 1;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return parsed;
}

function buildOpenPathPromotionContractFromRepo({
  openpathSha,
  packageVersion,
  linuxAgentVersion,
  aptSuite,
}) {
  const firefoxManifest = JSON.parse(readFileSync(FIREFOX_MANIFEST_PATH, 'utf8'));
  return buildOpenPathPromotionContract({
    openpathSha,
    packageVersion,
    linuxAgentVersion: linuxAgentVersion || packageVersion,
    aptSuite,
    firefoxExtensionVersion: String(firefoxManifest.version ?? '').trim(),
    browserPolicySpecSha256: sha256File(BROWSER_POLICY_SPEC_PATH),
  });
}

function runCli() {
  const [command, ...args] = process.argv.slice(2);
  if (command !== 'write') {
    return;
  }

  const parsed = parseCliArgs(args);
  const output = String(parsed.output ?? '').trim();
  if (!output) {
    throw new Error('--output is required');
  }

  const contract = buildOpenPathPromotionContractFromRepo({
    openpathSha: parsed.openpathSha,
    packageVersion: parsed.packageVersion,
    linuxAgentVersion: parsed.linuxAgentVersion,
    aptSuite: parsed.aptSuite,
  });

  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, serializeOpenPathPromotionContract(contract), 'utf8');
}

runCli();
