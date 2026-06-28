import { z } from 'zod';
import {
  router,
  publicProcedure,
  protectedProcedure,
  teacherProcedure,
  adminProcedure,
} from '../trpc.js';
import { RequestStatusSchema, CreateRequestDTOSchema } from '../../types/index.js';
import { TRPCError } from '@trpc/server';
import { CreateRequestData } from '../../types/storage.js';
import { stripUndefined } from '../../lib/utils.js';
import RequestService from '../../services/request.service.js';
import * as auth from '../../lib/auth.js';

/**
 * Source values a PUBLIC (unauthenticated) caller may declare on requests.create.
 * Any source the public caller supplies that is not in this allowlist is coerced
 * to `manual`. Normalization always runs for public submissions — there is no
 * skip-normalization path on the public tRPC surface.
 */
const PUBLIC_REQUEST_SOURCES = new Set(['manual', 'firefox-extension', 'web']);
const DEFAULT_PUBLIC_REQUEST_SOURCE = 'manual';

function resolvePublicRequestSource(source: string | undefined): string {
  if (source !== undefined && PUBLIC_REQUEST_SOURCES.has(source)) {
    return source;
  }
  return DEFAULT_PUBLIC_REQUEST_SOURCE;
}

export const requestsRouter = router({
  /**
   * Create a new domain access request.
   * Public endpoint, requires valid email.
   */
  create: publicProcedure.input(CreateRequestDTOSchema).mutation(async ({ input }) => {
    const result = await RequestService.createRequest(
      stripUndefined({
        domain: input.domain.toLowerCase(),
        reason: input.reason ?? 'No reason provided',
        requesterEmail: input.requesterEmail,
        groupId: input.groupId,
        // Server-assigned: unknown or non-allowlisted sources collapse to `manual`.
        source: resolvePublicRequestSource(input.source),
        machineHostname: input.machineHostname,
        originHost: input.originHost,
        originPage: input.originPage,
        clientVersion: input.clientVersion,
        errorType: input.errorType,
      }) as CreateRequestData
    );

    if (!result.ok) {
      throw new TRPCError({ code: result.error.code, message: result.error.message });
    }
    return result.data;
  }),

  /**
   * Get request status by ID.
   * Public endpoint for polling status.
   */
  getStatus: publicProcedure.input(z.object({ id: z.string() })).query(async ({ input }) => {
    const result = await RequestService.getRequestStatus(input.id);
    if (!result.ok) {
      throw new TRPCError({ code: result.error.code, message: result.error.message });
    }
    return result.data;
  }),

  /**
   * List all requests.
   * Protected endpoint.
   */
  list: protectedProcedure
    .input(z.object({ status: RequestStatusSchema.optional() }))
    .query(async ({ input, ctx }) => {
      return await RequestService.listRequests(input.status ?? null, ctx.user);
    }),

  /**
   * Get full request details by ID.
   * Protected endpoint. Enforces group access control.
   */
  get: protectedProcedure.input(z.object({ id: z.string() })).query(async ({ input, ctx }) => {
    const result = await RequestService.getRequest(input.id, ctx.user);
    if (!result.ok) {
      throw new TRPCError({ code: result.error.code, message: result.error.message });
    }
    return result.data;
  }),

  /**
   * Approve a request.
   * Teacher/Admin endpoint.
   */
  approve: teacherProcedure
    .input(z.object({ id: z.string(), groupId: z.string().optional() }))
    .mutation(async ({ input, ctx }) => {
      const result = await RequestService.approveRequest(input.id, input.groupId, ctx.user);
      if (!result.ok) {
        throw new TRPCError({ code: result.error.code, message: result.error.message });
      }
      return result.data;
    }),

  // Teacher+: Reject
  reject: teacherProcedure
    .input(z.object({ id: z.string(), reason: z.string().optional() }))
    .mutation(async ({ input, ctx }) => {
      const result = await RequestService.rejectRequest(input.id, input.reason, ctx.user);
      if (!result.ok) {
        throw new TRPCError({ code: result.error.code, message: result.error.message });
      }
      return result.data;
    }),

  // Admin: Delete
  delete: adminProcedure.input(z.object({ id: z.string() })).mutation(async ({ input }) => {
    const result = await RequestService.deleteRequest(input.id);
    if (!result.ok) {
      throw new TRPCError({ code: result.error.code, message: result.error.message });
    }
    return result.data;
  }),

  /**
   * Get request statistics.
   * Admin endpoint.
   */
  stats: adminProcedure.query(async () => {
    return await RequestService.getStats();
  }),

  // Protected: List groups
  listGroups: protectedProcedure.query(async ({ ctx }) => {
    return await RequestService.listGroupsForUser(ctx.user);
  }),

  // Admin: List blocked domains for a group
  listBlocked: adminProcedure.input(z.object({ groupId: z.string() })).query(async ({ input }) => {
    return await RequestService.listBlockedDomains(input.groupId);
  }),

  // Protected: Check if domain is blocked in a group
  check: protectedProcedure
    .input(z.object({ domain: z.string(), groupId: z.string() }))
    .mutation(async ({ input, ctx }) => {
      // Scope to the caller's approval groups, matching `list`/`get`. Without this
      // any authenticated user could enumerate another group's blocked rules by
      // passing an arbitrary groupId. Admins (canApproveGroup -> true) may check
      // any group.
      if (!auth.canApproveGroup(ctx.user, input.groupId)) {
        throw new TRPCError({
          code: 'FORBIDDEN',
          message: 'You do not have access to this group',
        });
      }
      return await RequestService.checkDomainBlocked(input.groupId, input.domain);
    }),
});
