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
