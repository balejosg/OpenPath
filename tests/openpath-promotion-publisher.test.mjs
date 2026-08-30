import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { describe, test } from 'node:test';

import {
  buildOpenPathPromotionContract,
  buildOpenPathPromotionContractV2,
} from '../scripts/openpath-promotion-contract.mjs';
import {
  buildPromotionContractFromPreparation,
  collectPromotionInputs,
} from '../scripts/publish-openpath-promotion-contract.mjs';

const SOURCE_SHA = '0123456789abcdef0123456789abcdef01234567';
const PREVIOUS_SOURCE_SHA = 'fedcba9876543210fedcba9876543210fedcba98';
const TEST_REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function makePreviousContract(preparation) {
  return buildOpenPathPromotionContractV2({
    openpathSha: PREVIOUS_SOURCE_SHA,
    openpathVersion: preparation.openpathVersion,
    components: {
      linuxAgent: {
        sourceSha: PREVIOUS_SOURCE_SHA,
        inputsSha256: preparation.fingerprints.linuxAgent,
        packageName: 'openpath-dnsmasq',
        packageVersion: '0.0.411-1',
        aptSuite: 'stable',
        filename: 'pool/stable/main/openpath-dnsmasq_0.0.411-1_amd64.deb',
        sha256: '4444444444444444444444444444444444444444444444444444444444444444',
      },
      windowsOfflineInstaller: {
        sourceSha: PREVIOUS_SOURCE_SHA,
        inputsSha256: preparation.fingerprints.windowsOfflineInstaller,
        version: preparation.openpathVersion,
        releaseTag: `scripts-v${preparation.openpathVersion}-${PREVIOUS_SOURCE_SHA.slice(0, 7)}`,
        templateAsset: 'OpenPath-Windows-Setup-Template.exe',
        templateSha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        payloadManifestAsset: 'payload-manifest.json',
        payloadManifestSha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      },
      browserPolicy: {
        sourceSha: PREVIOUS_SOURCE_SHA,
        inputsSha256: '3333333333333333333333333333333333333333333333333333333333333333',
        firefoxExtensionVersion: '2.0.0',
        browserPolicySpecSha256: '5555555555555555555555555555555555555555555555555555555555555555',
      },
    },
  });
}

describe('OpenPath promotion publisher orchestration', () => {
  test('loads the previous contract only from first-parent SHA-keyed paths', () => {
    const pagesRoot = mkdtempSync(join(tmpdir(), 'openpath-promotion-pages-'));
    const withoutPrevious = collectPromotionInputs({
      repoRoot: TEST_REPO_ROOT,
      pagesRoot,
      openpathSha: SOURCE_SHA,
      gitExec: () => `${PREVIOUS_SOURCE_SHA}\n`,
    });
    assert.equal(withoutPrevious.previousContract, null);

    const previousContract = makePreviousContract(withoutPrevious);
    const previousPath = join(
      pagesRoot,
      'promotion-contracts',
      'v2',
      `${PREVIOUS_SOURCE_SHA}.json`
    );
    mkdirSync(dirname(previousPath), { recursive: true });
    writeFileSync(previousPath, `${JSON.stringify(previousContract, null, 2)}\n`);

    const withPrevious = collectPromotionInputs({
      repoRoot: TEST_REPO_ROOT,
      pagesRoot,
      openpathSha: SOURCE_SHA,
      gitExec: () => `${PREVIOUS_SOURCE_SHA}\n`,
    });
    assert.equal(withPrevious.previousContractPath, previousPath);
    assert.equal(withPrevious.previousContract.openpathSha, PREVIOUS_SOURCE_SHA);
  });

  test('publishes a newer top-level SHA while inheriting unchanged components in OpenPath', () => {
    const pagesRoot = mkdtempSync(join(tmpdir(), 'openpath-promotion-pages-'));
    const initial = collectPromotionInputs({
      repoRoot: TEST_REPO_ROOT,
      pagesRoot,
      openpathSha: SOURCE_SHA,
      gitExec: () => `${PREVIOUS_SOURCE_SHA}\n`,
    });
    const previousContract = makePreviousContract(initial);
    const preparation = { ...initial, previousContract };

    const result = buildPromotionContractFromPreparation({
      repoRoot: TEST_REPO_ROOT,
      preparation,
      pagesRoot,
    });

    assert.equal(result.contract.openpathSha, SOURCE_SHA);
    assert.equal(result.contract.components.linuxAgent.sourceSha, PREVIOUS_SOURCE_SHA);
    assert.equal(result.contract.components.windowsOfflineInstaller.sourceSha, PREVIOUS_SOURCE_SHA);
    assert.equal(result.contract.components.browserPolicy.sourceSha, SOURCE_SHA);
    assert.deepEqual(result.changedComponents, ['browserPolicy']);
  });

  test('CLI verifies the physical APT and Windows evidence shapes consumed by the workflow', () => {
    const evidenceRoot = mkdtempSync(join(tmpdir(), 'openpath-promotion-evidence-'));
    const aptRoot = join(evidenceRoot, 'apt');
    const packageBytes = Buffer.from('physical deb');
    const packageSha = createHash('sha256').update(packageBytes).digest('hex');
    const packageFilename = 'pool/stable/main/openpath-dnsmasq_0.0.412-1_amd64.deb';
    const packagesPath = join(aptRoot, 'dists/stable/main/binary-amd64/Packages');
    mkdirSync(join(aptRoot, 'dists/stable/main/binary-amd64'), { recursive: true });
    mkdirSync(join(aptRoot, 'pool/stable/main'), { recursive: true });
    writeFileSync(
      packagesPath,
      `Package: openpath-dnsmasq\nVersion: 0.0.412-1\nFilename: ${packageFilename}\nSHA256: ${packageSha}\n\n`
    );
    writeFileSync(join(aptRoot, 'dists/stable/Release'), 'Suite: stable\nCodename: stable\n');
    writeFileSync(join(aptRoot, packageFilename), packageBytes);
    const v1Path = join(evidenceRoot, 'v1.json');
    writeFileSync(
      v1Path,
      `${JSON.stringify(
        buildOpenPathPromotionContract({
          openpathSha: SOURCE_SHA,
          packageVersion: '0.0.412',
          linuxAgentVersion: '0.0.412',
          aptSuite: 'stable',
          firefoxExtensionVersion: '2.0.1',
          browserPolicySpecSha256: 'meta',
        }),
        null,
        2
      )}\n`
    );
    const linuxOutput = join(evidenceRoot, 'linux.json');
    execFileSync(
      process.execPath,
      [
        'scripts/publish-openpath-promotion-contract.mjs',
        'verify-linux-apt',
        '--apt-root',
        aptRoot,
        '--v1-contract',
        v1Path,
        '--source-sha',
        SOURCE_SHA,
        '--inputs-sha256',
        '1111111111111111111111111111111111111111111111111111111111111111',
        '--output',
        linuxOutput,
      ],
      { cwd: TEST_REPO_ROOT, encoding: 'utf8' }
    );
    assert.equal(JSON.parse(readFileSync(linuxOutput, 'utf8')).filename, packageFilename);

    const windowsRoot = join(evidenceRoot, 'windows');
    mkdirSync(windowsRoot, { recursive: true });
    const templateBytes = Buffer.from('physical template');
    const templateSha = createHash('sha256').update(templateBytes).digest('hex');
    writeFileSync(join(windowsRoot, 'OpenPath-Windows-Setup-Template.exe'), templateBytes);
    writeFileSync(
      join(windowsRoot, 'OpenPath-Windows-Setup-Template.exe.sha256'),
      `${templateSha}  OpenPath-Windows-Setup-Template.exe\n`
    );
    writeFileSync(
      join(windowsRoot, 'payload-manifest.json'),
      '{"schemaVersion":1,"payloads":[]}\n'
    );
    const windowsMetadata = join(evidenceRoot, 'release.json');
    writeFileSync(windowsMetadata, JSON.stringify({ tag_name: 'scripts-v4.1.0-0123456' }));
    const windowsOutput = join(evidenceRoot, 'windows.json');
    execFileSync(
      process.execPath,
      [
        'scripts/publish-openpath-promotion-contract.mjs',
        'verify-windows-release',
        '--release-metadata',
        windowsMetadata,
        '--assets-root',
        windowsRoot,
        '--source-sha',
        SOURCE_SHA,
        '--inputs-sha256',
        '2222222222222222222222222222222222222222222222222222222222222222',
        '--version',
        '4.1.0',
        '--release-tag',
        'scripts-v4.1.0-0123456',
        '--tag-target-sha',
        SOURCE_SHA,
        '--output',
        windowsOutput,
      ],
      { cwd: TEST_REPO_ROOT, encoding: 'utf8' }
    );
    assert.equal(JSON.parse(readFileSync(windowsOutput, 'utf8')).templateSha256, templateSha);
  });
});
