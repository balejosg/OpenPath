import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  extractAgentReleaseToken,
  isAgentReleaseTokenAuthorized,
} from '../src/lib/agent-release-auth.js';

function request(headers: Record<string, string>): { get(name: string): string | undefined } {
  return { get: (name: string): string | undefined => headers[name.toLowerCase()] };
}

await describe('agent release token', async () => {
  await test('reads a bearer token or the release header', () => {
    assert.equal(extractAgentReleaseToken(request({ authorization: 'Bearer abc' })), 'abc');
    assert.equal(extractAgentReleaseToken(request({ 'x-openpath-release-token': ' xyz ' })), 'xyz');
    assert.equal(extractAgentReleaseToken(request({})), null);
  });

  await test('authorizes only the exact configured token', () => {
    assert.equal(
      isAgentReleaseTokenAuthorized('secret', request({ authorization: 'Bearer secret' })),
      true
    );
    assert.equal(
      isAgentReleaseTokenAuthorized('secret', request({ authorization: 'Bearer secreT' })),
      false
    );
    assert.equal(
      isAgentReleaseTokenAuthorized('secret', request({ authorization: 'Bearer secret-longer' })),
      false
    );
    assert.equal(isAgentReleaseTokenAuthorized('secret', request({})), false);
  });

  await test('an unset configured token authorizes nothing', () => {
    assert.equal(isAgentReleaseTokenAuthorized('', request({ authorization: 'Bearer ' })), false);
    assert.equal(isAgentReleaseTokenAuthorized('', request({ authorization: 'Bearer x' })), false);
  });
});
