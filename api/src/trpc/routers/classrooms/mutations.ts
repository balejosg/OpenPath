import { TRPCError } from '@trpc/server';

import ClassroomService from '../../../services/classroom.service.js';
import type { Context } from '../../context.js';
import {
  adminProcedure,
  publicProcedure,
  requireEnrollmentTokenAccess,
  teacherProcedure,
} from '../../trpc.js';
import {
  classroomIdSchema,
  createClassroomExemptionInputSchema,
  createClassroomInputSchema,
  createOperationalClassroomExemptionInputSchema,
  deleteExemptionInputSchema,
  deleteMachineInputSchema,
  registerMachineInputSchema,
  rotateMachineTokenInputSchema,
  setActiveGroupInputSchema,
  updateClassroomInputSchema,
} from './schemas.js';
import {
  throwClassroomServiceError,
  toCreateClassroomInput,
  toUpdateClassroomData,
} from './shared.js';

async function resolveEnrollmentRegistration(
  request: Context['req'],
  input: {
    hostname: string;
    classroomId?: string | undefined;
    classroomName?: string | undefined;
    version?: string | undefined;
  }
): Promise<{
  hostname: string;
  classroomId: string;
  classroomName: string;
  version?: string | undefined;
}> {
  const enrollment = await requireEnrollmentTokenAccess(request);

  if (input.classroomId && input.classroomId !== enrollment.classroomId) {
    throw new TRPCError({
      code: 'FORBIDDEN',
      message: 'Enrollment token is not valid for this classroom',
    });
  }

  if (input.classroomName && input.classroomName !== enrollment.classroomName) {
    throw new TRPCError({
      code: 'FORBIDDEN',
      message: 'Enrollment token is not valid for this classroom',
    });
  }

  return {
    ...input,
    classroomId: enrollment.classroomId,
    classroomName: enrollment.classroomName,
  };
}

export const classroomMutationProcedures = {
  create: adminProcedure.input(createClassroomInputSchema).mutation(async ({ input }) => {
    const result = await ClassroomService.createClassroom(toCreateClassroomInput(input));
    if (!result.ok) {
      throwClassroomServiceError(result.error);
    }
    return result.data;
  }),

  update: adminProcedure.input(updateClassroomInputSchema).mutation(async ({ input }) => {
    const result = await ClassroomService.updateClassroom(input.id, toUpdateClassroomData(input));
    if (!result.ok) {
      throwClassroomServiceError(result.error);
    }
    return result.data;
  }),

  setActiveGroup: teacherProcedure
    .input(setActiveGroupInputSchema)
    .mutation(async ({ input, ctx }) => {
      const result = await ClassroomService.setClassroomActiveGroup(ctx.user, input);
      if (!result.ok) {
        throwClassroomServiceError(result.error);
      }
      return result.data;
    }),

  createExemption: teacherProcedure
    .input(createClassroomExemptionInputSchema)
    .mutation(async ({ input, ctx }) => {
      const result = await ClassroomService.createExemptionForClassroom(ctx.user, {
        ...input,
        createdBy: ctx.user.sub,
      });
      if (!result.ok) {
        throwClassroomServiceError(result.error);
      }
      return result.data;
    }),

  createOperationalExemption: adminProcedure
    .input(createOperationalClassroomExemptionInputSchema)
    .mutation(async ({ input, ctx }) => {
      const result = await ClassroomService.createOperationalExemptionForClassroom(ctx.user, {
        ...input,
        createdBy: ctx.user.sub,
      });
      if (!result.ok) {
        throwClassroomServiceError(result.error);
      }
      return result.data;
    }),

  deleteExemption: teacherProcedure
    .input(deleteExemptionInputSchema)
    .mutation(async ({ input, ctx }) => {
      const result = await ClassroomService.deleteExemptionForClassroom(ctx.user, input.id);
      if (!result.ok) {
        throwClassroomServiceError(result.error);
      }
      return result.data;
    }),

  delete: adminProcedure.input(classroomIdSchema).mutation(async ({ input }) => {
    const result = await ClassroomService.deleteClassroom(input.id);
    if (!result.ok) {
      throwClassroomServiceError(result.error);
    }
    return result.data;
  }),

  registerMachine: publicProcedure
    .input(registerMachineInputSchema)
    .mutation(async ({ input, ctx }) => {
      const result = await ClassroomService.registerMachine(
        await resolveEnrollmentRegistration(ctx.req, input)
      );
      if (!result.ok) {
        throwClassroomServiceError(result.error);
      }

      const roomResult = await ClassroomService.getClassroom(result.data.classroomId);
      return {
        machine: result.data,
        classroom: roomResult.ok ? roomResult.data : null,
      };
    }),

  deleteMachine: adminProcedure.input(deleteMachineInputSchema).mutation(async ({ input }) => {
    const result = await ClassroomService.deleteMachine(input.hostname);
    if (!result.ok) {
      throwClassroomServiceError(result.error);
    }
    return result.data;
  }),

  rotateMachineToken: adminProcedure
    .input(rotateMachineTokenInputSchema)
    .mutation(async ({ input }) => {
      const result = await ClassroomService.rotateMachineToken(input.machineId);
      if (!result.ok) {
        throwClassroomServiceError(result.error);
      }
      return { success: true, whitelistUrl: result.data.whitelistUrl };
    }),
};
