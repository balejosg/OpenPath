import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { DbExecutor } from '../src/db/index.js';
import type { Rule } from '../src/lib/groups-storage.js';
import type { AuthenticatedMachine } from '../src/lib/server-request-auth.js';
import DomainEventsService from '../src/services/domain-events.service.js';
import type { MachineRequestAdmissionDeps } from '../src/services/machine-request-admission.service.js';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test-jwt-secret';

type AccessResult =
  | { ok: true; machine: AuthenticatedMachine; requestedHostname: string }
  | {
      ok: false;
      error: 'invalid-token' | 'hostname-mismatch';
      requestedHostname: string;
      machine?: AuthenticatedMachine;
    };

const testMachine: AuthenticatedMachine = {
  classroomId: 'classroom-1',
  createdAt: null,
  downloadTokenHash: 'hash',
  downloadTokenLastRotatedAt: null,
  hostname: 'lab-host-01',
  id: 'machine-1',
  lastSeen: null,
  reportedHostname: null,
  updatedAt: null,
  version: 'test',
};

interface TestDepsResult {
  createdRequests: MachineRequestAdmissionDeps['createRequest'][] extends never[]
    ? never[]
    : Record<string, unknown>[];
  createdRules: Record<string, unknown>[];
  deps: Partial<MachineRequestAdmissionDeps>;
  events: string[];
}

function createDeps(overrides: Partial<MachineRequestAdmissionDeps> = {}): TestDepsResult {
  const events: string[] = [];
  const createdRequests: Record<string, unknown>[] = [];
  const createdRules: Record<string, unknown>[] = [];
  const deps: Partial<MachineRequestAdmissionDeps> = {
    autoApproveMachineRequests: false,
    createRequest: (input) => {
      createdRequests.push(input as unknown as Record<string, unknown>);
      return Promise.resolve({ ok: true, data: { id: 'request-1', status: 'pending' } });
    },
    createRule: (groupId, type, value, comment, source, tx) => {
      createdRules.push({ groupId, type, value, comment, source, tx });
      return Promise.resolve({ success: true, id: 'rule-1' });
    },
    getRulesByGroup: () => Promise.resolve([]),
    isDomainBlocked: () => Promise.resolve({ blocked: false, matchedRule: null }),
    logger: { warn: (): void => undefined },
    publishWhitelistChanged: (groupId) => {
      events.push(groupId);
    },
    resolveEffectiveMachinePolicyContext: () =>
      Promise.resolve({
        classroomId: 'classroom-1',
        classroomName: 'Classroom 1',
        groupId: 'group-1',
        mode: 'grouped',
        reason: 'manual',
      }),
    resolveMachineTokenHostnameAccess: (): Promise<AccessResult> =>
      Promise.resolve({
        ok: true,
        machine: testMachine,
        requestedHostname: 'lab-host-01',
      }) as ReturnType<MachineRequestAdmissionDeps['resolveMachineTokenHostnameAccess']>,
    createTransactionalWriter: DomainEventsService.createTransactionalWriter,
    withTransaction: (operation) => operation('tx-1' as unknown as DbExecutor),
    ...overrides,
  };

  return { deps, events, createdRequests, createdRules };
}

await describe('machine request admission service', async () => {
  const { createSubmittedMachineRequest, decideAutoMachineRequest } =
    await import('../src/services/machine-request-admission.service.js');

  await test('blank token returns forbidden before policy lookup', async () => {
    let policyLookups = 0;
    const { deps } = createDeps({
      resolveEffectiveMachinePolicyContext: () => {
        policyLookups += 1;
        return Promise.resolve(null);
      },
      resolveMachineTokenHostnameAccess: () =>
        Promise.resolve({
          ok: false,
          error: 'invalid-token',
          requestedHostname: 'lab-host-01',
        } as AccessResult) as ReturnType<
          MachineRequestAdmissionDeps['resolveMachineTokenHostnameAccess']
        >,
    });

    const result = await decideAutoMachineRequest(
      { domainRaw: 'example.com', hostnameRaw: 'lab-host-01', token: '   ' },
      deps
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Invalid machine token' },
    });
    assert.equal(policyLookups, 0);
  });

  await test('unrestricted classroom rejects manual submissions', async () => {
    const { deps } = createDeps({
      resolveEffectiveMachinePolicyContext: () =>
        Promise.resolve({
          classroomId: 'classroom-1',
          classroomName: 'Classroom 1',
          groupId: null,
          mode: 'unrestricted',
          reason: 'manual',
        }),
    });

    const result = await createSubmittedMachineRequest(
      { domainRaw: 'example.com', hostnameRaw: 'lab-host-01', token: 'token' },
      deps
    );

    assert.deepEqual(result, {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: 'Machine classroom is unrestricted and does not require access requests',
      },
    });
  });

  await test('manual submissions normalize subdomains to the root request domain', async () => {
    const { deps, createdRequests } = createDeps();

    const result = await createSubmittedMachineRequest(
      { domainRaw: 'Video.CDN.Example.COM', hostnameRaw: 'lab-host-01', token: 'token' },
      deps
    );

    assert.ok(result.ok);
    assert.equal(result.data.domain, 'example.com');
    assert.equal(createdRequests.length, 1);
    const createdRequest = createdRequests[0];
    assert.ok(createdRequest);
    assert.equal(createdRequest.domain, 'example.com');
    assert.equal(createdRequest.source, 'firefox-extension');
  });

  await test('hostname mismatch rejects before policy lookup', async () => {
    let policyLookups = 0;
    const { deps } = createDeps({
      resolveEffectiveMachinePolicyContext: () => {
        policyLookups += 1;
        return Promise.resolve(null);
      },
      resolveMachineTokenHostnameAccess: () =>
        Promise.resolve({
          ok: false,
          error: 'hostname-mismatch',
          requestedHostname: 'lab-host-02',
          machine: testMachine,
        } as AccessResult) as ReturnType<
          MachineRequestAdmissionDeps['resolveMachineTokenHostnameAccess']
        >,
    });

    const result = await decideAutoMachineRequest(
      { domainRaw: 'example.com', hostnameRaw: 'lab-host-02', token: 'token' },
      deps
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Token is not valid for this hostname' },
    });
    assert.equal(policyLookups, 0);
  });

  await test('missing active policy context returns not found', async () => {
    const { deps } = createDeps({
      resolveEffectiveMachinePolicyContext: () => Promise.resolve(null),
    });

    const result = await decideAutoMachineRequest(
      { domainRaw: 'example.com', hostnameRaw: 'lab-host-01', token: 'token' },
      deps
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'No active group found for machine hostname' },
    });
  });

  await test('missing group rejects like unrestricted classrooms', async () => {
    const { deps } = createDeps({
      resolveEffectiveMachinePolicyContext: () =>
        Promise.resolve({
          classroomId: 'classroom-1',
          classroomName: 'Classroom 1',
          groupId: null,
          mode: 'grouped',
          reason: 'manual',
        }),
    });

    const result = await decideAutoMachineRequest(
      { domainRaw: 'example.com', hostnameRaw: 'lab-host-01', token: 'token' },
      deps
    );

    assert.deepEqual(result, {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: 'Machine classroom is unrestricted and does not require access requests',
      },
    });
  });

  await test('invalid domains fail after machine token proof succeeds', async () => {
    let tokenProofs = 0;
    let policyLookups = 0;
    const { deps } = createDeps({
      resolveEffectiveMachinePolicyContext: () => {
        policyLookups += 1;
        return Promise.resolve(null);
      },
      resolveMachineTokenHostnameAccess: () => {
        tokenProofs += 1;
        return Promise.resolve({
          ok: true,
          machine: testMachine,
          requestedHostname: 'lab-host-01',
        } as AccessResult) as ReturnType<
          MachineRequestAdmissionDeps['resolveMachineTokenHostnameAccess']
        >;
      },
    });

    const result = await decideAutoMachineRequest(
      { domainRaw: 'http://', hostnameRaw: 'lab-host-01', token: 'token' },
      deps
    );

    assert.equal(tokenProofs, 1);
    assert.equal(policyLookups, 0);
    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'BAD_REQUEST');
  });

  await test('blocked subdomain rejects auto approval', async () => {
    const { deps } = createDeps({
      isDomainBlocked: () => Promise.resolve({ blocked: true, matchedRule: 'videos.example.com' }),
    });

    const result = await decideAutoMachineRequest(
      { domainRaw: 'videos.example.com', hostnameRaw: 'lab-host-01', token: 'token' },
      deps
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Target matches a blocked subdomain rule' },
    });
  });

  await test('blocked path rejects auto approval', async () => {
    const { deps } = createDeps({
      getRulesByGroup: (_groupId, type) =>
        Promise.resolve(
          type === 'blocked_path'
            ? [
                {
                  id: 'blocked-path-1',
                  groupId: 'group-1',
                  type: 'blocked_path',
                  value: 'example.com/private/*',
                  source: 'manual',
                  comment: null,
                  createdAt: new Date().toISOString(),
                },
              ]
            : []
        ) as Promise<Rule[]>,
    });

    const result = await decideAutoMachineRequest(
      {
        domainRaw: 'cdn.example.com',
        hostnameRaw: 'lab-host-01',
        targetUrl: 'https://example.com/private/file.js',
        token: 'token',
      },
      deps
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Target URL matches a blocked path rule' },
    });
  });

  await test('non-whitelisted origin creates pending request when global auto approval is disabled', async () => {
    const { deps, createdRequests } = createDeps();

    const result = await decideAutoMachineRequest(
      {
        domainRaw: 'cdn.example.com',
        hostnameRaw: 'lab-host-01',
        originPage: 'https://untrusted.example.net/page',
        reason: 'ajax',
        token: 'token',
      },
      deps
    );

    assert.ok(result.ok);
    assert.deepEqual(result.data, {
      autoApproved: false,
      domain: 'cdn.example.com',
      groupId: 'group-1',
      requestId: 'request-1',
      requestStatus: 'pending',
      source: 'auto_extension',
    });
    assert.equal(createdRequests.length, 1);
    assert.equal(createdRequests[0]?.source, 'auto_extension');
  });

  await test('malformed origin creates pending request instead of auto approval', async () => {
    const { deps, createdRequests, createdRules } = createDeps({
      getRulesByGroup: (_groupId, type) =>
        Promise.resolve(
          type === 'whitelist'
            ? [
                {
                  id: 'rule-origin',
                  groupId: 'group-1',
                  type: 'whitelist',
                  value: '*.school.example',
                  source: 'manual',
                  comment: null,
                  createdAt: new Date().toISOString(),
                },
              ]
            : []
        ) as Promise<Rule[]>,
    });

    const result = await decideAutoMachineRequest(
      {
        domainRaw: 'cdn.example.com',
        hostnameRaw: 'lab-host-01',
        originPage: 'not a host',
        token: 'token',
      },
      deps
    );

    assert.ok(result.ok);
    assert.equal(result.data.autoApproved, false);
    assert.equal(createdRequests.length, 1);
    assert.equal(createdRules.length, 0);
  });

  await test('auto request preserves exact subresource domain when global auto approval is enabled', async () => {
    const { deps, createdRules } = createDeps({
      autoApproveMachineRequests: true,
    });

    const result = await decideAutoMachineRequest(
      {
        domainRaw: 'Video.CDN.Example.COM',
        hostnameRaw: 'lab-host-01',
        originPage: 'https://school.example/dashboard',
        token: 'token',
      },
      deps
    );

    assert.ok(result.ok);
    assert.equal(result.data.autoApproved, true);
    assert.equal(result.data.domain, 'video.cdn.example.com');
    assert.equal(createdRules[0]?.value, 'video.cdn.example.com');
  });

  await test('whitelisted origin auto approves and publishes whitelist event when global auto approval is enabled', async () => {
    const { deps, events, createdRules } = createDeps({
      autoApproveMachineRequests: true,
    });

    const result = await decideAutoMachineRequest(
      {
        diagnosticContext: 'xmlhttprequest',
        domainRaw: 'cdn.example.com',
        hostnameRaw: 'lab-host-01',
        originPage: 'https://teacher.school.example/dashboard',
        reason: 'ajax',
        token: 'token',
      },
      deps
    );

    assert.ok(result.ok);
    assert.deepEqual(result.data, {
      autoApproved: true,
      domain: 'cdn.example.com',
      duplicate: false,
      groupId: 'group-1',
      source: 'auto_extension',
      status: 'approved',
    });
    assert.deepEqual(events, ['group-1']);
    assert.ok(createdRules[0]);
    assert.equal(createdRules[0].source, 'auto_extension');
    assert.match(String(createdRules[0].comment), /diagnostic \(xmlhttprequest\)/);
  });

  // Regression tests for CVE: attacker-controlled originPage must not bypass
  // manual-approval gate when autoApproveMachineRequests=false.
  await test('[security] whitelisted origin does NOT auto-approve when global auto approval is disabled', async () => {
    const { deps, createdRequests, createdRules } = createDeps({
      autoApproveMachineRequests: false,
      getRulesByGroup: (_groupId, type) =>
        Promise.resolve(
          type === 'whitelist'
            ? [
                {
                  id: 'rule-origin',
                  groupId: 'group-1',
                  type: 'whitelist',
                  value: '*.github.io',
                  source: 'manual',
                  comment: null,
                  createdAt: new Date().toISOString(),
                },
              ]
            : []
        ) as Promise<Rule[]>,
    });

    // Attacker supplies an originPage whose hostname matches the whitelisted wildcard.
    const result = await decideAutoMachineRequest(
      {
        domainRaw: 'evil-target.com',
        hostnameRaw: 'lab-host-01',
        originPage: 'https://attacker.github.io/page',
        token: 'token',
      },
      deps
    );

    // Must be pending (human approval required), NOT auto-approved.
    assert.ok(result.ok);
    assert.equal(result.data.autoApproved, false);
    assert.equal(result.data.domain, 'evil-target.com');
    // A pending request must have been created for human review.
    assert.equal(createdRequests.length, 1);
    // No automatic whitelist rule must have been created for the target.
    assert.equal(createdRules.length, 0);
  });

  await test('[security] wildcard-user-content origin does NOT self-whitelist arbitrary target when auto approval is disabled', async () => {
    const { deps, createdRequests, createdRules } = createDeps({
      autoApproveMachineRequests: false,
      getRulesByGroup: (_groupId, type) =>
        Promise.resolve(
          type === 'whitelist'
            ? [
                {
                  id: 'rule-cdn',
                  groupId: 'group-1',
                  type: 'whitelist',
                  value: 'github.io',
                  source: 'manual',
                  comment: null,
                  createdAt: new Date().toISOString(),
                },
              ]
            : []
        ) as Promise<Rule[]>,
    });

    const result = await decideAutoMachineRequest(
      {
        domainRaw: 'blocked-by-teacher.example',
        hostnameRaw: 'lab-host-01',
        originPage: 'https://student-project.github.io/index.html',
        token: 'token',
      },
      deps
    );

    assert.ok(result.ok);
    assert.equal(result.data.autoApproved, false);
    // Pending request created for human review, no rule auto-created.
    assert.equal(createdRequests.length, 1);
    assert.equal(createdRules.length, 0);
  });

  await test('automatic whitelist event is published only after transaction commit', async () => {
    const calls: string[] = [];
    const transaction = 'tx-1' as unknown as DbExecutor;
    const { deps } = createDeps({
      autoApproveMachineRequests: true,
      createRule: (groupId, type, value, comment, source, tx) => {
        assert.equal(tx, transaction);
        calls.push('create:tx-1');
        return Promise.resolve({ success: true, id: 'rule-1' });
      },
      publishWhitelistChanged: (groupId) => {
        calls.push(`event:${groupId}`);
      },
      withTransaction: async (operation) => {
        calls.push('begin');
        const result = await operation(transaction);
        calls.push('commit');
        return result;
      },
    });

    const result = await decideAutoMachineRequest(
      { domainRaw: 'cdn.example.com', hostnameRaw: 'lab-host-01', token: 'token' },
      deps
    );

    assert.ok(result.ok);
    assert.deepEqual(calls, ['begin', 'create:tx-1', 'commit', 'event:group-1']);
  });

  await test('duplicate whitelist rule returns duplicate status', async () => {
    const { deps } = createDeps({
      autoApproveMachineRequests: true,
      createRule: () => Promise.resolve({ success: false, error: 'Rule already exists' }),
    });

    const result = await decideAutoMachineRequest(
      { domainRaw: 'cdn.example.com', hostnameRaw: 'lab-host-01', token: 'token' },
      deps
    );

    assert.deepEqual(result, {
      ok: true,
      data: {
        autoApproved: true,
        domain: 'cdn.example.com',
        duplicate: true,
        groupId: 'group-1',
        source: 'auto_extension',
        status: 'duplicate',
      },
    });
  });
});
