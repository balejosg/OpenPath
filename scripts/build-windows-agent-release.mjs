#!/usr/bin/env node
/**
 * Build the complete Windows agent file set for a canary release.
 *
 * The selection comes from the same `buildWindowsAgentFileManifest` the API
 * serves, so a canary converges on exactly the file set a stable release would
 * publish. The script writes:
 *
 *   <out>/files.json         [{ path, sha256, size, contentBase64 }]
 *   <out>/canonical.txt      the exact RSA/SHA-256 signed text
 *   <out>/publication.json   the POST body for /api/agent/windows/releases
 *   <out>/meta.json          build, sourceSha, fileCount
 *
 * Signing happens outside this script, in a protected GitHub environment. The
 * signature file is the RAW signature (`openssl dgst -out`), never base64 text:
 * this script base64-encodes it exactly once, and verifies it against the
 * agent's committed public key before anything is published.
 *
 *   openssl dgst -sha256 -sign key.pem -out signature.bin <out>/canonical.txt
 *   node scripts/build-windows-agent-release.mjs --sha <commit> --out <out> \
 *     --signature-file signature.bin --publish-only
 *
 * The browser release entries (the AMO-signed Firefox release and its metadata)
 * must be present, so a canary carries the same browser release as stable; a
 * missing one fails the build instead of being silently skipped. The managed
 * Chromium metadata cannot be reproduced in CI (its extension id comes from the
 * packaging key of the host that built it); it is left out explicitly with
 * --omit-chromium-managed and reported, and agents keep their installed copy.
 *
 * Usage:
 *   node scripts/build-windows-agent-release.mjs --sha <commit> --out <dir>
 *       [--omit-chromium-managed] [--signature-file <file>] [--publish | --publish-only]
 */
import { createHash, createPublicKey, verify } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export const REQUIRED_BROWSER_RELEASE_PATHS = [
  'browser-extension/firefox-release/metadata.json',
  'browser-extension/firefox-release/openpath-firefox-extension.xpi',
];
export const CHROMIUM_MANAGED_METADATA_PATH = 'browser-extension/chromium-managed/metadata.json';
export const AGENT_RELEASE_PUBLIC_KEY_PATH = path.join(
  repoRoot,
  'windows',
  'lib',
  'agent-release-public-key.xml'
);

function fail(message) {
  console.error(`[build-windows-agent-release] ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = {
    sha: '',
    out: '',
    signatureFile: '',
    publish: false,
    publishOnly: false,
    omitChromiumManaged: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--sha') args.sha = argv[++index] ?? '';
    else if (arg === '--out') args.out = argv[++index] ?? '';
    else if (arg === '--signature-file') args.signatureFile = argv[++index] ?? '';
    else if (arg === '--publish') args.publish = true;
    else if (arg === '--publish-only') args.publishOnly = true;
    else if (arg === '--omit-chromium-managed') args.omitChromiumManaged = true;
    else fail(`unknown argument: ${arg}`);
  }
  if (!args.sha) fail('--sha is required');
  if (!args.out) fail('--out is required');
  return args;
}

function resolveRepoHead() {
  return execFileSync('git', ['-C', repoRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
}

function assertCleanWorkingTree() {
  const status = execFileSync('git', ['-C', repoRoot, 'status', '--porcelain'], {
    encoding: 'utf8',
  }).trim();
  if (status) {
    fail('working tree is not clean; a canary release must be built from the exact commit');
  }
}

function setArtifactRoots() {
  process.env.OPENPATH_WINDOWS_AGENT_ROOT ??= path.join(repoRoot, 'windows');
  process.env.OPENPATH_SHARED_RUNTIME_ROOT ??= path.join(repoRoot, 'runtime');
  process.env.OPENPATH_FIREFOX_EXTENSION_ROOT ??= path.join(repoRoot, 'firefox-extension');
  process.env.OPENPATH_FIREFOX_RELEASE_ROOT ??= path.join(
    repoRoot,
    'firefox-extension',
    'build',
    'firefox-release'
  );
  process.env.OPENPATH_CHROMIUM_MANAGED_ROOT ??= path.join(
    repoRoot,
    'firefox-extension',
    'build',
    'chromium-managed'
  );
  process.env.OPENPATH_AGENT_VERSION_FILE ??= path.join(repoRoot, 'VERSION');
}

export function computeBuild(files) {
  return createHash('sha256')
    .update(files.map((file) => `${file.path}\t${file.sha256}\n`).join(''))
    .digest('hex');
}

export function buildCanonicalText(files, build, sourceSha) {
  const sorted = [...files].sort((left, right) =>
    left.path < right.path ? -1 : left.path > right.path ? 1 : 0
  );
  let text = `openpath-agent-release-v1\ncanary\n${build}\n${sourceSha}\n`;
  for (const file of sorted) {
    text += `${file.path}\t${file.sha256}\n`;
  }
  return text;
}

/** The raw signature file (openssl dgst -out) as the one base64 string agents decode. */
export function readSignatureBase64(signatureFile) {
  return fs.readFileSync(signatureFile).toString('base64');
}

function toBase64Url(base64) {
  return Buffer.from(base64, 'base64').toString('base64url');
}

/** Parses the agent's .NET RSAKeyValue public key into a Node key. */
export function parsePublicKeyXml(xml) {
  const modulus = /<Modulus>\s*([A-Za-z0-9+/=\s]+?)\s*<\/Modulus>/.exec(xml)?.[1];
  const exponent = /<Exponent>\s*([A-Za-z0-9+/=\s]+?)\s*<\/Exponent>/.exec(xml)?.[1];
  if (!modulus || !exponent) {
    throw new Error('the agent release public key has no Modulus/Exponent');
  }
  return createPublicKey({
    key: {
      kty: 'RSA',
      n: toBase64Url(modulus.replace(/\s+/g, '')),
      e: toBase64Url(exponent.replace(/\s+/g, '')),
    },
    format: 'jwk',
  });
}

/**
 * Verifies the publication exactly as an agent does: base64-decode the
 * signature once and check RSA PKCS#1 v1.5 / SHA-256 over the canonical text
 * rebuilt from the publication itself, with the agent's public key.
 */
export function verifyPublicationSignature(publication, publicKeyXml) {
  const publicKey = parsePublicKeyXml(publicKeyXml);
  const signature = Buffer.from(String(publication.signature ?? ''), 'base64');
  const modulusBytes = Math.ceil((publicKey.asymmetricKeyDetails?.modulusLength ?? 0) / 8);
  if (signature.length !== modulusBytes) {
    return false;
  }
  const canonical = buildCanonicalText(publication.files, publication.build, publication.sourceSha);
  return verify('sha256', Buffer.from(canonical, 'utf8'), publicKey, signature);
}

/** Fails unless every required browser release entry is in the file set. */
export function assertBrowserReleaseEntries(files, { omitChromiumManaged }) {
  const present = new Set(files.map((file) => file.path));
  const required = omitChromiumManaged
    ? REQUIRED_BROWSER_RELEASE_PATHS
    : [...REQUIRED_BROWSER_RELEASE_PATHS, CHROMIUM_MANAGED_METADATA_PATH];
  const missing = required.filter((entry) => !present.has(entry));
  if (missing.length > 0) {
    throw new Error(
      `the release is missing browser release entries: ${missing.join(', ')}; ` +
        'restore the signed Firefox release (and the managed Chromium metadata) before building'
    );
  }
  const omitted =
    omitChromiumManaged && !present.has(CHROMIUM_MANAGED_METADATA_PATH)
      ? [CHROMIUM_MANAGED_METADATA_PATH]
      : [];
  return { required, omitted };
}

async function loadManifestBuilder() {
  const modulePath = path.join(repoRoot, 'api', 'dist', 'src', 'lib', 'server-asset-windows.js');
  if (!fs.existsSync(modulePath)) {
    fail(
      'build the @openpath/api workspace first (api/dist/src/lib/server-asset-windows.js is missing)'
    );
  }
  return import(modulePath);
}

async function publishPreparedRelease({ out, expectedSha, signatureFile }) {
  const publicationPath = path.join(out, 'publication.json');
  if (!fs.existsSync(publicationPath)) {
    fail(`prepared release not found: ${publicationPath}`);
  }
  const publication = JSON.parse(fs.readFileSync(publicationPath, 'utf8'));
  if (publication.sourceSha !== expectedSha) {
    fail(`prepared release is for ${String(publication.sourceSha)}, not ${expectedSha}`);
  }
  if (signatureFile) {
    publication.signature = readSignatureBase64(signatureFile);
  }
  if (!publication.signature) {
    fail('the prepared release has no signature');
  }
  if (
    !verifyPublicationSignature(publication, fs.readFileSync(AGENT_RELEASE_PUBLIC_KEY_PATH, 'utf8'))
  ) {
    fail(
      'the signature does not verify against windows/lib/agent-release-public-key.xml; ' +
        'pass the raw openssl signature file and check that the signing key matches the agent key'
    );
  }

  const apiUrl = (process.env.OPENPATH_API_URL ?? '').trim().replace(/\/+$/, '');
  const token = (process.env.OPENPATH_AGENT_RELEASE_TOKEN ?? '').trim();
  if (!apiUrl) fail('OPENPATH_API_URL is required to publish');
  if (!token) fail('OPENPATH_AGENT_RELEASE_TOKEN is required to publish');

  const response = await fetch(`${apiUrl}/api/agent/windows/releases`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(publication),
  });
  const bodyText = await response.text();
  if (!response.ok) {
    fail(`publish failed with HTTP ${String(response.status)}: ${bodyText.slice(0, 500)}`);
  }
  const body = JSON.parse(bodyText);
  const publishedBuild = body?.release?.build;
  if (publishedBuild !== publication.build) {
    fail(
      `server published build ${String(publishedBuild)} instead of ${String(publication.build)}`
    );
  }
  console.log(`build=${String(publication.build)}`);
  console.log(`published=${publishedBuild}`);
  return publishedBuild;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.publishOnly) {
    const head = resolveRepoHead();
    if (head !== args.sha.trim()) {
      fail(`checkout is at ${head}, not the requested ${args.sha}`);
    }
    assertCleanWorkingTree();
    await publishPreparedRelease({
      out: args.out,
      expectedSha: args.sha.trim(),
      signatureFile: args.signatureFile,
    });
    return;
  }

  const head = resolveRepoHead();
  if (head !== args.sha.trim()) {
    fail(`checkout is at ${head}, not the requested ${args.sha}`);
  }
  assertCleanWorkingTree();

  setArtifactRoots();
  const { buildWindowsAgentFileManifest } = await loadManifestBuilder();
  const manifest = buildWindowsAgentFileManifest();
  if (manifest.length === 0) {
    fail('the Windows agent file set is empty');
  }

  const files = manifest.map((entry) => {
    const content = fs.readFileSync(entry.absolutePath);
    const sha256 = createHash('sha256').update(content).digest('hex');
    if (sha256 !== entry.sha256) {
      fail(`hash changed while reading ${entry.relativePath}`);
    }
    return {
      path: entry.relativePath,
      sha256,
      size: content.length,
      contentBase64: content.toString('base64'),
    };
  });
  // The API computes the published build over ordinal path order; sort here so
  // the declared build and the stored build are the same fingerprint.
  files.sort((left, right) => (left.path < right.path ? -1 : left.path > right.path ? 1 : 0));
  const build = computeBuild(files);
  const canonical = buildCanonicalText(files, build, args.sha.trim());

  let browserRelease;
  try {
    browserRelease = assertBrowserReleaseEntries(files, {
      omitChromiumManaged: args.omitChromiumManaged,
    });
  } catch (error) {
    fail(error instanceof Error ? error.message : String(error));
  }
  for (const entry of browserRelease.required) {
    console.log(`browser-release=${entry}`);
  }
  for (const entry of browserRelease.omitted) {
    console.log(`omitted=${entry} (agents keep their installed copy)`);
  }

  const signature = args.signatureFile ? readSignatureBase64(args.signatureFile) : '';

  fs.mkdirSync(args.out, { recursive: true });
  fs.writeFileSync(path.join(args.out, 'files.json'), JSON.stringify(files), 'utf8');
  fs.writeFileSync(path.join(args.out, 'canonical.txt'), canonical, 'utf8');
  const publication = {
    build,
    sourceSha: args.sha.trim(),
    signature,
    files: files.map((file) => ({
      path: file.path,
      sha256: file.sha256,
      contentBase64: file.contentBase64,
    })),
  };
  fs.writeFileSync(path.join(args.out, 'publication.json'), JSON.stringify(publication), 'utf8');
  fs.writeFileSync(
    path.join(args.out, 'meta.json'),
    JSON.stringify(
      {
        build,
        sourceSha: args.sha.trim(),
        fileCount: files.length,
        browserRelease: browserRelease.required,
        omitted: browserRelease.omitted,
      },
      null,
      2
    ) + '\n',
    'utf8'
  );

  console.log(`build=${build}`);
  console.log(`files=${String(files.length)}`);
  console.log(`canonical=${path.join(args.out, 'canonical.txt')}`);

  if (args.publish) {
    if (!signature) fail('--publish requires --signature-file');
    await publishPreparedRelease({
      out: args.out,
      expectedSha: args.sha.trim(),
      signatureFile: args.signatureFile,
    });
  } else {
    console.log('published=no');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    fail(error instanceof Error ? (error.stack ?? error.message) : String(error));
  });
}
