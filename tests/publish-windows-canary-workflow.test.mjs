// Contract for the manual Windows canary publication workflow.
// Guarded files: .github/workflows/publish-windows-canary.yml,
// scripts/build-windows-agent-release.mjs.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { generateKeyPairSync, sign } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, test } from 'node:test';

import {
  assertBrowserReleaseEntries,
  buildCanonicalText,
  computeBuild,
  readSignatureBase64,
  verifyPublicationSignature,
} from '../scripts/build-windows-agent-release.mjs';
import { extractWorkflowJobBlock, projectRoot, readText } from './repo-config/support.mjs';

function hasOpenssl() {
  try {
    execFileSync('openssl', ['version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function publicKeyXml(publicKey) {
  const jwk = publicKey.export({ format: 'jwk' });
  const modulus = Buffer.from(jwk.n, 'base64url').toString('base64');
  const exponent = Buffer.from(jwk.e, 'base64url').toString('base64');
  return `<RSAKeyValue><Modulus>${modulus}</Modulus><Exponent>${exponent}</Exponent></RSAKeyValue>`;
}

function samplePublication() {
  const files = [
    { path: 'lib/Alpha.psm1', sha256: '0'.repeat(64), contentBase64: 'YQ==' },
    { path: 'scripts/Run.ps1', sha256: '1'.repeat(64), contentBase64: 'Yg==' },
  ];
  return { build: computeBuild(files), sourceSha: 'a'.repeat(40), signature: '', files };
}

const WORKFLOW_PATH = '.github/workflows/publish-windows-canary.yml';
const SCRIPT_PATH = 'scripts/build-windows-agent-release.mjs';

describe('publish Windows canary workflow contract', () => {
  test('is manual dispatch only and requires an exact SHA', () => {
    const workflow = readText(WORKFLOW_PATH);

    assert.match(workflow, /^on:\n {2}workflow_dispatch:/m);
    assert.doesNotMatch(workflow, /^ {2}push:/m);
    assert.match(workflow, /inputs:\n {6}sha:\n/);
    assert.match(workflow, /required: true/);
    assert.match(workflow, /ref: \$\{\{ inputs\.sha \}\}/);
  });

  test('publication depends on a successful Windows Pester run for that SHA', () => {
    const workflow = readText(WORKFLOW_PATH);
    const gate = extractWorkflowJobBlock(workflow, 'require-windows-pester');
    const build = extractWorkflowJobBlock(workflow, 'build');
    const publish = extractWorkflowJobBlock(workflow, 'sign-and-publish');

    assert.match(gate, /head_sha=\$\{TARGET_SHA\}/);
    assert.match(gate, /conclusion == "success"/);
    assert.match(gate, /Windows Agent Tests/);
    assert.match(build, /needs: require-windows-pester/);
    assert.match(publish, /needs: build/);
  });

  test('the signing key is available only in the protected environment job', () => {
    const workflow = readText(WORKFLOW_PATH);
    const build = extractWorkflowJobBlock(workflow, 'build');
    const publish = extractWorkflowJobBlock(workflow, 'sign-and-publish');

    assert.match(publish, /environment: windows-canary-release/);
    assert.match(publish, /secrets\.OPENPATH_AGENT_RELEASE_SIGNING_KEY/);
    assert.match(publish, /openssl dgst -sha256 -sign/);
    assert.match(publish, /--publish-only/);
    assert.match(publish, /secrets\.OPENPATH_AGENT_RELEASE_TOKEN/);
    assert.doesNotMatch(build, /OPENPATH_AGENT_RELEASE_SIGNING_KEY/);
    assert.doesNotMatch(build, /OPENPATH_AGENT_RELEASE_TOKEN/);
    assert.equal((workflow.match(/secrets\.OPENPATH_AGENT_RELEASE_SIGNING_KEY/g) ?? []).length, 1);
  });

  test('builds the same file set the API serves and prints the build', () => {
    const workflow = readText(WORKFLOW_PATH);
    const script = readText(SCRIPT_PATH);

    assert.ok(existsSync(`${projectRoot}/${SCRIPT_PATH}`));
    assert.match(workflow, /build-windows-agent-release\.mjs/);
    assert.match(workflow, /--out "\$RUNNER_TEMP\/canary-release"/);
    assert.match(script, /buildWindowsAgentFileManifest/);
    assert.match(script, /openpath-agent-release-v1/);
    assert.match(script, /files\.sort\(\(left, right\)/);
    assert.match(script, /computeBuild/);
    assert.match(script, /contentBase64/);
    assert.match(script, /console\.log\(`build=\$\{build\}`\)/);
  });

  test('the published signature is the raw openssl output, never base64 text', () => {
    const workflow = readText(WORKFLOW_PATH);
    const publish = extractWorkflowJobBlock(workflow, 'sign-and-publish');

    assert.match(publish, /-out "\$RUNNER_TEMP\/canary-signature\.bin"/);
    assert.match(publish, /--signature-file "\$RUNNER_TEMP\/canary-signature\.bin"/);
    const commands = publish
      .split('\n')
      .filter((line) => !line.trimStart().startsWith('#'))
      .join('\n');
    assert.doesNotMatch(commands, /\bbase64\b/);
    assert.doesNotMatch(commands, /\.b64\b/);
  });

  test('what CI signs is what an agent verifies, end to end with a throwaway key', () => {
    const scratch = mkdtempSync(path.join(tmpdir(), 'canary-sign-'));
    try {
      const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 3072 });
      const publication = samplePublication();
      const canonicalPath = path.join(scratch, 'canonical.txt');
      writeFileSync(
        canonicalPath,
        buildCanonicalText(publication.files, publication.build, publication.sourceSha),
        'utf8'
      );
      const signaturePath = path.join(scratch, 'canary-signature.bin');
      if (hasOpenssl()) {
        const keyPath = path.join(scratch, 'key.pem');
        writeFileSync(keyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }));
        // The workflow's sign step, verbatim.
        execFileSync('openssl', [
          'dgst',
          '-sha256',
          '-sign',
          keyPath,
          '-out',
          signaturePath,
          canonicalPath,
        ]);
      } else {
        writeFileSync(signaturePath, sign('sha256', readFileSync(canonicalPath), privateKey));
      }
      const xml = publicKeyXml(publicKey);

      publication.signature = readSignatureBase64(signaturePath);
      assert.equal(Buffer.from(publication.signature, 'base64').length, 384);
      assert.equal(verifyPublicationSignature(publication, xml), true);

      // The defect this guards: a base64 text file passed as the signature file.
      const base64TextPath = path.join(scratch, 'canary-signature.b64');
      writeFileSync(base64TextPath, readFileSync(signaturePath).toString('base64'));
      publication.signature = readSignatureBase64(base64TextPath);
      assert.equal(verifyPublicationSignature(publication, xml), false);

      // A changed file hash after signing never verifies.
      publication.signature = readSignatureBase64(signaturePath);
      publication.files[0].sha256 = '2'.repeat(64);
      assert.equal(verifyPublicationSignature(publication, xml), false);
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  });

  test('the canary carries the signed Firefox release that stable ships', () => {
    const workflow = readText(WORKFLOW_PATH);
    const build = extractWorkflowJobBlock(workflow, 'build');

    assert.match(build, /uses: \.\/\.github\/actions\/prepare-firefox-release-artifacts/);
    assert.match(build, /sign-on-cache-miss: 'false'/);
    assert.match(build, /require-signed-artifacts: 'true'/);
    assert.doesNotMatch(build, /secrets\.WEB_EXT/);
    assert.match(build, /--omit-chromium-managed/);

    const complete = [
      { path: 'browser-extension/firefox-release/metadata.json' },
      { path: 'browser-extension/firefox-release/openpath-firefox-extension.xpi' },
      { path: 'lib/Alpha.psm1' },
    ];
    assert.deepEqual(assertBrowserReleaseEntries(complete, { omitChromiumManaged: true }), {
      required: [
        'browser-extension/firefox-release/metadata.json',
        'browser-extension/firefox-release/openpath-firefox-extension.xpi',
      ],
      omitted: ['browser-extension/chromium-managed/metadata.json'],
    });
    assert.throws(
      () =>
        assertBrowserReleaseEntries(
          complete.filter((file) => !file.path.endsWith('.xpi')),
          { omitChromiumManaged: true }
        ),
      /openpath-firefox-extension\.xpi/
    );
    assert.throws(
      () => assertBrowserReleaseEntries(complete, { omitChromiumManaged: false }),
      /chromium-managed\/metadata\.json/
    );
  });
});
