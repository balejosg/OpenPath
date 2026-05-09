export interface HarnessSession {
  email: string;
  accessToken: string;
  userId?: string;
}

export interface HarnessGroup {
  id: string;
  name: string;
  displayName: string;
}

export interface HarnessClassroom {
  id: string;
  name: string;
  displayName: string;
  defaultGroupId: string;
}

export interface HarnessSchedule {
  id: string;
  classroomId: string;
  groupId: string;
  startAt: string;
  endAt: string;
}

export interface HarnessMachine {
  id: string;
  classroomId: string;
  machineHostname: string;
  reportedHostname: string;
  machineToken: string;
  whitelistUrl: string;
}

export interface StudentFixtureHosts {
  portal: string;
  cdnPortal: string;
  site: string;
  apiSite: string;
}

export interface StudentScenario {
  scenarioName: string;
  apiUrl: string;
  auth: {
    admin: HarnessSession;
    teacher: HarnessSession;
  };
  groups: {
    restricted: HarnessGroup;
    alternate: HarnessGroup;
  };
  classroom: HarnessClassroom;
  schedules: {
    activeRestriction: HarnessSchedule;
    futureAlternate: HarnessSchedule;
  };
  machine: HarnessMachine;
  fixtures: StudentFixtureHosts;
}

export interface OpenAndExpectLoadedOptions {
  url: string;
  title?: string;
  selector?: string;
  timeoutMs?: number;
}

export interface OpenAndExpectBlockedOptions {
  url: string;
  forbiddenSelector?: string;
  forbiddenText?: string;
  timeoutMs?: number;
}

export interface BlockedScreenExpectation {
  reasonPrefix?: string;
  timeoutMs?: number;
}

export interface BlockedScreenRequestOptions {
  reason: string;
  timeoutMs?: number;
}

export interface ConvergenceOptions {
  timeoutMs?: number;
  pollMs?: number;
}

export interface StudentPolicyDriverOptions {
  diagnosticsDir?: string;
  extensionPath?: string;
  firefoxBinaryPath?: string;
  headless?: boolean;
}

export interface RunResult {
  success: boolean;
  diagnosticsDir: string;
}

export type PolicyMode = 'sse' | 'fallback';

export type StudentPolicyCoverageProfile = 'full' | 'fallback-propagation';

export type StudentPolicyScenarioGroup =
  | 'full'
  | 'request-lifecycle'
  | 'ajax-auto-allow'
  | 'path-blocking'
  | 'exemptions';

export interface RequestSubmissionResult {
  success: boolean;
  id?: string;
  status?: string;
  approved?: boolean;
  autoApproved?: boolean;
  duplicate?: boolean;
  error?: string;
}

export interface RequestStatusResult {
  id: string;
  domain: string;
  status: string;
}

export interface DomainRequestSummary extends RequestStatusResult {
  reason?: string;
}

export interface RuleResult {
  id: string;
  groupId?: string;
  type?: string;
  value?: string;
}

export interface ExemptionResult {
  id: string;
  machineId: string;
  classroomId: string;
  scheduleId: string;
  expiresAt: string;
}

export interface DomainStatusPayload {
  hostname: string;
  state: 'detected' | 'pending' | 'autoApproved' | 'duplicate' | 'localUpdateError' | 'apiError';
  updatedAt: number;
  message?: string;
}

export interface RuntimeResponse<T> {
  success?: boolean;
  error?: string;
  statuses?: Record<string, DomainStatusPayload>;
  domains?: Record<string, unknown>;
  available?: boolean;
  value?: T;
  version?: string;
  count?: number;
  rawRules?: string[];
  compiledPatterns?: string[];
}
