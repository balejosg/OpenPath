/**
 * Agent release signatures: the canonical signed text and its RSA/SHA-256
 * verification, identical to what the Windows agent checks before it downloads
 * any file (`windows/lib/internal/AgentReleaseSignature.ps1`).
 *
 * Canonical text (UTF-8, LF, every line newline-terminated):
 *   openpath-agent-release-v1
 *   <ring>
 *   <build>
 *   <sourceSha>
 *   <path>\t<sha256>        (sorted by path, ordinal)
 *
 * The public key is the agent's own `lib/agent-release-public-key.xml`
 * (.NET `RSAKeyValue`), so a release the API accepts is one the agents accept.
 */
import { createPublicKey, verify, type KeyObject } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import { getAgentArtifactRoots } from './server-asset-roots.js';

export const AGENT_RELEASE_CANONICAL_HEADER = 'openpath-agent-release-v1';

export interface AgentReleaseSignedFields {
  ring: string;
  build: string;
  sourceSha: string;
  files: readonly { path: string; sha256: string }[];
}

function compareOrdinal(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

export function buildAgentReleaseCanonicalText(release: AgentReleaseSignedFields): string {
  const lines = release.files.map((file) => `${file.path}\t${file.sha256}`).sort(compareOrdinal);
  let text = `${AGENT_RELEASE_CANONICAL_HEADER}\n${release.ring}\n${release.build}\n${release.sourceSha}\n`;
  for (const line of lines) {
    text += `${line}\n`;
  }
  return text;
}

function toBase64Url(value: string): string {
  return Buffer.from(value, 'base64').toString('base64url');
}

/** Parses a .NET `RSAKeyValue` public key; returns null when it is unusable. */
export function parseRsaPublicKeyXml(xml: string): KeyObject | null {
  const modulus = /<Modulus>\s*([A-Za-z0-9+/=\s]+?)\s*<\/Modulus>/.exec(xml)?.[1];
  const exponent = /<Exponent>\s*([A-Za-z0-9+/=\s]+?)\s*<\/Exponent>/.exec(xml)?.[1];
  if (!modulus || !exponent) {
    return null;
  }
  try {
    return createPublicKey({
      key: {
        kty: 'RSA',
        n: toBase64Url(modulus.replace(/\s+/g, '')),
        e: toBase64Url(exponent.replace(/\s+/g, '')),
      },
      format: 'jwk',
    });
  } catch {
    return null;
  }
}

/** The agent's shipped release public key, or null when it is missing or unusable. */
export function readAgentReleasePublicKey(): KeyObject | null {
  const keyPath = path.join(
    getAgentArtifactRoots().windowsAgentRoot,
    'lib',
    'agent-release-public-key.xml'
  );
  try {
    return parseRsaPublicKeyXml(fs.readFileSync(keyPath, 'utf8'));
  } catch {
    return null;
  }
}

const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

/**
 * Verifies a base64 RSA PKCS#1 v1.5 / SHA-256 signature over the canonical text.
 * The decoded signature must be exactly one modulus long, so a signature that
 * was base64-encoded twice is rejected instead of silently failing on agents.
 */
export function verifyAgentReleaseSignature(
  release: AgentReleaseSignedFields & { signature: string },
  publicKey: KeyObject
): boolean {
  const signatureText = release.signature.trim();
  if (!signatureText || signatureText.length % 4 !== 0 || !BASE64_PATTERN.test(signatureText)) {
    return false;
  }
  const signature = Buffer.from(signatureText, 'base64');
  const modulusBits = publicKey.asymmetricKeyDetails?.modulusLength ?? 0;
  if (modulusBits === 0 || signature.length !== Math.ceil(modulusBits / 8)) {
    return false;
  }
  try {
    return verify(
      'sha256',
      Buffer.from(buildAgentReleaseCanonicalText(release), 'utf8'),
      publicKey,
      signature
    );
  } catch {
    return false;
  }
}
