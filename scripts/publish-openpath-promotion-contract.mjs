#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  buildOpenPathPromotionContractV2,
  parseDebianStanzas,
  publishImmutablePromotionContract,
  resolvePromotionContractComponents,
  validateOpenPathPromotionContractV2,
  verifyBrowserPolicyArtifact,
  verifyLinuxPromotionArtifact,
  verifyWindowsPromotionArtifact,
} from './openpath-promotion-contract.mjs';
import {
  computeReleaseInputFingerprint,
  RELEASE_INPUT_DEFINITIONS,
} from './openpath-release-inputs.mjs';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const defaultRepoRoot = resolve(scriptDir, '..');
const SHA40_PATTERN = /^[0-9a-f]{40}$/;

function requireSha40(value, label) {
  const normalized = String(value ?? '').trim();
  if (!SHA40_PATTERN.test(normalized)) {
    throw new Error(`${label} must be a 40-character lowercase SHA`);
  }
  return normalized;
}

function readRequiredVersion(repoRoot) {
  const version = readFileSync(join(repoRoot, 'VERSION'), 'utf8').trim();
  if (!version) throw new Error('VERSION must contain a non-empty OpenPath version');
  return version;
}

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    throw new Error(`Unable to read ${label} at ${path}: ${error.message}`);
  }
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function defaultGitExec(args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' });
}

export function findPreviousPromotionContract({
  repoRoot,
  pagesRoot,
  openpathSha,
  gitExec = defaultGitExec,
}) {
  const normalizedSha = requireSha40(openpathSha, 'openpathSha');
  let firstParentHistory = '';
  try {
    firstParentHistory = gitExec(['rev-list', '--first-parent', `${normalizedSha}^`], repoRoot);
  } catch {
    return null;
  }

  for (const candidateSha of String(firstParentHistory)
    .split(/\r?\n/)
    .map((candidate) => candidate.trim())
    .filter(Boolean)) {
    if (!SHA40_PATTERN.test(candidateSha)) continue;
    const candidatePath = join(
      resolve(pagesRoot),
      'promotion-contracts',
      'v2',
      `${candidateSha}.json`
    );
    if (!existsSync(candidatePath)) continue;
    const contract = validateOpenPathPromotionContractV2(
      readJson(candidatePath, 'previous v2 promotion contract')
    );
    if (contract.openpathSha !== candidateSha) {
      throw new Error(
        `Previous v2 promotion contract path ${candidatePath} is keyed to ${contract.openpathSha}, not ${candidateSha}`
      );
    }
    return {
      path: candidatePath,
      contract,
    };
  }

  return null;
}

function collectCurrentPromotionInputs({ repoRoot, openpathSha }) {
  const resolvedRepoRoot = resolve(repoRoot);
  const normalizedSha = requireSha40(openpathSha, 'openpathSha');
  const openpathVersion = readRequiredVersion(resolvedRepoRoot);
  const fingerprints = Object.fromEntries(
    Object.keys(RELEASE_INPUT_DEFINITIONS).map((component) => [
      component,
      computeReleaseInputFingerprint({
        repoRoot: resolvedRepoRoot,
        component,
      }),
    ])
  );
  const browserPolicy = verifyBrowserPolicyArtifact({
    sourceSha: normalizedSha,
    inputsSha256: fingerprints.browserPolicy,
    manifestPath: join(resolvedRepoRoot, 'firefox-extension', 'manifest.json'),
    policySpecPath: join(resolvedRepoRoot, 'runtime', 'browser-policy-spec.json'),
  });

  return {
    openpathSha: normalizedSha,
    openpathVersion,
    fingerprints,
    browserPolicy,
  };
}

export function collectPromotionInputs({
  repoRoot = defaultRepoRoot,
  pagesRoot,
  openpathSha,
  gitExec = defaultGitExec,
}) {
  const resolvedPagesRoot = resolve(pagesRoot);
  const current = collectCurrentPromotionInputs({ repoRoot, openpathSha });
  const previous = findPreviousPromotionContract({
    repoRoot: resolve(repoRoot),
    pagesRoot: resolvedPagesRoot,
    openpathSha: current.openpathSha,
    gitExec,
  });
  const changedComponents = Object.keys(RELEASE_INPUT_DEFINITIONS).filter(
    (component) =>
      !previous ||
      previous.contract.components[component].inputsSha256 !== current.fingerprints[component]
  );

  return {
    openpathSha: current.openpathSha,
    openpathVersion: current.openpathVersion,
    fingerprints: current.fingerprints,
    browserPolicy: current.browserPolicy,
    changedComponents,
    previousContractPath: previous?.path ?? null,
    previousContract: previous?.contract ?? null,
  };
}

function readEvidence(path, component) {
  if (!path) {
    throw new Error(`Physical evidence is required for changed component ${component}`);
  }
  return readJson(resolve(path), `${component} physical evidence`);
}

function buildPlaceholderComponent({ component, previous, sourceSha, inputsSha256, version }) {
  const placeholder = { ...previous, sourceSha, inputsSha256 };
  if (component === 'windowsOfflineInstaller') {
    placeholder.version = version;
    placeholder.releaseTag = `scripts-v${version}-${sourceSha.slice(0, 7)}`;
  }
  return placeholder;
}

export function buildPromotionContractFromPreparation({
  repoRoot = defaultRepoRoot,
  pagesRoot,
  preparation,
  linuxEvidencePath,
  windowsEvidencePath,
}) {
  const current = collectCurrentPromotionInputs({
    repoRoot,
    openpathSha: preparation?.openpathSha,
  });
  for (const component of Object.keys(RELEASE_INPUT_DEFINITIONS)) {
    if (preparation.fingerprints?.[component] !== current.fingerprints[component]) {
      throw new Error(
        `Promotion preparation is stale: ${component} inputsSha256 changed before publication`
      );
    }
  }
  if (preparation.openpathVersion !== current.openpathVersion) {
    throw new Error('Promotion preparation is stale: VERSION changed before publication');
  }

  const previousContract = preparation.previousContract ?? null;
  const currentComponents = {
    browserPolicy: current.browserPolicy,
  };
  for (const component of ['linuxAgent', 'windowsOfflineInstaller']) {
    const currentInputsSha256 = current.fingerprints[component];
    const previousComponent = previousContract?.components?.[component];
    const unchanged = previousComponent && previousComponent.inputsSha256 === currentInputsSha256;

    if (unchanged) {
      currentComponents[component] = buildPlaceholderComponent({
        component,
        previous: previousComponent,
        sourceSha: current.openpathSha,
        inputsSha256: currentInputsSha256,
        version: current.openpathVersion,
      });
      continue;
    }

    const evidencePath = component === 'linuxAgent' ? linuxEvidencePath : windowsEvidencePath;
    const evidence = readEvidence(evidencePath, component);
    if (evidence.sourceSha !== current.openpathSha) {
      throw new Error(
        `${component} evidence sourceSha ${evidence.sourceSha} does not match promoted SHA ${current.openpathSha}`
      );
    }
    if (evidence.inputsSha256 !== currentInputsSha256) {
      throw new Error(
        `${component} evidence inputsSha256 does not match the canonical current fingerprint`
      );
    }
    currentComponents[component] = evidence;
  }

  const components = resolvePromotionContractComponents({
    currentComponents,
    previousContract,
  });
  const contract = buildOpenPathPromotionContractV2({
    openpathSha: current.openpathSha,
    openpathVersion: current.openpathVersion,
    components,
  });
  return {
    contract,
    changedComponents: Object.keys(RELEASE_INPUT_DEFINITIONS).filter(
      (component) =>
        !previousContract ||
        previousContract.components[component].inputsSha256 !== current.fingerprints[component]
    ),
    outputPath: join(
      resolve(pagesRoot),
      'promotion-contracts',
      'v2',
      `${current.openpathSha}.json`
    ),
  };
}

export function publishPromotionContract({
  repoRoot = defaultRepoRoot,
  pagesRoot,
  preparation,
  linuxEvidencePath,
  windowsEvidencePath,
}) {
  const result = buildPromotionContractFromPreparation({
    repoRoot,
    pagesRoot,
    preparation,
    linuxEvidencePath,
    windowsEvidencePath,
  });
  return {
    ...result,
    publication: publishImmutablePromotionContract({
      outputPath: result.outputPath,
      contract: result.contract,
    }),
  };
}

function parseCliArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith('--')) throw new Error(`Unknown argument: ${arg}`);
    const key = arg.slice(2);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) {
      throw new Error(`Value is required for --${key}`);
    }
    parsed[key] = value;
    index += 1;
  }
  return parsed;
}

function requireArgument(args, name) {
  const value = String(args[name] ?? '').trim();
  if (!value) throw new Error(`--${name} is required`);
  return value;
}

function resolveContainedPath(root, relativePath, label) {
  const resolvedRoot = resolve(root);
  const resolvedPath = resolve(resolvedRoot, relativePath);
  const fromRoot = relative(resolvedRoot, resolvedPath);
  if (isAbsolute(fromRoot) || fromRoot === '..' || fromRoot.startsWith('../')) {
    throw new Error(`${label} must stay inside ${resolvedRoot}`);
  }
  return resolvedPath;
}

function runCli() {
  const [command, ...rawArgs] = process.argv.slice(2);
  if (!command) return;
  const args = parseCliArgs(rawArgs);

  if (command === 'prepare') {
    const preparation = collectPromotionInputs({
      repoRoot: args['repo-root'] ?? defaultRepoRoot,
      pagesRoot: requireArgument(args, 'pages-root'),
      openpathSha: requireArgument(args, 'openpath-sha'),
    });
    writeJson(requireArgument(args, 'output'), preparation);
    console.log(
      `Prepared promotion contract for ${preparation.openpathSha}; changed components: ${preparation.changedComponents.join(', ') || 'none'}`
    );
    return;
  }

  if (command === 'publish-v2') {
    const preparation = readJson(
      resolve(requireArgument(args, 'preparation')),
      'promotion preparation'
    );
    const result = publishPromotionContract({
      repoRoot: args['repo-root'] ?? defaultRepoRoot,
      pagesRoot: requireArgument(args, 'pages-root'),
      preparation,
      linuxEvidencePath: args['linux-evidence'],
      windowsEvidencePath: args['windows-evidence'],
    });
    console.log(`Promotion contract ${result.publication.status}: ${result.outputPath}`);
    return;
  }

  if (command === 'verify-linux-apt') {
    const aptRoot = resolve(requireArgument(args, 'apt-root'));
    const sourceSha = requireSha40(requireArgument(args, 'source-sha'), 'sourceSha');
    const v1Contract = readJson(
      resolve(requireArgument(args, 'v1-contract')),
      'v1 promotion contract'
    );
    if (v1Contract.openpathSha !== sourceSha) {
      throw new Error('v1 promotion contract is not keyed to the promoted SHA');
    }
    const aptSuite = v1Contract.aptSuite;
    const packagesPath = join(aptRoot, 'dists', aptSuite, 'main', 'binary-amd64', 'Packages');
    const releasePath = join(aptRoot, 'dists', aptSuite, 'Release');
    const packageVersion = String(v1Contract.packageVersion ?? '').trim();
    const packageStanzas = parseDebianStanzas(readFileSync(packagesPath, 'utf8')).filter(
      (fields) => fields.Package === 'openpath-dnsmasq'
    );
    const selected =
      packageStanzas.find((fields) => fields.Version === `${packageVersion}-1`) ??
      packageStanzas.find((fields) => fields.Version === packageVersion);
    if (!selected?.Filename) {
      throw new Error(
        `APT Packages does not contain openpath-dnsmasq version ${packageVersion} for ${sourceSha}`
      );
    }
    const artifactPath = resolveContainedPath(aptRoot, selected.Filename, 'APT Packages Filename');
    const component = verifyLinuxPromotionArtifact({
      sourceSha,
      inputsSha256: requireArgument(args, 'inputs-sha256'),
      aptSuite,
      packagesText: readFileSync(packagesPath, 'utf8'),
      releaseText: readFileSync(releasePath, 'utf8'),
      filename: selected.Filename,
      artifactPath,
    });
    writeJson(requireArgument(args, 'output'), component);
    console.log(`Verified physical Linux package ${component.filename}`);
    return;
  }

  if (command === 'verify-windows-release') {
    const releaseMetadataPath = resolve(requireArgument(args, 'release-metadata'));
    const releaseMetadata = readJson(releaseMetadataPath, 'GitHub Release metadata');
    const assetsRoot = resolve(requireArgument(args, 'assets-root'));
    const sourceSha = requireSha40(requireArgument(args, 'source-sha'), 'sourceSha');
    const releaseTag = requireArgument(args, 'release-tag');
    const version = requireArgument(args, 'version');
    const templateAsset = 'OpenPath-Windows-Setup-Template.exe';
    const releaseAssets = [
      { name: templateAsset, path: join(assetsRoot, templateAsset) },
      {
        name: `${templateAsset}.sha256`,
        path: join(assetsRoot, `${templateAsset}.sha256`),
      },
      { name: 'payload-manifest.json', path: join(assetsRoot, 'payload-manifest.json') },
    ];
    const component = verifyWindowsPromotionArtifact({
      sourceSha,
      inputsSha256: requireArgument(args, 'inputs-sha256'),
      version,
      releaseTag,
      tagTargetSha: requireArgument(args, 'tag-target-sha'),
      releaseTagName: releaseMetadata.tagName ?? releaseMetadata.tag_name,
      releaseAssets,
    });
    writeJson(requireArgument(args, 'output'), component);
    console.log(`Verified physical Windows release ${component.releaseTag}`);
    return;
  }

  throw new Error(`Unknown promotion publisher command: ${command}`);
}

runCli();
