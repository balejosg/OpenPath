import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { describe, test } from 'node:test';

import {
  buildOpenPathPromotionContract,
  buildOpenPathPromotionContractV2,
  classifyImmutableTagPublication,
  publishImmutablePromotionContract,
  resolvePromotionContractComponents,
  serializeOpenPathPromotionContract,
  serializeOpenPathPromotionContractV2,
  verifyBrowserPolicyArtifact,
  verifyLinuxPromotionArtifact,
  verifyWindowsPromotionArtifact,
} from '../scripts/openpath-promotion-contract.mjs';

const SOURCE_SHA = '0123456789abcdef0123456789abcdef01234567';
const PREVIOUS_SOURCE_SHA = 'fedcba9876543210fedcba9876543210fedcba98';
const LINUX_INPUTS_SHA = '1111111111111111111111111111111111111111111111111111111111111111';
const WINDOWS_INPUTS_SHA = '2222222222222222222222222222222222222222222222222222222222222222';
const BROWSER_INPUTS_SHA = '3333333333333333333333333333333333333333333333333333333333333333';
const TEMPLATE_SHA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const MANIFEST_SHA = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

function makeV2Components({ sourceSha = SOURCE_SHA } = {}) {
  return {
    linuxAgent: {
      sourceSha,
      inputsSha256: LINUX_INPUTS_SHA,
      packageName: 'openpath-dnsmasq',
      packageVersion: '0.0.412-1',
      aptSuite: 'stable',
      filename: 'pool/stable/main/openpath-dnsmasq_0.0.412-1_amd64.deb',
      sha256: '4444444444444444444444444444444444444444444444444444444444444444',
    },
    windowsOfflineInstaller: {
      sourceSha,
      inputsSha256: WINDOWS_INPUTS_SHA,
      version: '4.1.0',
      releaseTag: `scripts-v4.1.0-${sourceSha.slice(0, 7)}`,
      templateAsset: 'OpenPath-Windows-Setup-Template.exe',
      templateSha256: TEMPLATE_SHA,
      payloadManifestAsset: 'payload-manifest.json',
      payloadManifestSha256: MANIFEST_SHA,
    },
    browserPolicy: {
      sourceSha,
      inputsSha256: BROWSER_INPUTS_SHA,
      firefoxExtensionVersion: '2.0.1',
      browserPolicySpecSha256: '5555555555555555555555555555555555555555555555555555555555555555',
    },
  };
}

describe('OpenPath promotion contract', () => {
  test('builds a standalone promotion contract for an exact OpenPath SHA', () => {
    const contract = buildOpenPathPromotionContract({
      openpathSha: '0123456789abcdef0123456789abcdef01234567',
      packageVersion: '0.0.412',
      linuxAgentVersion: '0.0.412',
      aptSuite: 'unstable',
      firefoxExtensionVersion: '4.1.25',
      browserPolicySpecSha256: 'meta123',
    });

    assert.deepEqual(contract, {
      version: 1,
      openpathSha: '0123456789abcdef0123456789abcdef01234567',
      packageVersion: '0.0.412',
      linuxAgentVersion: '0.0.412',
      aptSuite: 'unstable',
      firefoxExtensionVersion: '4.1.25',
      browserPolicySpecSha256: 'meta123',
    });
  });

  test('serializes the promotion contract as stable JSON', () => {
    const serialized = serializeOpenPathPromotionContract({
      version: 1,
      openpathSha: '0123456789abcdef0123456789abcdef01234567',
      packageVersion: '4.1.25',
      linuxAgentVersion: '4.1.25',
      aptSuite: 'stable',
      firefoxExtensionVersion: '4.1.25',
      browserPolicySpecSha256: 'meta123',
    });

    assert.equal(
      serialized,
      `${JSON.stringify(
        {
          version: 1,
          openpathSha: '0123456789abcdef0123456789abcdef01234567',
          packageVersion: '4.1.25',
          linuxAgentVersion: '4.1.25',
          aptSuite: 'stable',
          firefoxExtensionVersion: '4.1.25',
          browserPolicySpecSha256: 'meta123',
        },
        null,
        2
      )}\n`
    );
  });

  test('builds the complete generic v2 contract with deterministic bytes', () => {
    const contract = buildOpenPathPromotionContractV2({
      openpathSha: SOURCE_SHA,
      openpathVersion: '4.1.0',
      components: makeV2Components(),
    });

    assert.deepEqual(contract, {
      schemaVersion: 2,
      openpathSha: SOURCE_SHA,
      openpathVersion: '4.1.0',
      interfaces: {
        wrapperIntegration: 1,
        windowsOfflineInstaller: 1,
        readiness: 1,
      },
      components: makeV2Components(),
    });

    const reordered = {
      components: {
        browserPolicy: contract.components.browserPolicy,
        windowsOfflineInstaller: contract.components.windowsOfflineInstaller,
        linuxAgent: contract.components.linuxAgent,
      },
      interfaces: {
        readiness: 1,
        windowsOfflineInstaller: 1,
        wrapperIntegration: 1,
      },
      openpathVersion: '4.1.0',
      openpathSha: SOURCE_SHA,
      schemaVersion: 2,
    };

    assert.equal(
      serializeOpenPathPromotionContractV2(contract),
      serializeOpenPathPromotionContractV2(reordered)
    );
    assert.equal(
      serializeOpenPathPromotionContractV2(contract),
      `${JSON.stringify(contract, null, 2)}\n`
    );
  });

  test('rejects volatile fields, malformed hashes, unsupported interfaces, and mismatched release tags', () => {
    const cases = [
      {
        name: 'volatile top-level field',
        mutate: (contract) => {
          contract.generatedAt = '2026-08-30T00:00:00.000Z';
        },
        expected: /unknown property.*generatedAt/i,
      },
      {
        name: 'uppercase source SHA',
        mutate: (contract) => {
          contract.openpathSha = SOURCE_SHA.toUpperCase();
        },
        expected: /openpathSha.*40-character lowercase/i,
      },
      {
        name: 'wrong interface version',
        mutate: (contract) => {
          contract.interfaces.readiness = 2;
        },
        expected: /interfaces\.readiness.*1/i,
      },
      {
        name: 'mismatched release tag',
        mutate: (contract) => {
          contract.components.windowsOfflineInstaller.releaseTag = 'scripts-v4.1.0-fedcba9';
        },
        expected: /releaseTag.*sourceSha/i,
      },
      {
        name: 'malformed component SHA-256',
        mutate: (contract) => {
          contract.components.browserPolicy.inputsSha256 = 'not-a-sha';
        },
        expected: /inputsSha256.*64-character SHA-256/i,
      },
    ];

    for (const { name, mutate, expected } of cases) {
      const contract = buildOpenPathPromotionContractV2({
        openpathSha: SOURCE_SHA,
        openpathVersion: '4.1.0',
        components: makeV2Components(),
      });
      mutate(contract);
      assert.throws(() => serializeOpenPathPromotionContractV2(contract), expected, name);
    }
  });

  test('inherits only components whose current canonical inputs fingerprint is identical', () => {
    const previous = buildOpenPathPromotionContractV2({
      openpathSha: PREVIOUS_SOURCE_SHA,
      openpathVersion: '4.0.9',
      components: makeV2Components({ sourceSha: PREVIOUS_SOURCE_SHA }),
    });
    const current = makeV2Components();
    current.browserPolicy.inputsSha256 =
      '6666666666666666666666666666666666666666666666666666666666666666';

    const resolved = resolvePromotionContractComponents({
      currentComponents: current,
      previousContract: previous,
    });

    assert.equal(resolved.linuxAgent.sourceSha, PREVIOUS_SOURCE_SHA);
    assert.equal(resolved.windowsOfflineInstaller.sourceSha, PREVIOUS_SOURCE_SHA);
    assert.equal(resolved.browserPolicy.sourceSha, SOURCE_SHA);
    assert.equal(resolved.browserPolicy.inputsSha256, current.browserPolicy.inputsSha256);
  });

  test('requires a complete current component when its fingerprint changed', () => {
    const previous = buildOpenPathPromotionContractV2({
      openpathSha: PREVIOUS_SOURCE_SHA,
      openpathVersion: '4.0.9',
      components: makeV2Components({ sourceSha: PREVIOUS_SOURCE_SHA }),
    });
    const current = makeV2Components();
    current.linuxAgent.inputsSha256 =
      '7777777777777777777777777777777777777777777777777777777777777777';
    delete current.linuxAgent.filename;

    assert.throws(
      () =>
        resolvePromotionContractComponents({
          currentComponents: current,
          previousContract: previous,
        }),
      /linuxAgent.*filename.*required/i
    );
  });

  test('does not inherit from a missing or partial previous v2 contract', () => {
    const current = makeV2Components();
    assert.deepEqual(
      resolvePromotionContractComponents({ currentComponents: current, previousContract: null }),
      current
    );

    const previous = buildOpenPathPromotionContractV2({
      openpathSha: PREVIOUS_SOURCE_SHA,
      openpathVersion: '4.0.9',
      components: makeV2Components({ sourceSha: PREVIOUS_SOURCE_SHA }),
    });
    delete previous.components.browserPolicy;
    assert.throws(
      () =>
        resolvePromotionContractComponents({
          currentComponents: current,
          previousContract: previous,
        }),
      /components\.browserPolicy.*required/i
    );
  });

  test('publishes a v2 contract create/identical-ok/different-fail without replacing bytes', () => {
    const directory = mkdtempSync(join(tmpdir(), 'openpath-promotion-contract-'));
    const outputPath = join(directory, 'promotion-contracts', 'v2', `${SOURCE_SHA}.json`);
    const contract = buildOpenPathPromotionContractV2({
      openpathSha: SOURCE_SHA,
      openpathVersion: '4.1.0',
      components: makeV2Components(),
    });

    assert.deepEqual(publishImmutablePromotionContract({ outputPath, contract }), {
      status: 'created',
    });
    const originalBytes = readFileSync(outputPath);
    assert.deepEqual(publishImmutablePromotionContract({ outputPath, contract }), {
      status: 'identical',
    });

    const different = buildOpenPathPromotionContractV2({
      openpathSha: SOURCE_SHA,
      openpathVersion: '4.1.1',
      components: makeV2Components(),
    });
    assert.throws(
      () => publishImmutablePromotionContract({ outputPath, contract: different }),
      /immutable.*different bytes/i
    );
    assert.deepEqual(readFileSync(outputPath), originalBytes);
    assert.throws(
      () =>
        publishImmutablePromotionContract({
          outputPath: join(directory, 'promotion-contracts', 'v2', 'wrong.json'),
          contract,
        }),
      /path must be keyed/i
    );
  });

  test('verifies Linux provenance against Packages metadata, suite metadata, and physical bytes', () => {
    const packageBytes = Buffer.from('physical deb bytes');
    const packageSha = createHash('sha256').update(packageBytes).digest('hex');
    const filename = 'pool/stable/main/openpath-dnsmasq_0.0.412-1_amd64.deb';
    const packagesText = [
      'Package: openpath-dnsmasq',
      'Version: 0.0.412-1',
      `Filename: ${filename}`,
      `SHA256: ${packageSha}`,
      '',
    ].join('\n');
    const releaseText = ['Suite: stable', 'Codename: stable', ''].join('\n');

    const component = verifyLinuxPromotionArtifact({
      sourceSha: SOURCE_SHA,
      inputsSha256: LINUX_INPUTS_SHA,
      aptSuite: 'stable',
      packagesText,
      releaseText,
      filename,
      artifactBytes: packageBytes,
    });

    assert.deepEqual(component, {
      sourceSha: SOURCE_SHA,
      inputsSha256: LINUX_INPUTS_SHA,
      packageName: 'openpath-dnsmasq',
      packageVersion: '0.0.412-1',
      aptSuite: 'stable',
      filename,
      sha256: packageSha,
    });

    assert.throws(
      () =>
        verifyLinuxPromotionArtifact({
          sourceSha: SOURCE_SHA,
          inputsSha256: LINUX_INPUTS_SHA,
          aptSuite: 'stable',
          packagesText,
          releaseText,
          filename,
          artifactBytes: Buffer.from('different bytes'),
        }),
      /physical.*SHA256|artifact.*SHA256/i
    );
  });

  test('verifies browser-policy provenance from the physical manifest and policy specification', () => {
    const policySpecBytes = Buffer.from('{"schemaVersion":1,"rules":[]}\n');
    const policySpecSha = createHash('sha256').update(policySpecBytes).digest('hex');

    assert.deepEqual(
      verifyBrowserPolicyArtifact({
        sourceSha: SOURCE_SHA,
        inputsSha256: BROWSER_INPUTS_SHA,
        manifestText: '{"version":"2.0.1"}\n',
        policySpecBytes,
      }),
      {
        sourceSha: SOURCE_SHA,
        inputsSha256: BROWSER_INPUTS_SHA,
        firefoxExtensionVersion: '2.0.1',
        browserPolicySpecSha256: policySpecSha,
      }
    );

    assert.throws(
      () =>
        verifyBrowserPolicyArtifact({
          sourceSha: SOURCE_SHA,
          inputsSha256: BROWSER_INPUTS_SHA,
          manifestText: '{"version":"2.0.1"}\n',
          policySpecBytes: Buffer.from('not-json'),
        }),
      /policy specification.*JSON/i
    );
  });

  test('verifies Windows provenance through tag, release assets, sidecar, and physical bytes', () => {
    const templateBytes = Buffer.from('physical template bytes');
    const payloadManifestBytes = Buffer.from('{"schemaVersion":1,"payloads":[]}\n');
    const templateSha = createHash('sha256').update(templateBytes).digest('hex');
    const payloadManifestSha = createHash('sha256').update(payloadManifestBytes).digest('hex');
    const releaseTag = 'scripts-v4.1.0-0123456';

    const component = verifyWindowsPromotionArtifact({
      sourceSha: SOURCE_SHA,
      inputsSha256: WINDOWS_INPUTS_SHA,
      version: '4.1.0',
      releaseTag,
      tagTargetSha: SOURCE_SHA,
      release: { tag_name: releaseTag },
      releaseAssets: [
        { name: 'OpenPath-Windows-Setup-Template.exe', bytes: templateBytes },
        {
          name: 'OpenPath-Windows-Setup-Template.exe.sha256',
          bytes: Buffer.from(`${templateSha}  OpenPath-Windows-Setup-Template.exe\n`),
        },
        { name: 'payload-manifest.json', bytes: payloadManifestBytes },
      ],
    });

    assert.deepEqual(component, {
      sourceSha: SOURCE_SHA,
      inputsSha256: WINDOWS_INPUTS_SHA,
      version: '4.1.0',
      releaseTag,
      templateAsset: 'OpenPath-Windows-Setup-Template.exe',
      templateSha256: templateSha,
      payloadManifestAsset: 'payload-manifest.json',
      payloadManifestSha256: payloadManifestSha,
    });

    assert.throws(
      () =>
        verifyWindowsPromotionArtifact({
          sourceSha: SOURCE_SHA,
          inputsSha256: WINDOWS_INPUTS_SHA,
          version: '4.1.0',
          releaseTag,
          tagTargetSha: PREVIOUS_SOURCE_SHA,
          releaseTagName: releaseTag,
          releaseAssets: [],
        }),
      /tag.*sourceSha/i
    );

    assert.throws(
      () =>
        verifyWindowsPromotionArtifact({
          sourceSha: SOURCE_SHA,
          inputsSha256: WINDOWS_INPUTS_SHA,
          version: '4.1.0',
          releaseTag,
          tagTargetSha: SOURCE_SHA,
          releaseTagName: releaseTag,
          releaseAssets: [
            { name: 'OpenPath-Windows-Setup-Template.exe', bytes: templateBytes },
            {
              name: 'OpenPath-Windows-Setup-Template.exe.sha256',
              bytes: Buffer.from(`${'0'.repeat(64)}  OpenPath-Windows-Setup-Template.exe\n`),
            },
            { name: 'payload-manifest.json', bytes: payloadManifestBytes },
          ],
        }),
      /sidecar SHA256/i
    );

    assert.throws(
      () =>
        verifyWindowsPromotionArtifact({
          sourceSha: SOURCE_SHA,
          inputsSha256: WINDOWS_INPUTS_SHA,
          version: '4.1.0',
          releaseTag,
          tagTargetSha: SOURCE_SHA,
          releaseTagName: releaseTag,
          releaseAssets: [
            { name: 'OpenPath-Windows-Setup-Template.exe', bytes: templateBytes },
            {
              name: 'OpenPath-Windows-Setup-Template.exe.sha256',
              bytes: Buffer.from(`${templateSha}  OpenPath-Windows-Setup-Template.exe\n`),
            },
          ],
        }),
      /missing authoritative asset.*payload-manifest/i
    );
  });

  test('classifies immutable tag publication without treating a conflicting target as recoverable', () => {
    assert.equal(
      classifyImmutableTagPublication({ sourceSha: SOURCE_SHA, existingTargetSha: '' }),
      'create'
    );
    assert.equal(
      classifyImmutableTagPublication({ sourceSha: SOURCE_SHA, existingTargetSha: SOURCE_SHA }),
      'identical'
    );
    assert.throws(
      () =>
        classifyImmutableTagPublication({
          sourceSha: SOURCE_SHA,
          existingTargetSha: PREVIOUS_SOURCE_SHA,
        }),
      /tag.*different target/i
    );
  });
});
