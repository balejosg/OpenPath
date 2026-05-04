import { describe, test } from 'node:test';
import assert from 'node:assert';

import { CANONICAL_GROUP_IDS } from './fixtures.js';
import { createAccessToken, registerSecurityLifecycle, request } from './security-test-harness.js';

registerSecurityLifecycle();

void describe('Security tests - authorization boundaries', () => {
  void test('prevents students from approving requests', async () => {
    const domain = `student-test-${Date.now().toString()}.com`;
    const createResp = await request('/trpc/requests.create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        domain,
        reason: 'test',
        requesterEmail: 'student@school.edu',
        groupId: CANONICAL_GROUP_IDS.groupA,
      }),
    });
    assert.strictEqual(createResp.status, 200);
    const requestId = (createResp.body as { result: { data: { id: string } } }).result.data.id;

    const studentToken = await createAccessToken({
      sub: 'student-1',
      email: 'student@school.edu',
      name: 'Student',
      roles: [{ role: 'student', groupIds: [CANONICAL_GROUP_IDS.groupA] }],
    });

    const approveResp = await request('/trpc/requests.approve', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${studentToken}`,
      },
      body: JSON.stringify({ id: requestId }),
    });

    assert.strictEqual(approveResp.status, 403);
  });

  void test('prevents cross-group access', async () => {
    const domain = `group-b-test-${Date.now().toString()}.com`;
    const createResp = await request('/trpc/requests.create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        domain,
        reason: 'test',
        requesterEmail: 'user@school.edu',
        groupId: CANONICAL_GROUP_IDS.groupB,
      }),
    });
    assert.strictEqual(createResp.status, 200);
    const requestId = (createResp.body as { result: { data: { id: string } } }).result.data.id;

    const teacherToken = await createAccessToken({
      sub: 'teacher-1',
      email: 'teacher@school.edu',
      name: 'Teacher',
      roles: [{ role: 'teacher', groupIds: [CANONICAL_GROUP_IDS.groupA] }],
    });

    const approveResp = await request('/trpc/requests.approve', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${teacherToken}`,
      },
      body: JSON.stringify({ id: requestId }),
    });

    assert.strictEqual(approveResp.status, 403);
  });

  void test('allows teachers to approve pending requests for their group', async () => {
    const domain = `approve-test-${Date.now().toString()}.com`;
    const createResp = await request('/trpc/requests.create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        domain,
        reason: 'test',
        requesterEmail: 'user@school.edu',
        groupId: CANONICAL_GROUP_IDS.groupA,
      }),
    });
    assert.strictEqual(createResp.status, 200);
    const requestId = (createResp.body as { result: { data: { id: string } } }).result.data.id;

    const teacherToken = await createAccessToken({
      sub: 'teacher-approve',
      email: 'teacher-approve@school.edu',
      name: 'Teacher Approve',
      roles: [{ role: 'teacher', groupIds: [CANONICAL_GROUP_IDS.groupA] }],
    });

    const approveResp = await request('/trpc/requests.approve', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${teacherToken}`,
      },
      body: JSON.stringify({ id: requestId }),
    });

    assert.strictEqual(approveResp.status, 200);
    const approved = (approveResp.body as { result: { data: { status: string } } }).result.data;
    assert.strictEqual(approved.status, 'approved');

    const secondApproveResp = await request('/trpc/requests.approve', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${teacherToken}`,
      },
      body: JSON.stringify({ id: requestId }),
    });
    assert.strictEqual(secondApproveResp.status, 400);
  });

  void test('rejects approval when an explicit target group cannot be resolved', async () => {
    const domain = `missing-target-${Date.now().toString()}.com`;
    const createResp = await request('/trpc/requests.create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        domain,
        reason: 'test',
        requesterEmail: 'user@school.edu',
        groupId: CANONICAL_GROUP_IDS.groupA,
      }),
    });
    assert.strictEqual(createResp.status, 200);
    const requestId = (createResp.body as { result: { data: { id: string } } }).result.data.id;

    const teacherToken = await createAccessToken({
      sub: 'teacher-missing-target',
      email: 'teacher-missing-target@school.edu',
      name: 'Teacher Missing Target',
      roles: [{ role: 'teacher', groupIds: ['missing-target-group'] }],
    });

    const approveResp = await request('/trpc/requests.approve', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${teacherToken}`,
      },
      body: JSON.stringify({ id: requestId, groupId: 'missing-target-group' }),
    });

    assert.strictEqual(approveResp.status, 400);
  });

  void test('allows teachers to reject pending requests for their group', async () => {
    const domain = `reject-test-${Date.now().toString()}.com`;
    const createResp = await request('/trpc/requests.create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        domain,
        reason: 'test',
        requesterEmail: 'user@school.edu',
        groupId: CANONICAL_GROUP_IDS.groupA,
      }),
    });
    assert.strictEqual(createResp.status, 200);
    const requestId = (createResp.body as { result: { data: { id: string } } }).result.data.id;

    const teacherToken = await createAccessToken({
      sub: 'teacher-reject',
      email: 'teacher-reject@school.edu',
      name: 'Teacher Reject',
      roles: [{ role: 'teacher', groupIds: [CANONICAL_GROUP_IDS.groupA] }],
    });

    const rejectResp = await request('/trpc/requests.reject', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${teacherToken}`,
      },
      body: JSON.stringify({ id: requestId, reason: 'not needed' }),
    });

    assert.strictEqual(rejectResp.status, 200);
    const rejected = (rejectResp.body as { result: { data: { status: string } } }).result.data;
    assert.strictEqual(rejected.status, 'rejected');

    const secondRejectResp = await request('/trpc/requests.reject', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${teacherToken}`,
      },
      body: JSON.stringify({ id: requestId, reason: 'still no' }),
    });
    assert.strictEqual(secondRejectResp.status, 400);
  });

  void test('rejects cookie-authenticated mutations without a trusted origin', async () => {
    const response = await request('/trpc/auth.logout', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Cookie: 'op_access=fake-access; op_refresh=fake-refresh',
      },
      body: JSON.stringify({}),
    });

    assert.strictEqual(response.status, 403);
    const body = response.body as { code?: string; error?: string };
    assert.strictEqual(body.code, 'FORBIDDEN');
    assert.match(body.error ?? '', /csrf origin/i);
  });

  void test('allows trusted-origin cookie mutations to continue past CSRF checks', async () => {
    const response = await request('/trpc/auth.logout', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Cookie: 'op_access=fake-access; op_refresh=fake-refresh',
        Origin: 'http://localhost:3000',
      },
      body: JSON.stringify({}),
    });

    assert.notStrictEqual(response.status, 403);
  });
});
