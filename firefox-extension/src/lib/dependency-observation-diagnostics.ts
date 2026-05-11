export type OpenPathDependencyObservationSource =
  | 'openpathPageActivity'
  | 'webRequest.onBeforeRequest'
  | 'webRequest.onErrorOccurred'
  | 'webNavigation.onBeforeNavigate'
  | 'webNavigation.onErrorOccurred';

export interface OpenPathDependencyObservationNativeVerify {
  success?: boolean;
  results?: unknown[];
  error?: string;
}

export interface OpenPathDependencyObservationEventInput {
  source: OpenPathDependencyObservationSource;
  tabId?: number | undefined;
  frameId?: number | undefined;
  requestId?: string | undefined;
  type?: string | undefined;
  kind?: string | undefined;
  anchorHost?: string | undefined;
  dependencyHost?: string | undefined;
  hostname?: string | undefined;
}

export interface OpenPathDependencyObservationEvent extends OpenPathDependencyObservationEventInput {
  phase: string;
  timestamp: string;
  hostname?: string | undefined;
  nativeVerify?: OpenPathDependencyObservationNativeVerify;
}

export interface OpenPathDependencyObservationDiagnostics {
  enabled: boolean;
  phase: string;
  maxEvents: number;
  events: OpenPathDependencyObservationEvent[];
  configuredAt: string;
}

export interface OpenPathDependencyObservationDiagnosticsConfig {
  enabled: boolean;
  phase?: string;
  maxEvents?: number;
  verifyHost?: (hostname: string) => Promise<OpenPathDependencyObservationNativeVerify>;
}

const DEFAULT_PHASE = 'default';
const DEFAULT_MAX_EVENTS = 250;

let diagnosticsState: OpenPathDependencyObservationDiagnostics = {
  enabled: false,
  phase: DEFAULT_PHASE,
  maxEvents: DEFAULT_MAX_EVENTS,
  events: [],
  configuredAt: new Date(0).toISOString(),
};
let nativeVerifier:
  | ((hostname: string) => Promise<OpenPathDependencyObservationNativeVerify>)
  | undefined;

function normalizeText(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined;
}

function resolveHostname(input: OpenPathDependencyObservationEventInput): string | undefined {
  return (
    normalizeText(input.hostname)?.toLowerCase() ??
    normalizeText(input.dependencyHost)?.toLowerCase() ??
    normalizeText(input.anchorHost)?.toLowerCase()
  );
}

function cloneDiagnostics(): OpenPathDependencyObservationDiagnostics {
  return {
    enabled: diagnosticsState.enabled,
    phase: diagnosticsState.phase,
    maxEvents: diagnosticsState.maxEvents,
    configuredAt: diagnosticsState.configuredAt,
    events: diagnosticsState.events.map((event) => ({ ...event })),
  };
}

function appendEvent(event: OpenPathDependencyObservationEvent): void {
  diagnosticsState.events.push(event);
  if (diagnosticsState.events.length > diagnosticsState.maxEvents) {
    diagnosticsState.events.splice(0, diagnosticsState.events.length - diagnosticsState.maxEvents);
  }
}

export function configureOpenPathDependencyObservationDiagnostics(
  config: OpenPathDependencyObservationDiagnosticsConfig
): OpenPathDependencyObservationDiagnostics {
  diagnosticsState = {
    enabled: config.enabled,
    phase: normalizeText(config.phase) ?? DEFAULT_PHASE,
    maxEvents:
      typeof config.maxEvents === 'number' && Number.isFinite(config.maxEvents)
        ? Math.max(1, Math.trunc(config.maxEvents))
        : DEFAULT_MAX_EVENTS,
    events: diagnosticsState.events,
    configuredAt: new Date().toISOString(),
  };
  nativeVerifier = config.enabled ? config.verifyHost : undefined;

  return cloneDiagnostics();
}

export function clearOpenPathDependencyObservationDiagnostics(): OpenPathDependencyObservationDiagnostics {
  diagnosticsState = {
    ...diagnosticsState,
    events: [],
  };
  return cloneDiagnostics();
}

export function getOpenPathDependencyObservationDiagnostics(): OpenPathDependencyObservationDiagnostics {
  return cloneDiagnostics();
}

export function recordOpenPathDependencyObservationEvent(
  input: OpenPathDependencyObservationEventInput
): void {
  if (!diagnosticsState.enabled) {
    return;
  }

  const hostname = resolveHostname(input);
  const event: OpenPathDependencyObservationEvent = {
    ...input,
    ...(hostname ? { hostname } : {}),
    phase: diagnosticsState.phase,
    timestamp: new Date().toISOString(),
  };
  appendEvent(event);

  if (!hostname || !nativeVerifier) {
    return;
  }

  void nativeVerifier(hostname).then(
    (nativeVerify) => {
      event.nativeVerify = nativeVerify;
    },
    (error: unknown) => {
      event.nativeVerify = {
        success: false,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  );
}
