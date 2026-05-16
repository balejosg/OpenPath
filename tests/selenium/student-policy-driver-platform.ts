import assert from 'node:assert';

import {
  buildWindowsBlockedDnsCommand,
  buildWindowsHttpProbeCommand,
  DEFAULT_POLL_MS,
  DEFAULT_TIMEOUT_MS,
  delay,
  escapeRegExp,
  getDisableSseCommand,
  getEnableSseCommand,
  getFixtureIpForHostname,
  isWindows,
  normalizeWhitelistContents,
  readWhitelistFile,
  runPlatformCommand,
  shellEscape,
  getUpdateCommand,
} from './student-policy-env';
import type { ConvergenceOptions } from './student-policy-types';

export async function assertDnsBlocked(hostname: string): Promise<void> {
  const command = isWindows()
    ? buildWindowsBlockedDnsCommand(hostname)
    : `sh -c "dig @127.0.0.1 ${hostname} +short +time=3 || true"`;

  const output = await runPlatformCommand(command);
  const normalized = output.trim();
  const fixtureIp = getFixtureIpForHostname(hostname);
  assert.ok(
    normalized === '' ||
      normalized === '0.0.0.0' ||
      normalized === '192.0.2.1' ||
      (fixtureIp !== null && normalized !== fixtureIp),
    `Expected DNS for ${hostname} to be blocked, received: ${normalized}`
  );
}

export async function assertDnsAllowed(hostname: string): Promise<void> {
  const command = isWindows()
    ? `powershell -NoLogo -Command "$result = Resolve-DnsName -Name '${hostname}' -Server 127.0.0.1 -DnsOnly -ErrorAction Stop; $result | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }"`
    : `sh -c "dig @127.0.0.1 ${hostname} +short +time=3 || true"`;

  const output = await runPlatformCommand(command);
  const normalized = output.trim();
  const fixtureIp = getFixtureIpForHostname(hostname);
  assert.ok(
    normalized !== '' &&
      normalized !== '0.0.0.0' &&
      normalized !== '192.0.2.1' &&
      (fixtureIp === null || normalized === fixtureIp),
    `Expected DNS for ${hostname} to be allowed, received: ${normalized}`
  );
}

export async function assertWhitelistContains(hostname: string): Promise<void> {
  const contents = normalizeWhitelistContents(await readWhitelistFile());
  assert.match(contents, new RegExp(`(^|\\n)${escapeRegExp(hostname)}($|\\n)`));
}

export async function assertWhitelistMissing(hostname: string): Promise<void> {
  const contents = normalizeWhitelistContents(await readWhitelistFile());
  assert.doesNotMatch(contents, new RegExp(`(^|\\n)${escapeRegExp(hostname)}($|\\n)`));
}

export async function forceLocalUpdate(): Promise<void> {
  await runPlatformCommand(getUpdateCommand());
}

export async function withSseDisabled<T>(callback: () => Promise<T>): Promise<T> {
  await runPlatformCommand(getDisableSseCommand());
  try {
    return await callback();
  } finally {
    await runPlatformCommand(getEnableSseCommand());
  }
}

export async function waitForConvergence(
  assertion: () => Promise<void>,
  options: ConvergenceOptions = {}
): Promise<void> {
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const pollMs = options.pollMs ?? DEFAULT_POLL_MS;
  const deadline = Date.now() + timeoutMs;
  let lastError: Error | null = null;

  while (Date.now() < deadline) {
    try {
      await assertion();
      return;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      await delay(pollMs);
    }
  }

  throw lastError ?? new Error('Timed out waiting for convergence');
}

export async function assertHttpReachable(url: string): Promise<void> {
  const command = isWindows()
    ? buildWindowsHttpProbeCommand(url, { useFixtureIp: true })
    : `curl -fsS --connect-timeout 3 --max-time 5 ${shellEscape(url)} >/dev/null`;

  await runPlatformCommand(command);
}

export async function assertHttpBlocked(url: string): Promise<void> {
  const command = isWindows()
    ? buildWindowsHttpProbeCommand(url)
    : `curl -fsS --connect-timeout 3 --max-time 5 ${shellEscape(url)} >/dev/null`;

  try {
    await runPlatformCommand(command);
  } catch {
    return;
  }

  throw new Error(`Expected HTTP access to be blocked for ${url}`);
}
