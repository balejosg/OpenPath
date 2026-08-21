import * as classroomStorage from '../lib/classroom-storage.js';
import {
  EnrollmentTokenTtlError,
  assertWithinEnrollmentTtlCeiling,
  generateEnrollmentTokenWithExpiry,
  verifyEnrollmentToken,
} from '../lib/enrollment-token.js';
import ClassroomService from './classroom.service.js';
import type { JWTPayload } from '../types/index.js';
import type {
  EnrollmentServiceResult,
  EnrollmentTicketOutput,
  EnrollmentTokenAccess,
} from './enrollment-service-shared.js';
import { hasEnrollmentRole } from './enrollment-service-shared.js';

export async function resolveEnrollmentContext(input: {
  authorizationHeader?: string | undefined;
  classroomId: string;
}): Promise<
  EnrollmentServiceResult<{
    classroom: NonNullable<Awaited<ReturnType<typeof classroomStorage.getClassroomById>>>;
    enrollmentToken: string;
  }>
> {
  if (!input.classroomId) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'Missing classroomId' },
    };
  }

  const authHeader = input.authorizationHeader;
  if (authHeader?.startsWith('Bearer ') !== true) {
    return {
      ok: false,
      error: { code: 'UNAUTHORIZED', message: 'Authorization header required' },
    };
  }

  const enrollmentToken = authHeader.slice(7);
  const payload = verifyEnrollmentToken(enrollmentToken);
  if (!payload) {
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Invalid enrollment token' },
    };
  }

  if (payload.classroomId !== input.classroomId) {
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Enrollment token does not match classroom' },
    };
  }

  const classroom = await classroomStorage.getClassroomById(input.classroomId);
  if (!classroom) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Classroom not found' },
    };
  }

  return {
    ok: true,
    data: {
      classroom,
      enrollmentToken,
    },
  };
}

export async function resolveEnrollmentTokenAccess(
  authorizationHeader?: string
): Promise<EnrollmentServiceResult<EnrollmentTokenAccess>> {
  if (authorizationHeader?.startsWith('Bearer ') !== true) {
    return {
      ok: false,
      error: { code: 'UNAUTHORIZED', message: 'Authorization header required' },
    };
  }

  const enrollmentToken = authorizationHeader.slice(7);
  const payload = verifyEnrollmentToken(enrollmentToken);
  if (!payload) {
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Invalid enrollment token' },
    };
  }

  const classroom = await classroomStorage.getClassroomById(payload.classroomId);
  if (!classroom) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Classroom not found' },
    };
  }

  return {
    ok: true,
    data: {
      classroomId: classroom.id,
      classroomName: classroom.name,
    },
  };
}

export async function issueEnrollmentTicket(input: {
  classroomId: string;
  user: JWTPayload;
  expiresIn?: string;
}): Promise<EnrollmentServiceResult<EnrollmentTicketOutput>> {
  if (!hasEnrollmentRole(input.user.roles)) {
    return {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Teacher access required' },
    };
  }

  if (!input.classroomId) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'classroomId parameter required' },
    };
  }

  if (input.expiresIn !== undefined) {
    try {
      assertWithinEnrollmentTtlCeiling(input.expiresIn);
    } catch (error) {
      return {
        ok: false,
        error: {
          code: 'BAD_REQUEST',
          message:
            error instanceof EnrollmentTokenTtlError ? error.message : 'Invalid expiresIn value',
        },
      };
    }
  }

  const access = await ClassroomService.ensureUserCanEnrollClassroom(input.user, input.classroomId);
  if (!access.ok) {
    return {
      ok: false,
      error: {
        code: access.error.code,
        message: access.error.message,
      },
    };
  }

  try {
    const bundle = generateEnrollmentTokenWithExpiry(access.data.id, input.expiresIn);
    return {
      ok: true,
      data: {
        enrollmentToken: bundle.enrollmentToken,
        expiresAt: bundle.expiresAt,
        classroomId: access.data.id,
        classroomName: access.data.name,
      },
    };
  } catch (error) {
    return {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message:
          error instanceof EnrollmentTokenTtlError
            ? error.message
            : 'Unable to issue enrollment token',
      },
    };
  }
}

export const EnrollmentAccessService = {
  resolveEnrollmentContext,
  resolveEnrollmentTokenAccess,
  issueEnrollmentTicket,
};

export default EnrollmentAccessService;
