import { z } from 'zod';
import { router, publicProcedure, protectedProcedure } from '../trpc.js';
import { TRPCError } from '@trpc/server';
import { CreatePushSubscriptionDTOSchema, getErrorMessage } from '../../types/index.js';
import * as push from '../../lib/push.js';
import * as auth from '../../lib/auth.js';
import { logger } from '../../lib/logger.js';

export const pushRouter = router({
  // Backwards-compatible alias (older clients/tests)
  getVapidPublicKey: publicProcedure.query(() => {
    const publicKey = push.getVapidPublicKey();
    if (publicKey === null || publicKey === '') {
      throw new TRPCError({
        code: 'SERVICE_UNAVAILABLE',
        message: 'Push notifications not configured',
      });
    }
    return { publicKey, enabled: true };
  }),

  getVapidKey: publicProcedure.query(() => {
    const publicKey = push.getVapidPublicKey();
    if (publicKey === null || publicKey === '') {
      throw new TRPCError({
        code: 'SERVICE_UNAVAILABLE',
        message: 'Push notifications not configured',
      });
    }
    return { publicKey, enabled: true };
  }),

  getStatus: protectedProcedure.query(async ({ ctx }) => {
    const enabled = push.isPushEnabled();
    const subscriptions = await push.getSubscriptionsForUser(ctx.user.sub);

    return {
      pushEnabled: enabled,
      subscriptionCount: subscriptions.length,
      subscriptions: subscriptions.map((s) => ({
        id: s.id,
        groupIds: s.groupIds,
        createdAt: s.createdAt,
        userAgent: s.userAgent,
      })),
    };
  }),

  subscribe: protectedProcedure
    .input(
      z.object({
        subscription: CreatePushSubscriptionDTOSchema.omit({ userAgent: true }),
        groupIds: z.array(z.string()).optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      const userGroups = auth.getApprovalGroups(ctx.user);
      let targetGroups: string[];

      if (input.groupIds === undefined || input.groupIds.length === 0) {
        // No explicit groups: fall back to the caller's own approval scope.
        if (userGroups === 'all') {
          targetGroups = ['*'];
        } else if (userGroups.length > 0) {
          targetGroups = userGroups;
        } else {
          throw new TRPCError({ code: 'BAD_REQUEST', message: 'No groups to subscribe to' });
        }
      } else if (userGroups === 'all') {
        // Admins may subscribe to any group, including the '*' wildcard.
        targetGroups = input.groupIds;
      } else {
        // Non-admins: a client-supplied group list is an IDOR vector. Intersect it
        // with the caller's approval groups and never honour the admin-only '*'
        // wildcard. If nothing survives the intersection, the caller asked only for
        // groups they do not own -> reject.
        const allowed = new Set(userGroups);
        targetGroups = input.groupIds.filter((groupId) => groupId !== '*' && allowed.has(groupId));
        if (targetGroups.length === 0) {
          // Nothing the caller is allowed to subscribe to remained after scoping.
          // Use BAD_REQUEST without disclosing whether the requested groups exist,
          // so this path cannot be used to probe other tenants' group ids.
          throw new TRPCError({
            code: 'BAD_REQUEST',
            message: 'No subscribable groups in request',
          });
        }
      }

      try {
        const userAgent = ctx.req.headers['user-agent'] ?? '';
        const record = await push.saveSubscription(
          ctx.user.sub,
          targetGroups,
          input.subscription as push.PushSubscriptionData,
          userAgent
        );

        return {
          success: true,
          subscriptionId: record.id,
          groupIds: record.groupIds,
        };
      } catch (error) {
        const message = getErrorMessage(error);
        logger.error('Error saving subscription', {
          error: message,
          userId: ctx.user.sub,
          endpoint: input.subscription.endpoint.substring(0, 50),
        });

        if (message.startsWith('Unknown group IDs:')) {
          throw new TRPCError({
            code: 'BAD_REQUEST',
            message,
          });
        }

        throw new TRPCError({
          code: 'INTERNAL_SERVER_ERROR',
          message: 'Failed to save subscription',
        });
      }
    }),

  unsubscribe: protectedProcedure
    .input(
      z.object({
        endpoint: z.string().optional(),
        subscriptionId: z.string().optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      const endpoint =
        input.endpoint !== undefined && input.endpoint !== '' ? input.endpoint : undefined;
      const subscriptionId =
        input.subscriptionId !== undefined && input.subscriptionId !== ''
          ? input.subscriptionId
          : undefined;

      if (endpoint === undefined && subscriptionId === undefined) {
        throw new TRPCError({
          code: 'BAD_REQUEST',
          message: 'Either endpoint or subscriptionId required',
        });
      }

      // Ownership scoping: only delete a subscription that belongs to the caller.
      // The lib delete-by-endpoint/id helpers are unscoped, so a raw call would let
      // any authenticated user remove another tenant's subscription (IDOR). Resolve
      // the caller's own subscriptions and require the target to be among them.
      const ownSubscriptions = await push.getSubscriptionsForUser(ctx.user.sub);
      const target = ownSubscriptions.find((subscription) => {
        if (subscriptionId !== undefined) {
          return subscription.id === subscriptionId;
        }
        return subscription.subscription.endpoint === endpoint;
      });

      if (target === undefined) {
        throw new TRPCError({ code: 'NOT_FOUND', message: 'Subscription not found' });
      }

      const deleted = await push.deleteSubscriptionById(target.id);
      if (!deleted) {
        throw new TRPCError({ code: 'NOT_FOUND', message: 'Subscription not found' });
      }

      return { success: true };
    }),
});
