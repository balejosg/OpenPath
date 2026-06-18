#!/usr/bin/env node

/**
 * Guards the Linux client release lane against the failure mode that broke machine `max12`:
 * the `stable` APT suite serves the `.deb` that manual installs and fresh enrollments receive
 * (`apt-setup.sh --stable` / `quick-install.sh`), but `stable` only advances on a `v*` tag. After
 * the 2026-05-10 extension-id rename (`monitor-bloqueos@openpath` -> `openpath-block-monitor@openpath`)
 * no stable release was cut for 5+ weeks, so `stable` kept serving a `.deb` whose managed-extension
 * id no longer matched the shipped XPI. Firefox refuses a force_installed extension whose downloaded
 * id != the policy key, so every such client loops forever on `firefox_registration_missing`.
 *
 * This check downloads the LATEST `stable` `openpath-dnsmasq` `.deb` (what a fresh install gets),
 * extracts the managed-extension id it defaults to, and FAILS when it differs from the gecko id in
 * `firefox-extension/manifest.json`. Run on push to main + a daily schedule: it goes red after any
 * id rename and stays red until a stable release republishes a matching `.deb`.
 */

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const currentFilePath = fileURLToPath(import.meta.url);
const scriptDir = dirname(currentFilePath);
const projectRoot = resolve(scriptDir, '..');
const FIREFOX_MANIFEST_PATH = resolve(projectRoot, 'firefox-extension/manifest.json');

export const DEFAULT_OPENPATH_APT_BASE_URL =
  'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt';
export const STABLE_SUITE = 'stable';
const STABLE_DEB_POLICY_PATH = 'usr/local/lib/openpath/lib/firefox-policy.sh';

/**
 * Extracts the env-default managed-extension id baked into a shipped `firefox-policy.sh`, i.e. the
 * `<id>` in `FIREFOX_MANAGED_EXTENSION_ID="${FIREFOX_MANAGED_EXTENSION_ID:-<id>}"`.
 */
export function parseManagedExtensionId(policyScriptText) {
  const match = String(policyScriptText ?? '').match(
    /FIREFOX_MANAGED_EXTENSION_ID="\$\{FIREFOX_MANAGED_EXTENSION_ID:-([^}"]+)\}"/
  );
  if (!match) {
    throw new Error(
      'Could not find a FIREFOX_MANAGED_EXTENSION_ID default in the stable client firefox-policy.sh'
    );
  }
  return match[1].trim();
}

/** Reads the Firefox extension gecko id from a parsed manifest.json (current key, legacy fallback). */
export function parseGeckoId(manifest) {
  const id =
    manifest?.browser_specific_settings?.gecko?.id ?? manifest?.applications?.gecko?.id ?? '';
  const normalized = String(id).trim();
  if (!normalized) {
    throw new Error('firefox-extension/manifest.json has no gecko id');
  }
  return normalized;
}

/** Parses APT `Packages` metadata into the list of advertised `openpath-dnsmasq` {version, filename}. */
export function parseStableDebCandidates(packagesText) {
  return String(packagesText ?? '')
    .split(/\n\s*\n/)
    .map((stanza) => {
      const fields = Object.fromEntries(
        stanza
          .split('\n')
          .map((line) => line.match(/^([^:]+):\s*(.*)$/))
          .filter(Boolean)
          .map((m) => [m[1].trim(), m[2].trim()])
      );
      return fields.Package === 'openpath-dnsmasq'
        ? { version: fields.Version ?? '', filename: fields.Filename ?? '' }
        : null;
    })
    .filter((entry) => entry && entry.version && entry.filename);
}

/**
 * Compares two Debian-ish version strings used by this repo (`N.N.N-R`, `0.0.<timestamp>-R`).
 * Returns >0 if a is newer, <0 if older, 0 if equal. Sufficient for the numeric forms this lane
 * publishes (full dpkg version semantics are not required here).
 */
export function compareDebVersions(a, b) {
  const toParts = (value) =>
    String(value ?? '')
      .split('-')[0]
      .split('.')
      .map((part) => Number.parseInt(part, 10) || 0);
  const aParts = toParts(a);
  const bParts = toParts(b);
  const length = Math.max(aParts.length, bParts.length);
  for (let i = 0; i < length; i += 1) {
    const diff = (aParts[i] ?? 0) - (bParts[i] ?? 0);
    if (diff !== 0) {
      return diff > 0 ? 1 : -1;
    }
  }
  return 0;
}

/** Picks the highest-versioned candidate (the `.deb` a fresh `apt-get install` would receive). */
export function selectLatestDebCandidate(candidates) {
  if (!Array.isArray(candidates) || candidates.length === 0) {
    throw new Error('The stable APT suite advertises no openpath-dnsmasq package');
  }
  return candidates.reduce((best, candidate) =>
    compareDebVersions(candidate.version, best.version) > 0 ? candidate : best
  );
}

/** Throws (fail-closed) when the stable client `.deb` id does not match the current manifest id. */
export function assertStableClientExtensionIdMatches({
  stableExtensionId,
  manifestExtensionId,
  stableVersion,
}) {
  if (stableExtensionId !== manifestExtensionId) {
    throw new Error(
      `Stable Linux client (openpath-dnsmasq=${stableVersion}) ships managed-extension id ` +
        `'${stableExtensionId}', but firefox-extension/manifest.json declares ` +
        `'${manifestExtensionId}'. A stable client with a mismatched id can never register the ` +
        `managed extension (firefox_registration_missing loop). Cut a stable OpenPath release ` +
        `(push a v* tag) so build-deb publishes a fresh stable .deb for the current id.`
    );
  }
}

export function buildStablePackagesUrl(baseUrl = DEFAULT_OPENPATH_APT_BASE_URL) {
  return `${String(baseUrl).replace(/\/+$/, '')}/dists/${STABLE_SUITE}/main/binary-amd64/Packages`;
}

async function fetchText(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to download ${url} (${response.status} ${response.statusText})`);
  }
  return response.text();
}

async function fetchBuffer(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to download ${url} (${response.status} ${response.statusText})`);
  }
  return Buffer.from(await response.arrayBuffer());
}

function readStableDebManagedExtensionId(debBuffer) {
  const workDir = mkdtempSync(join(tmpdir(), 'openpath-stable-deb-'));
  try {
    const debPath = join(workDir, 'openpath-dnsmasq.deb');
    const extractDir = join(workDir, 'extracted');
    writeFileSync(debPath, debBuffer);
    execFileSync('dpkg-deb', ['-x', debPath, extractDir], {
      stdio: ['ignore', 'ignore', 'inherit'],
    });
    const policy = readFileSync(join(extractDir, STABLE_DEB_POLICY_PATH), 'utf8');
    return parseManagedExtensionId(policy);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
}

async function main() {
  const baseUrl = process.env.OPENPATH_APT_BASE_URL?.trim() || DEFAULT_OPENPATH_APT_BASE_URL;
  const manifest = JSON.parse(readFileSync(FIREFOX_MANIFEST_PATH, 'utf8'));
  const manifestExtensionId = parseGeckoId(manifest);

  const packagesText = await fetchText(buildStablePackagesUrl(baseUrl));
  const latest = selectLatestDebCandidate(parseStableDebCandidates(packagesText));

  const debBuffer = await fetchBuffer(`${baseUrl.replace(/\/+$/, '')}/${latest.filename}`);
  const stableExtensionId = readStableDebManagedExtensionId(debBuffer);

  assertStableClientExtensionIdMatches({
    stableExtensionId,
    manifestExtensionId,
    stableVersion: latest.version,
  });

  console.log(
    `OK: stable openpath-dnsmasq=${latest.version} ships managed-extension id ` +
      `'${stableExtensionId}', matching firefox-extension/manifest.json.`
  );
}

if (process.argv[1] && resolve(process.argv[1]) === currentFilePath) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
