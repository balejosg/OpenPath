import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { describe, test } from 'node:test';

import {
  buildAgentReleaseCanonicalText,
  parseRsaPublicKeyXml,
  readAgentReleasePublicKey,
  verifyAgentReleaseSignature,
} from '../src/lib/agent-release-signature.js';

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });

function toXml(): string {
  const jwk = publicKey.export({ format: 'jwk' });
  const modulus = Buffer.from(String(jwk.n), 'base64url').toString('base64');
  const exponent = Buffer.from(String(jwk.e), 'base64url').toString('base64');
  return `<RSAKeyValue><Modulus>${modulus}</Modulus><Exponent>${exponent}</Exponent></RSAKeyValue>`;
}

const release = {
  ring: 'canary',
  build: 'b'.repeat(64),
  sourceSha: 'a'.repeat(40),
  files: [
    { path: 'scripts/Run.ps1', sha256: '2'.repeat(64) },
    { path: 'lib/Zeta.psm1', sha256: '1'.repeat(64) },
    { path: 'lib/Alpha.psm1', sha256: '0'.repeat(64) },
  ],
};

await describe('agent release signature', async () => {
  await test('the canonical text matches the agent format, sorted by ordinal path', () => {
    assert.equal(
      buildAgentReleaseCanonicalText(release),
      [
        'openpath-agent-release-v1',
        'canary',
        'b'.repeat(64),
        'a'.repeat(40),
        `lib/Alpha.psm1\t${'0'.repeat(64)}`,
        `lib/Zeta.psm1\t${'1'.repeat(64)}`,
        `scripts/Run.ps1\t${'2'.repeat(64)}`,
        '',
      ].join('\n')
    );
  });

  await test('a signature from the matching key verifies through the XML key', () => {
    const key = parseRsaPublicKeyXml(toXml());
    assert.ok(key);
    const signature = sign(
      'sha256',
      Buffer.from(buildAgentReleaseCanonicalText(release), 'utf8'),
      privateKey
    ).toString('base64');

    assert.equal(verifyAgentReleaseSignature({ ...release, signature }, key), true);
    assert.equal(
      verifyAgentReleaseSignature({ ...release, ring: 'stable', signature }, key),
      false
    );
    assert.equal(
      verifyAgentReleaseSignature(
        { ...release, signature: Buffer.from(signature).toString('base64') },
        key
      ),
      false
    );
    assert.equal(verifyAgentReleaseSignature({ ...release, signature: 'not base64!' }, key), false);
    assert.equal(verifyAgentReleaseSignature({ ...release, signature: '' }, key), false);
  });

  await test('an unusable XML key is null', () => {
    assert.equal(parseRsaPublicKeyXml('<RSAKeyValue></RSAKeyValue>'), null);
    assert.equal(
      parseRsaPublicKeyXml(
        '<RSAKeyValue><Modulus>AA==</Modulus><Exponent></Exponent></RSAKeyValue>'
      ),
      null
    );
  });

  await test('the shipped agent public key parses', () => {
    const key = readAgentReleasePublicKey();
    assert.ok(key);
    assert.ok((key.asymmetricKeyDetails?.modulusLength ?? 0) >= 2048);
  });
});
