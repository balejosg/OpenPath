import {
  buildFixtureUrl,
  isRuleAlreadyPresent,
  normalizeUrl,
  parseJsonBody,
  parseJsonResponse,
  parseTrpcResponse,
} from './student-policy-env';
import type {
  DomainRequestSummary,
  ExemptionResult,
  RequestStatusResult,
  RequestSubmissionResult,
  RuleResult,
  StudentScenario,
} from './student-policy-types';

export function matchesRequestDomain(candidateDomain: string, requestedDomain: string): boolean {
  const candidate = candidateDomain.trim().toLowerCase().replace(/\.+$/, '');
  const requested = requestedDomain.trim().toLowerCase().replace(/\.+$/, '');

  return candidate === requested || requested.endsWith(`.${candidate}`);
}

export class StudentPolicyServerClient {
  private readonly scenario: StudentScenario;

  public constructor(scenario: StudentScenario) {
    this.scenario = scenario;
  }

  private get apiUrl(): string {
    return normalizeUrl(this.scenario.apiUrl);
  }

  private async trpcMutate<T>(procedure: string, input: unknown, accessToken: string): Promise<T> {
    const response = await fetch(`${this.apiUrl}/trpc/${procedure}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify(input),
    });

    return parseTrpcResponse<T>(response, procedure);
  }

  private async trpcQuery<T>(procedure: string, input: unknown, accessToken?: string): Promise<T> {
    const response = await fetch(
      `${this.apiUrl}/trpc/${procedure}?input=${encodeURIComponent(JSON.stringify(input))}`,
      {
        headers: accessToken === undefined ? {} : { Authorization: `Bearer ${accessToken}` },
      }
    );

    return parseTrpcResponse<T>(response, procedure);
  }

  private async postJson<T>(pathName: string, body: unknown, accessToken?: string): Promise<T> {
    const response = await fetch(`${this.apiUrl}${pathName}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(accessToken === undefined ? {} : { Authorization: `Bearer ${accessToken}` }),
      },
      body: JSON.stringify(body),
    });

    return parseJsonResponse<T>(response);
  }

  private async postJsonAllowingError<T>(
    pathName: string,
    body: unknown,
    accessToken?: string
  ): Promise<T> {
    const response = await fetch(`${this.apiUrl}${pathName}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(accessToken === undefined ? {} : { Authorization: `Bearer ${accessToken}` }),
      },
      body: JSON.stringify(body),
    });

    return parseJsonBody<T>(response);
  }

  public async submitManualRequest(
    domain: string,
    reason: string
  ): Promise<RequestSubmissionResult> {
    return this.postJsonAllowingError<RequestSubmissionResult>('/api/requests/submit', {
      domain,
      hostname: this.scenario.machine.reportedHostname,
      token: this.scenario.machine.machineToken,
      reason,
      origin_page: buildFixtureUrl(this.scenario.fixtures.portal, '/ok'),
    });
  }

  public async submitAutoRequest(
    domain: string,
    reason: string,
    options: { originPage?: string; targetUrl?: string } = {}
  ): Promise<RequestSubmissionResult> {
    return this.postJsonAllowingError<RequestSubmissionResult>('/api/requests/auto', {
      domain,
      hostname: this.scenario.machine.reportedHostname,
      token: this.scenario.machine.machineToken,
      reason,
      origin_page: options.originPage ?? buildFixtureUrl(this.scenario.fixtures.site, '/ok'),
      ...(options.targetUrl === undefined ? {} : { target_url: options.targetUrl }),
    });
  }

  public async getRequestStatus(requestId: string): Promise<RequestStatusResult> {
    return this.trpcQuery<RequestStatusResult>('requests.getStatus', { id: requestId });
  }

  public async findPendingRequestByDomain(domain: string): Promise<DomainRequestSummary> {
    const deadline = Date.now() + 10_000;
    let latestPendingRequests: DomainRequestSummary[] = [];

    while (Date.now() < deadline) {
      latestPendingRequests = await this.trpcQuery<DomainRequestSummary[]>(
        'requests.list',
        { status: 'pending' },
        this.scenario.auth.teacher.accessToken
      );
      const request =
        latestPendingRequests.find(
          (candidate) => candidate.domain === domain && candidate.status === 'pending'
        ) ??
        latestPendingRequests.find(
          (candidate) =>
            matchesRequestDomain(candidate.domain, domain) && candidate.status === 'pending'
        );

      if (request) {
        return request;
      }

      await new Promise((resolve) => setTimeout(resolve, 250));
    }

    const allRequests = await this.trpcQuery<DomainRequestSummary[]>(
      'requests.list',
      {},
      this.scenario.auth.teacher.accessToken
    );
    const matchingRequests = allRequests.filter((candidate) =>
      matchesRequestDomain(candidate.domain, domain)
    );
    const pendingDomains = latestPendingRequests.map((candidate) => candidate.domain).join(', ');
    const matchingStatuses = matchingRequests
      .map((candidate) => `${candidate.id}:${candidate.status}`)
      .join(', ');

    throw new Error(
      `No pending request found for domain ${domain}; matchingStatuses=${matchingStatuses || 'none'}; pendingDomains=${pendingDomains || 'none'}`
    );
  }

  public async approveRequest(requestId: string, groupId: string): Promise<void> {
    await this.trpcMutate(
      'requests.approve',
      { id: requestId, groupId },
      this.scenario.auth.teacher.accessToken
    );
  }

  public async rejectRequest(requestId: string, reason: string): Promise<void> {
    await this.trpcMutate(
      'requests.reject',
      { id: requestId, reason },
      this.scenario.auth.teacher.accessToken
    );
  }

  public async createGroupRule(
    groupId: string,
    type: string,
    value: string,
    comment: string
  ): Promise<RuleResult> {
    return this.trpcMutate<RuleResult>(
      'groups.createRule',
      { groupId, type, value, comment },
      this.scenario.auth.teacher.accessToken
    );
  }

  public async ensureWhitelistRule(groupId: string, value: string, comment: string): Promise<void> {
    try {
      await this.createGroupRule(groupId, 'whitelist', value, comment);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!isRuleAlreadyPresent(message)) {
        throw error;
      }
    }
  }

  public async deleteGroupRule(ruleId: string, groupId?: string): Promise<void> {
    await this.trpcMutate(
      'groups.deleteRule',
      { id: ruleId, ...(groupId === undefined ? {} : { groupId }) },
      this.scenario.auth.teacher.accessToken
    );
  }

  public async createTemporaryExemption(scheduleId: string): Promise<ExemptionResult> {
    return this.trpcMutate<ExemptionResult>(
      'classrooms.createExemption',
      {
        machineId: this.scenario.machine.id,
        classroomId: this.scenario.classroom.id,
        scheduleId,
      },
      this.scenario.auth.teacher.accessToken
    );
  }

  public async deleteTemporaryExemption(exemptionId: string): Promise<void> {
    await this.trpcMutate(
      'classrooms.deleteExemption',
      { id: exemptionId },
      this.scenario.auth.teacher.accessToken
    );
  }

  public async setActiveGroup(groupId: string | null): Promise<string | null> {
    const result = await this.trpcMutate<{ currentGroupId: string | null }>(
      'classrooms.setActiveGroup',
      { id: this.scenario.classroom.id, groupId },
      this.scenario.auth.teacher.accessToken
    );
    return result.currentGroupId;
  }

  public async setAutoApprove(enabled: boolean): Promise<void> {
    const result = await this.postJson<{ enabled?: boolean }>(
      '/api/test-support/auto-approve',
      { enabled },
      this.scenario.auth.teacher.accessToken
    );

    if (result.enabled !== enabled) {
      throw new Error(`Expected auto-approve=${String(enabled)}, got ${String(result.enabled)}`);
    }
  }

  public async tickBoundaries(at: string): Promise<void> {
    await this.postJson(
      '/api/test-support/tick-boundaries',
      { at },
      this.scenario.auth.teacher.accessToken
    );
  }

  public async setTestClock(at: string | null): Promise<void> {
    await this.postJson('/api/test-support/clock', { at }, this.scenario.auth.teacher.accessToken);
  }

  public async getMachineContext(): Promise<unknown> {
    const response = await fetch(
      `${this.apiUrl}/api/test-support/machine-context/${encodeURIComponent(this.scenario.machine.machineHostname)}`,
      {
        headers: {
          Authorization: `Bearer ${this.scenario.auth.teacher.accessToken}`,
        },
      }
    );

    return parseJsonResponse<unknown>(response);
  }

  public async fetchMachineWhitelist(): Promise<string> {
    const response = await fetch(this.scenario.machine.whitelistUrl);
    if (!response.ok) {
      throw new Error(`Whitelist fetch failed with status ${response.status}`);
    }
    return response.text();
  }
}
