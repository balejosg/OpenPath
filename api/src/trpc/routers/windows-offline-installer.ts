import { TRPCError } from '@trpc/server';
import { z } from 'zod';

import { getPublicBaseUrl } from '../../lib/server-asset-http.js';
import {
  createWindowsOfflineInstallerService,
  WindowsOfflineInstallerError,
} from '../../services/windows-offline-installer-artifact.service.js';
import { router, teacherProcedure } from '../trpc.js';

const generateInput = z.object({
  classroomId: z.string().min(1).max(128),
});

function toTrpcError(error: unknown): TRPCError {
  if (error instanceof WindowsOfflineInstallerError) {
    if (error.code === 'NOT_FOUND') {
      return new TRPCError({ code: 'NOT_FOUND', message: 'Classroom not found' });
    }
    if (error.code === 'FORBIDDEN') {
      return new TRPCError({ code: 'FORBIDDEN', message: 'Classroom access denied' });
    }
    if (error.code === 'UNAUTHORIZED') {
      return new TRPCError({ code: 'UNAUTHORIZED', message: 'Authentication required' });
    }
  }
  return new TRPCError({
    code: 'INTERNAL_SERVER_ERROR',
    message: 'Failed to generate offline installer',
  });
}

export const windowsOfflineInstallerRouter = router({
  generate: teacherProcedure.input(generateInput).mutation(async ({ ctx, input }) => {
    try {
      const artifact = await createWindowsOfflineInstallerService().generate({
        apiUrl: getPublicBaseUrl(ctx.req),
        classroomId: input.classroomId,
        user: ctx.user,
      });

      return {
        fileName: artifact.fileName,
        version: artifact.version,
        sha256: artifact.sha256,
        tokenExpiresAt: artifact.tokenExpiresAt,
        downloadUrl: artifact.downloadUrl,
        downloadExpiresAt: artifact.downloadExpiresAt,
      };
    } catch (error) {
      throw toTrpcError(error);
    }
  }),
});
