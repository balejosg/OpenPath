import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test-jwt-secret';

await describe('enrollment service', async () => {
  const { issueEnrollmentTicket } = await import('../src/services/enrollment.service.js');

  function assertTicketError(result: Awaited<ReturnType<typeof issueEnrollmentTicket>>): {
    code: string;
    message: string;
  } {
    if (result.ok) {
      assert.fail('Expected an error result but ticket issuance succeeded');
    }
    return result.error;
  }

  await test('requires a teacher or admin role before issuing enrollment tickets', async () => {
    const result = await issueEnrollmentTicket({
      classroomId: 'classroom-1',
      user: {
        sub: 'student-1',
        email: 'student@example.com',
        name: 'Student Example',
        type: 'access',
        roles: [{ role: 'student', groupIds: [] }],
      },
    });

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Teacher access required' },
    });
  });

  await test('rejects expiresIn beyond the configured ceiling before touching storage', async () => {
    const result = await issueEnrollmentTicket({
      classroomId: 'classroom-1',
      expiresIn: '9999h',
      user: {
        sub: 'teacher-1',
        email: 'teacher@example.com',
        name: 'Teacher Example',
        type: 'access',
        roles: [{ role: 'teacher', groupIds: [] }],
      },
    });

    const error = assertTicketError(result);
    assert.equal(error.code, 'BAD_REQUEST');
    assert.match(error.message, /maximum/i);
  });

  await test('rejects malformed expiresIn values before touching storage', async () => {
    const result = await issueEnrollmentTicket({
      classroomId: 'classroom-1',
      expiresIn: 'banana',
      user: {
        sub: 'teacher-2',
        email: 'teacher2@example.com',
        name: 'Teacher Two',
        type: 'access',
        roles: [{ role: 'admin', groupIds: [] }],
      },
    });

    const error = assertTicketError(result);
    assert.equal(error.code, 'BAD_REQUEST');
  });
});
