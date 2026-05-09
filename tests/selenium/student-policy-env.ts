import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { exec as execCallback } from 'node:child_process';
import { promisify } from 'node:util';
import type {
  PolicyMode,
  StudentPolicyCoverageProfile,
  StudentPolicyScenarioGroup,
  StudentScenario,
} from './student-policy-types';

const exec = promisify(execCallback);

export const FIREFOX_EXTENSION_ID = 'monitor-bloqueos@openpath';
export const DEFAULT_TIMEOUT_MS = 15_000;
export const DEFAULT_BLOCKED_TIMEOUT_MS = 8_000;
export const DEFAULT_POLL_MS = 250;
export const DEFAULT_DIAGNOSTICS_DIR = path.resolve(__dirname, '../../artifacts/student-policy');
export const DEFAULT_EXTENSION_PATH = path.resolve(
  __dirname,
  '../../firefox-extension/openpath-firefox-extension.xpi'
);

export function optionalEnv(name: string): string | undefined {
  const value = process.env[name];
  return value === undefined || value.trim() === '' ? undefined : value.trim();
}

export function normalizeUrl(url: string): string {
  return url.trim().replace(/\/+$/, '');
}

export function normalizeBoolean(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  return value === '1' || value.toLowerCase() === 'true';
}

export function shouldSkipBundledExtension(): boolean {
  return normalizeBoolean(optionalEnv('OPENPATH_SKIP_EXTENSION_BUNDLE'), false);
}

export function getDiagnosticsDir(rootDir = DEFAULT_DIAGNOSTICS_DIR): string {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(rootDir, timestamp);
}

export async function ensureDirectory(dirPath: string): Promise<void> {
  await fs.mkdir(dirPath, { recursive: true });
}

export async function loadScenarioFromEnv(): Promise<StudentScenario> {
  const inline = optionalEnv('OPENPATH_STUDENT_SCENARIO_JSON');
  if (inline !== undefined) {
    return JSON.parse(inline) as StudentScenario;
  }

  const filePath = optionalEnv('OPENPATH_STUDENT_SCENARIO_FILE');
  if (filePath !== undefined) {
    const fileContents = await fs.readFile(filePath, 'utf8');
    return JSON.parse(fileContents) as StudentScenario;
  }

  throw new Error(
    'Set OPENPATH_STUDENT_SCENARIO_JSON or OPENPATH_STUDENT_SCENARIO_FILE before running the Selenium suite'
  );
}

export function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function buildPopupUrl(extensionUuid: string): string {
  return `moz-extension://${extensionUuid}/popup/popup.html`;
}

export function buildWindowsBlockedDnsCommand(hostname: string): string {
  return `powershell -NoLogo -Command "try { $result = Resolve-DnsName -Name '${hostname}' -Server 127.0.0.1 -DnsOnly -ErrorAction Stop; if ($result) { $result | ForEach-Object { $_.IPAddress } } } catch { if (($_.Exception.Message -like '*DNS name does not exist*') -or ($_.FullyQualifiedErrorId -like '*DNS_ERROR_RCODE_NAME_ERROR*')) { exit 0 } throw }"`;
}

export function buildWindowsHttpProbeCommand(url: string): string {
  const escapedUrl = url.replace(/'/g, "''");
  const script = `Invoke-WebRequest -Uri '${escapedUrl}' -UseBasicParsing -ErrorAction Stop | Out-Null`;
  const encodedScript = Buffer.from(script, 'utf16le').toString('base64');
  return `powershell -NoLogo -EncodedCommand ${encodedScript}`;
}

export async function runPlatformCommand(command: string): Promise<string> {
  const { stdout, stderr } = await exec(command);
  return `${stdout}${stderr}`.trim();
}

export function isWindows(): boolean {
  return os.platform() === 'win32';
}

export function getWhitelistPath(): string {
  return (
    optionalEnv('OPENPATH_WHITELIST_PATH') ??
    (isWindows() ? 'C:\\OpenPath\\data\\whitelist.txt' : '/var/lib/openpath/whitelist.txt')
  );
}

export function getUpdateCommand(): string {
  return (
    optionalEnv('OPENPATH_FORCE_UPDATE_COMMAND') ??
    (isWindows()
      ? 'powershell -NoLogo -File "C:\\OpenPath\\scripts\\Update-OpenPath.ps1"'
      : 'sudo /usr/local/bin/openpath-update.sh --update')
  );
}

export function getDisableSseCommand(): string {
  return (
    optionalEnv('OPENPATH_DISABLE_SSE_COMMAND') ??
    (isWindows()
      ? 'powershell -NoLogo -Command "Stop-ScheduledTask -TaskName \\"OpenPath-SSE\\" -ErrorAction SilentlyContinue"'
      : 'sudo systemctl stop openpath-sse-listener.service')
  );
}

export function getEnableSseCommand(): string {
  return (
    optionalEnv('OPENPATH_ENABLE_SSE_COMMAND') ??
    (isWindows()
      ? 'powershell -NoLogo -Command "Start-ScheduledTask -TaskName \\"OpenPath-SSE\\" -ErrorAction SilentlyContinue"'
      : 'sudo systemctl start openpath-sse-listener.service')
  );
}

export function shellEscape(value: string): string {
  const escapedSingleQuote = String.raw`'"'"'`;
  return `'${value.replace(/'/g, escapedSingleQuote)}'`;
}

export async function readWhitelistFile(): Promise<string> {
  return fs.readFile(getWhitelistPath(), 'utf8');
}

export function normalizeWhitelistContents(contents: string): string {
  return contents.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
}

export function getFixturePort(): string {
  return optionalEnv('OPENPATH_FIXTURE_PORT') ?? '80';
}

export function getStudentHostSuffix(): string {
  return (optionalEnv('OPENPATH_STUDENT_HOST_SUFFIX') ?? '127.0.0.1.sslip.io')
    .trim()
    .replace(/^\.+|\.+$/g, '');
}

export function getFixtureIpForHostname(hostname: string): string | null {
  const suffix = getStudentHostSuffix();
  if (!hostname.endsWith(`.${suffix}`) && hostname !== suffix) {
    return null;
  }

  const match = /((?:\d{1,3}\.){3}\d{1,3})/.exec(suffix);
  return match?.[1] ?? null;
}

export function buildFixtureUrl(hostname: string, pathname: string): string {
  return `http://${hostname}:${getFixturePort()}${pathname}`;
}

export function buildHost(label: string): string {
  return `${label}.${getStudentHostSuffix()}`;
}

export function buildScenarioHost(scenario: StudentScenario, label: string): string {
  const suffix = getStudentHostSuffix();
  const token =
    scenario.classroom.id
      .replace(/[^a-z0-9]/gi, '')
      .toLowerCase()
      .slice(-8) || 'scenario';
  return `${label}-${token}.${suffix}`;
}

export function getPolicyMode(): PolicyMode {
  const mode = optionalEnv('OPENPATH_STUDENT_MODE');
  return mode === 'fallback' ? 'fallback' : 'sse';
}

export function getStudentPolicyCoverageProfile(): StudentPolicyCoverageProfile {
  const profile = optionalEnv('OPENPATH_STUDENT_COVERAGE_PROFILE');
  if (profile === undefined) {
    return 'full';
  }

  if (profile === 'full' || profile === 'fallback-propagation') {
    return profile;
  }

  throw new Error(
    `OPENPATH_STUDENT_COVERAGE_PROFILE must be "full" or "fallback-propagation", received "${profile}"`
  );
}

export function getStudentPolicyScenarioGroup(): StudentPolicyScenarioGroup {
  const group = optionalEnv('OPENPATH_STUDENT_SCENARIO_GROUP');
  if (group === undefined) {
    return 'full';
  }

  if (
    group === 'full' ||
    group === 'request-lifecycle' ||
    group === 'ajax-auto-allow' ||
    group === 'path-blocking' ||
    group === 'exemptions'
  ) {
    return group;
  }

  throw new Error(
    `OPENPATH_STUDENT_SCENARIO_GROUP must be "full", "request-lifecycle", "ajax-auto-allow", "path-blocking", or "exemptions", received "${group}"`
  );
}

export function isRuleAlreadyPresent(errorMessage: string): boolean {
  return /already exists|duplicate/i.test(errorMessage);
}

export async function parseJsonResponse<T>(response: Response): Promise<T> {
  if (!response.ok) {
    throw new Error(`Request failed with status ${response.status}: ${await response.text()}`);
  }
  return (await response.json()) as T;
}

export async function parseJsonBody<T>(response: Response): Promise<T> {
  return (await response.json()) as T;
}

export async function parseTrpcResponse<T>(response: Response, procedure: string): Promise<T> {
  const payload = (await response.json()) as {
    result?: { data?: T };
    error?: { message?: string; data?: { code?: string } };
  };

  if (response.ok && payload.result?.data !== undefined) {
    return payload.result.data;
  }

  throw new Error(
    `tRPC call ${procedure} failed: ${payload.error?.message ?? `HTTP ${String(response.status)}`}`
  );
}

export async function delay(ms: number): Promise<void> {
  await new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
