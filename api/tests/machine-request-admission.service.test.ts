import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { AuthenticatedMachine } from '../src/lib/server-request-auth.js';
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
  configPosture: null,
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

function createDeps(overrides: Partial<MachineRequestAdmissionDeps> = {}): {
  createdRequests: Record<string, unknown>[];
  deps: Partial<MachineRequestAdmissionDeps>;
} {
  const createdRequests: Record<string, unknown>[] = [];
  const deps: Partial<MachineRequestAdmissionDeps> = {
    createRequest: (input) => {
      createdRequests.push(input as unknown as Record<string, unknown>);
      return Promise.resolve({ ok: true, data: { id: 'request-1', status: 'pending' } });
    },
    logger: { warn: (): void => undefined },
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
    ...overrides,
  };

  return { deps, createdRequests };
}

await describe('machine request admission service — submit path', async () => {
  const { createSubmittedMachineRequest } =
    await import('../src/services/machine-request-admission.service.js');

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
});
