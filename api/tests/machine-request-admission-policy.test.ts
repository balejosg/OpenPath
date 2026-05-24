import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  admissionDomainMatchesRule,
  admissionOriginMatchesWhitelist,
  admissionTargetMatchesBlockedPath,
  extractAdmissionHostname,
} from '../src/services/machine-request-admission-policy.js';

await describe('machine request admission policy', async () => {
  await test('extracts normalized hostnames from URLs and host-like values', () => {
    assert.equal(
      extractAdmissionHostname(' HTTPS://Teacher.School.Example/path '),
      'teacher.school.example'
    );
    assert.equal(extractAdmissionHostname('cdn.example.com:443/script.js'), 'cdn.example.com');
    assert.equal(extractAdmissionHostname('   '), null);
  });

  await test('matches exact and wildcard whitelist origins without accepting malformed origins', () => {
    assert.equal(
      admissionOriginMatchesWhitelist('https://teacher.school.example/dashboard', [
        '*.school.example',
      ]),
      true
    );
    assert.equal(
      admissionOriginMatchesWhitelist('https://school.example/dashboard', ['*.school.example']),
      true
    );
    assert.equal(admissionOriginMatchesWhitelist('not a host', ['*.school.example']), false);
  });

  await test('matches exact subresource hosts against root whitelist rules', () => {
    assert.equal(admissionDomainMatchesRule('cdn.example.com', 'example.com'), true);
    assert.equal(admissionDomainMatchesRule('evil-example.com', 'example.com'), false);
  });

  await test('matches blocked path rules by host and path pattern', () => {
    assert.equal(
      admissionTargetMatchesBlockedPath('https://example.com/private/file.js?download=1', [
        'example.com/private/*',
      ]),
      true
    );
    assert.equal(
      admissionTargetMatchesBlockedPath('https://cdn.example.com/private/file.js', [
        'example.com/private/*',
      ]),
      true
    );
    assert.equal(
      admissionTargetMatchesBlockedPath('https://example.net/private/file.js', [
        'example.com/private/*',
      ]),
      false
    );
  });
});
