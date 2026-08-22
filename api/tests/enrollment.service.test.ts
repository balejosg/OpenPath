import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test-jwt-secret';

await describe('enrollment service', async () => {
  const { issueEnrollmentTicket, resolveEnrollmentContext, resolveEnrollmentTokenAccess } =
    await import('../src/services/enrollment-access.service.js');
  const { generateEnrollmentToken } = await import('../src/lib/enrollment-token.js');
  const classroomStorage = await import('../src/lib/classroom-storage.js');

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

  await test('rejects missing classroomId on ticket issuance', async () => {
    const result = await issueEnrollmentTicket({
      classroomId: '',
      user: {
        sub: 'admin-1',
        email: 'admin@example.com',
        name: 'Admin User',
        type: 'access',
        roles: [{ role: 'admin', groupIds: [] }],
      },
    });

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'classroomId parameter required' },
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

  await test('issues ticket successfully for existing classroom with admin role', async () => {
    const classroomName = `enrollment-test-${Math.random().toString(36).slice(2, 8)}`;
    const classroom = await classroomStorage.createClassroom({ name: classroomName });
    const result = await issueEnrollmentTicket({
      classroomId: classroom.id,
      expiresIn: '12h',
      user: {
        sub: 'admin-1',
        email: 'admin@example.com',
        name: 'Admin Example',
        type: 'access',
        roles: [{ role: 'admin', groupIds: [] }],
      },
    });

    assert.equal(result.ok, true);
    if (result.ok) {
      assert.equal(result.data.classroomId, classroom.id);
      assert.equal(result.data.classroomName, classroom.name);
      assert.ok(typeof result.data.enrollmentToken === 'string');
      assert.ok(typeof result.data.expiresAt === 'string');
    }
  });

  await test('resolveEnrollmentContext handles validation and success cases', async () => {
    assert.deepEqual(await resolveEnrollmentContext({ classroomId: '' }), {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Missing classroomId' },
    });

    assert.deepEqual(
      await resolveEnrollmentContext({ classroomId: 'c1', authorizationHeader: 'invalid' }),
      {
        ok: false,
        error: { code: 'UNAUTHORIZED', message: 'Authorization header required' },
      }
    );

    assert.deepEqual(
      await resolveEnrollmentContext({ classroomId: 'c1', authorizationHeader: 'Bearer not-jwt' }),
      {
        ok: false,
        error: { code: 'FORBIDDEN', message: 'Invalid enrollment token' },
      }
    );

    const tokenForOther = generateEnrollmentToken('other-classroom');
    assert.deepEqual(
      await resolveEnrollmentContext({
        classroomId: 'target-classroom',
        authorizationHeader: `Bearer ${tokenForOther}`,
      }),
      {
        ok: false,
        error: { code: 'FORBIDDEN', message: 'Enrollment token does not match classroom' },
      }
    );

    const tokenMissingClassroom = generateEnrollmentToken('non-existent-room-id');
    assert.deepEqual(
      await resolveEnrollmentContext({
        classroomId: 'non-existent-room-id',
        authorizationHeader: `Bearer ${tokenMissingClassroom}`,
      }),
      {
        ok: false,
        error: { code: 'NOT_FOUND', message: 'Classroom not found' },
      }
    );

    const classroomName = `context-room-${Math.random().toString(36).slice(2, 8)}`;
    const classroom = await classroomStorage.createClassroom({ name: classroomName });
    const validToken = generateEnrollmentToken(classroom.id);
    const success = await resolveEnrollmentContext({
      classroomId: classroom.id,
      authorizationHeader: `Bearer ${validToken}`,
    });
    assert.equal(success.ok, true);
    if (success.ok) {
      assert.equal(success.data.classroom.id, classroom.id);
      assert.equal(success.data.enrollmentToken, validToken);
    }
  });

  await test('resolveEnrollmentTokenAccess handles validation and success cases', async () => {
    assert.deepEqual(await resolveEnrollmentTokenAccess(undefined), {
      ok: false,
      error: { code: 'UNAUTHORIZED', message: 'Authorization header required' },
    });

    assert.deepEqual(await resolveEnrollmentTokenAccess('Bearer not-valid'), {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Invalid enrollment token' },
    });

    const tokenMissing = generateEnrollmentToken('non-existent-room-2');
    assert.deepEqual(await resolveEnrollmentTokenAccess(`Bearer ${tokenMissing}`), {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Classroom not found' },
    });

    const classroomName = `access-room-${Math.random().toString(36).slice(2, 8)}`;
    const classroom = await classroomStorage.createClassroom({ name: classroomName });
    const validToken = generateEnrollmentToken(classroom.id);
    const success = await resolveEnrollmentTokenAccess(`Bearer ${validToken}`);
    assert.equal(success.ok, true);
    if (success.ok) {
      assert.equal(success.data.classroomId, classroom.id);
      assert.equal(success.data.classroomName, classroom.name);
    }
  });
});
