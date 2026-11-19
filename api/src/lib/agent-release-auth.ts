/**
 * Release-token check for the agent release routes. It is shared by the route
 * handlers and by the body-parser gate, so the large publish body is never
 * buffered or parsed for a caller that does not hold the token.
 */
import { timingSafeEqual } from 'node:crypto';

export interface ReleaseTokenRequest {
  get(name: string): string | undefined;
}

export function extractAgentReleaseToken(req: ReleaseTokenRequest): string | null {
  const authorization = req.get('authorization');
  const bearerPrefix = 'Bearer ';
  if (authorization?.startsWith(bearerPrefix)) {
    return authorization.slice(bearerPrefix.length).trim() || null;
  }
  const headerToken = req.get('x-openpath-release-token')?.trim();
  return headerToken ?? null;
}

/** Timing-safe comparison; an unset expected token authorizes nothing. */
export function isAgentReleaseTokenAuthorized(expected: string, req: ReleaseTokenRequest): boolean {
  const presented = extractAgentReleaseToken(req);
  if (!expected || !presented) {
    return false;
  }
  const expectedBuffer = Buffer.from(expected);
  const presentedBuffer = Buffer.from(presented);
  return (
    expectedBuffer.length === presentedBuffer.length &&
    timingSafeEqual(expectedBuffer, presentedBuffer)
  );
}
