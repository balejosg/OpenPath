import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import {
  isWindows,
  readWhitelistFile,
  runPlatformCommand,
  shellEscape,
} from './student-policy-env';

export const LINUX_AUTO_ALLOW_BOUNDARY_ARTIFACT = 'linux-auto-allow-boundary.json';
export const LINUX_RUNTIME_DEPENDENCY_APPLY_ARTIFACT = 'linux-runtime-dependency-apply.json';

export const LINUX_AUTO_ALLOW_DIAGNOSTIC_PHASES = [
  'firefox-extension-ready',
  'origin-page-load',
  'page-observer',
  'page-resource-candidates',
  'no-automatic-rule-creation',
  'explicit-whitelist-apply',
  'explicit-probe-traffic',
  'artifact-written',
] as const;

export type LinuxAutoAllowPhaseId = (typeof LINUX_AUTO_ALLOW_DIAGNOSTIC_PHASES)[number];
export type LinuxAutoAllowPhaseStatus = 'pending' | 'passed' | 'failed' | 'skipped';

export interface LinuxAutoAllowDiagnosticPhase {
  id: LinuxAutoAllowPhaseId;
  status: LinuxAutoAllowPhaseStatus;
  message?: string;
  evidence?: Record<string, unknown>;
}

export interface LinuxAutoAllowProbe {
  id: 'fetch' | 'xhr' | 'image' | 'script' | 'stylesheet' | 'font';
  host: string;
  url: string;
  observerState?: {
    lastError?: string | null;
    lastNotification?: { kind?: string; url?: string } | null;
    notifications?: Record<string, number>;
    patched?: Record<string, boolean>;
  };
  firstResult?: 'ok' | 'blocked';
  explicitResult?: 'ok' | 'blocked';
}

export interface LinuxAutoAllowBoundary {
  id: LinuxAutoAllowPhaseId | 'success' | 'unknown';
  message: string;
  recommendedNextAction: string;
}

export interface LinuxAutoAllowDiagnostics {
  remoteWhitelist?: string;
  localWhitelist?: string;
  dnsmasqStatus?: string;
  openpathSseListenerStatus?: string;
  openpathUpdateStatus?: string;
  openpathLogTail?: string;
  resolvConf?: string;
  nativeHostManifest?: string;
  rootNativeHostManifest?: string;
  dnsProbes?: Record<string, string>;
  collectionErrors?: string[];
}

export interface LinuxAutoAllowArtifact {
  platform: 'linux';
  success: boolean;
  failureBoundary: LinuxAutoAllowBoundary;
  diagnosticPhases: LinuxAutoAllowDiagnosticPhase[];
  probes: LinuxAutoAllowProbe[];
  diagnostics: LinuxAutoAllowDiagnostics;
  writtenAt: string;
}

export interface LinuxRuntimeDependencyApplyArtifact {
  platform: 'linux';
  outcome: 'runtime-dependency-applied';
  success: boolean;
  originHost: string;
  dependencyHosts: string[];
  remoteWhitelistMutated: false;
  writtenAt: string;
}

const NEXT_ACTION_BY_PHASE: Record<LinuxAutoAllowPhaseId | 'unknown' | 'success', string> = {
  'firefox-extension-ready':
    'Inspect Firefox extension install, native-host manifest, and Selenium browser readiness before changing auto-allow logic.',
  'origin-page-load':
    'Inspect fixture DNS/page load evidence before changing extension or native-host behavior.',
  'page-observer':
    'Inspect extension content-script injection and the page observer registration path.',
  'page-resource-candidates':
    'Inspect extension page-resource detection, candidate matching, and browser console evidence.',
  'no-automatic-rule-creation':
    'Inspect Firefox page-resource observation and ensure no automatic rule publication path was reintroduced.',
  'explicit-whitelist-apply':
    'Inspect explicit group rules, /var/lib/openpath/whitelist.txt, and openpath-update.service before changing browser behavior.',
  'explicit-probe-traffic':
    'Inspect Firefox probe traffic, dnsmasq state, and explicit native-host policy visibility before changing policy publication.',
  'artifact-written':
    'Inspect artifact directory permissions and runner artifact upload configuration.',
  unknown: 'Inspect the collected diagnostics to identify the first missing evidence boundary.',
  success:
    'No diagnostic boundary remained after Linux page-resource observation and explicit allowlist convergence.',
};

export function classifyLinuxAutoAllowBoundary(
  phases: LinuxAutoAllowDiagnosticPhase[]
): LinuxAutoAllowBoundary {
  const failedPhase = phases.find((phase) => phase.status === 'failed');

  if (!failedPhase) {
    return {
      id: 'success',
      message:
        'Linux AJAX/subresource observation completed without automatic rule creation and explicit allowlist probes succeeded.',
      recommendedNextAction: NEXT_ACTION_BY_PHASE.success,
    };
  }

  return {
    id: failedPhase.id,
    message: failedPhase.message ?? `${failedPhase.id} failed`,
    recommendedNextAction: NEXT_ACTION_BY_PHASE[failedPhase.id] ?? NEXT_ACTION_BY_PHASE.unknown,
  };
}

export function buildLinuxAutoAllowArtifact(options: {
  success: boolean;
  diagnosticPhases: LinuxAutoAllowDiagnosticPhase[];
  probes: LinuxAutoAllowProbe[];
  diagnostics: LinuxAutoAllowDiagnostics;
  writtenAt?: string;
}): LinuxAutoAllowArtifact {
  return {
    platform: 'linux',
    success: options.success,
    failureBoundary: classifyLinuxAutoAllowBoundary(options.diagnosticPhases),
    diagnosticPhases: options.diagnosticPhases,
    probes: options.probes,
    diagnostics: options.diagnostics,
    writtenAt: options.writtenAt ?? new Date().toISOString(),
  };
}

export function upsertLinuxAutoAllowPhase(
  phases: LinuxAutoAllowDiagnosticPhase[],
  phase: LinuxAutoAllowDiagnosticPhase
): LinuxAutoAllowDiagnosticPhase[] {
  const nextPhases = phases.filter((candidate) => candidate.id !== phase.id);
  nextPhases.push(phase);
  return LINUX_AUTO_ALLOW_DIAGNOSTIC_PHASES.flatMap((phaseId) =>
    nextPhases.filter((candidate) => candidate.id === phaseId)
  );
}

async function captureCommand(command: string): Promise<string> {
  try {
    return await runPlatformCommand(command);
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

async function readOptionalFile(filePath: string): Promise<string> {
  try {
    return await readFile(filePath, 'utf8');
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

export async function collectLinuxAutoAllowDiagnostics(options: {
  fetchRemoteWhitelist: () => Promise<string>;
  probeHosts: string[];
}): Promise<LinuxAutoAllowDiagnostics> {
  const diagnostics: LinuxAutoAllowDiagnostics = {};
  const collectionErrors: string[] = [];

  try {
    diagnostics.remoteWhitelist = await options.fetchRemoteWhitelist();
  } catch (error) {
    collectionErrors.push(
      `remoteWhitelist: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  try {
    diagnostics.localWhitelist = await readWhitelistFile();
  } catch (error) {
    collectionErrors.push(
      `localWhitelist: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  diagnostics.dnsmasqStatus = await captureCommand('systemctl status dnsmasq --no-pager || true');
  diagnostics.openpathSseListenerStatus = await captureCommand(
    'systemctl status openpath-sse-listener.service --no-pager || true'
  );
  diagnostics.openpathUpdateStatus = await captureCommand(
    'systemctl status openpath-update.service --no-pager || true'
  );
  diagnostics.openpathLogTail = await captureCommand(
    'tail -n 200 /var/log/openpath.log 2>/dev/null || true'
  );
  diagnostics.resolvConf = await readOptionalFile('/etc/resolv.conf');
  diagnostics.nativeHostManifest = await readOptionalFile(
    '/usr/lib/mozilla/native-messaging-hosts/whitelist_native_host.json'
  );
  diagnostics.rootNativeHostManifest = await readOptionalFile(
    '/root/.mozilla/native-messaging-hosts/whitelist_native_host.json'
  );

  diagnostics.dnsProbes = {};
  for (const host of options.probeHosts) {
    diagnostics.dnsProbes[host] = await captureCommand(
      `dig @127.0.0.1 ${shellEscape(host)} +short +time=3 +tries=1 2>&1 || true`
    );
  }

  if (collectionErrors.length > 0) {
    diagnostics.collectionErrors = collectionErrors;
  }

  return diagnostics;
}

export async function writeLinuxAutoAllowBoundaryArtifact(options: {
  diagnosticsDir: string;
  success: boolean;
  phases: LinuxAutoAllowDiagnosticPhase[];
  probes: LinuxAutoAllowProbe[];
  fetchRemoteWhitelist: () => Promise<string>;
}): Promise<LinuxAutoAllowArtifact | null> {
  if (isWindows()) {
    return null;
  }

  const artifactPath = join(options.diagnosticsDir, LINUX_AUTO_ALLOW_BOUNDARY_ARTIFACT);
  const diagnostics = await collectLinuxAutoAllowDiagnostics({
    fetchRemoteWhitelist: options.fetchRemoteWhitelist,
    probeHosts: options.probes.map((probe) => probe.host),
  });
  const artifact = buildLinuxAutoAllowArtifact({
    success: options.success,
    diagnosticPhases: upsertLinuxAutoAllowPhase(options.phases, {
      id: 'artifact-written',
      status: 'passed',
      evidence: { artifactPath },
    }),
    probes: options.probes,
    diagnostics,
  });

  await mkdir(options.diagnosticsDir, { recursive: true });
  await writeFile(artifactPath, `${JSON.stringify(artifact, null, 2)}\n`, 'utf8');
  return artifact;
}

export async function writeLinuxRuntimeDependencyApplyArtifact(options: {
  diagnosticsDir: string;
  success: boolean;
  originHost: string;
  dependencyHosts: string[];
}): Promise<LinuxRuntimeDependencyApplyArtifact | null> {
  if (isWindows()) {
    return null;
  }

  const artifact: LinuxRuntimeDependencyApplyArtifact = {
    platform: 'linux',
    outcome: 'runtime-dependency-applied',
    success: options.success,
    originHost: options.originHost,
    dependencyHosts: options.dependencyHosts,
    remoteWhitelistMutated: false,
    writtenAt: new Date().toISOString(),
  };
  await mkdir(options.diagnosticsDir, { recursive: true });
  await writeFile(
    join(options.diagnosticsDir, LINUX_RUNTIME_DEPENDENCY_APPLY_ARTIFACT),
    `${JSON.stringify(artifact, null, 2)}\n`,
    'utf8'
  );
  return artifact;
}
