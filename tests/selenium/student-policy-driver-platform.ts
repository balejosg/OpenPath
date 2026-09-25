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
  runPlatformCommandResult,
  shellEscape,
  getUpdateCommand,
  type PlatformCommandResult,
} from './student-policy-env';
import type { ConvergenceOptions } from './student-policy-types';

export const FORCE_LOCAL_UPDATE_RETRY_ATTEMPTS = 3;
export const FORCE_LOCAL_UPDATE_RETRY_DELAY_MS = 5_000;

function formatForceLocalUpdateError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}

export function shouldRetryForceLocalUpdateError(error: unknown, command: string): boolean {
  const message = formatForceLocalUpdateError(error);

  if (
    /Another OpenPath update is already running|existing OpenPath update to finish|OpenPath update lock/i.test(
      message
    )
  ) {
    return true;
  }

  return (
    /Update-OpenPath\.ps1|openpath-update\.sh/.test(command) && /^Command failed:/i.test(message)
  );
}

export function isCompletedWindowsUpdateFailure(error: unknown): boolean {
  return isCompletedWindowsUpdateOutput(formatForceLocalUpdateError(error));
}

export function isCompletedWindowsUpdateOutput(output: string): boolean {
  return /=== OpenPath update completed(?: successfully| \(no changes\)) ===/.test(output);
}

export function isSkippedWindowsUpdateOutput(output: string): boolean {
  return /Another OpenPath update is already running - skipping (?:this cycle|runtime dependency fast apply)/i.test(
    output
  );
}

function createForceLocalUpdateResultError(command: string, result: PlatformCommandResult): Error {
  const prefix = result.failed ? 'Command failed' : 'Command did not apply update';
  return new Error(`${prefix}: ${command}${result.output === '' ? '' : `\n${result.output}`}`);
}

export function shouldRetryForceLocalUpdateResult(
  result: PlatformCommandResult,
  command: string
): boolean {
  if (isSkippedWindowsUpdateOutput(result.output)) {
    return true;
  }

  if (result.failed) {
    return shouldRetryForceLocalUpdateError(
      createForceLocalUpdateResultError(command, result),
      command
    );
  }

  return false;
}

const TRANSIENT_DNS_RETRIES = 6;
const TRANSIENT_DNS_RETRY_DELAY_MS = 2_000;
const TRANSIENT_DNS_RETRY_MAX_DELAY_MS = 15_000;

function sleepMilliseconds(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function parseDnsAddresses(output: string): string[] {
  return output
    .split(/[\s,]+/)
    .map((value) => value.trim())
    .filter((value) => value.length > 0);
}

function isBlockedDnsAddress(address: string): boolean {
  return address === '' || address === '0.0.0.0' || address === '::' || address === '192.0.2.1';
}

function isTransientDnsCommandError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /forcibly closed|connection (refused|reset)|timed out|10054|WSAECONNRESET/i.test(message);
}

// The product's own update cycle restarts the local DNS service in bursts, so a
// single Resolve-DnsName call can land on the restart gap. Retry transient
// connection failures and non-answers with exponential backoff before failing.
async function assertDnsWithRetry(
  hostname: string,
  command: string,
  isExpected: (output: string) => boolean,
  expectation: string
): Promise<void> {
  let lastOutput = '';
  for (let attempt = 0; ; attempt += 1) {
    try {
      const output = (await runPlatformCommand(command)).trim();
      if (isExpected(output)) {
        return;
      }
      lastOutput = output;
    } catch (error) {
      if (attempt >= TRANSIENT_DNS_RETRIES || !isTransientDnsCommandError(error)) {
        throw error;
      }
      lastOutput = `error: ${error instanceof Error ? error.message : String(error)}`;
    }
    if (attempt >= TRANSIENT_DNS_RETRIES) {
      break;
    }
    await sleepMilliseconds(
      Math.min(TRANSIENT_DNS_RETRY_DELAY_MS * 2 ** attempt, TRANSIENT_DNS_RETRY_MAX_DELAY_MS)
    );
  }
  assert.ok(false, `Expected DNS for ${hostname} to be ${expectation}, received: ${lastOutput}`);
}

export async function assertDnsBlocked(hostname: string): Promise<void> {
  const command = isWindows()
    ? buildWindowsBlockedDnsCommand(hostname)
    : `sh -c "dig @127.0.0.1 ${hostname} +short +time=3 || true"`;

  const fixtureIp = getFixtureIpForHostname(hostname);
  await assertDnsWithRetry(
    hostname,
    command,
    (normalized) => {
      const addresses = parseDnsAddresses(normalized);
      if (addresses.length === 0) {
        return true;
      }
      // Acrylic can return a bogus secondary answer (e.g. "::") alongside the
      // blocked primary, so a host is only considered allowed when the fixture
      // address is actually present.
      return addresses.every(
        (address) => isBlockedDnsAddress(address) || (fixtureIp !== null && address !== fixtureIp)
      );
    },
    'blocked'
  );
}

export async function assertDnsAllowed(hostname: string): Promise<void> {
  const command = isWindows()
    ? `powershell -NoLogo -Command "$result = Resolve-DnsName -Name '${hostname}' -Server 127.0.0.1 -DnsOnly -ErrorAction Stop; $result | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }"`
    : `sh -c "dig @127.0.0.1 ${hostname} +short +time=3 || true"`;

  const fixtureIp = getFixtureIpForHostname(hostname);
  await assertDnsWithRetry(
    hostname,
    command,
    (normalized) => {
      const addresses = parseDnsAddresses(normalized);
      if (fixtureIp !== null) {
        return addresses.includes(fixtureIp);
      }
      return addresses.some((address) => !isBlockedDnsAddress(address));
    },
    'allowed'
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
  const command = getUpdateCommand();
  let lastError: unknown = null;

  for (let attempt = 1; attempt <= FORCE_LOCAL_UPDATE_RETRY_ATTEMPTS; attempt += 1) {
    const result = await runPlatformCommandResult(command);

    if (isWindows() && result.failed && isCompletedWindowsUpdateOutput(result.output)) {
      return;
    }

    if (!result.failed && !(isWindows() && isSkippedWindowsUpdateOutput(result.output))) {
      return;
    }

    const error = createForceLocalUpdateResultError(command, result);
    lastError = error;

    if (
      attempt === FORCE_LOCAL_UPDATE_RETRY_ATTEMPTS ||
      !shouldRetryForceLocalUpdateResult(result, command)
    ) {
      throw error;
    }

    console.warn(
      `Forced OpenPath update failed during attempt ${attempt}; retrying after ${FORCE_LOCAL_UPDATE_RETRY_DELAY_MS}ms`
    );
    await delay(FORCE_LOCAL_UPDATE_RETRY_DELAY_MS);
  }

  throw lastError ?? new Error('Forced OpenPath update failed');
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
