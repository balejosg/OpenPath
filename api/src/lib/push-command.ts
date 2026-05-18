/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 */

import { eq } from 'drizzle-orm';
import { v4 as uuidv4 } from 'uuid';
import webPush from 'web-push';
import { db } from '../db/index.js';
import { pushSubscriptions } from '../db/schema.js';
import { logger } from './logger.js';
import { config } from '../config.js';
import type { DomainRequest } from '../types/index.js';
import {
  type NotificationPayload,
  type NotificationResult,
  type PushSubscriptionData,
  type SubscriptionRecord,
  normalizeAndValidateSubscriptionGroupIds,
  VAPID_CONFIGURED,
} from './push-shared.js';
import { getSubscriptionsForGroup } from './push-query.js';

export async function saveSubscription(
  userId: string,
  groupIds: string[],
  subscription: PushSubscriptionData,
  userAgent = ''
): Promise<SubscriptionRecord> {
  const validatedGroupIds = await normalizeAndValidateSubscriptionGroupIds(groupIds);

  await db.delete(pushSubscriptions).where(eq(pushSubscriptions.endpoint, subscription.endpoint));

  const record = {
    id: `push_${uuidv4().slice(0, 8)}`,
    userId,
    groupIds: validatedGroupIds,
    endpoint: subscription.endpoint,
    p256dh: subscription.keys.p256dh,
    auth: subscription.keys.auth,
    userAgent,
  };

  await db.insert(pushSubscriptions).values(record);

  return {
    id: record.id,
    userId,
    groupIds: validatedGroupIds,
    subscription,
    userAgent,
    createdAt: new Date().toISOString(),
  };
}

export async function deleteSubscriptionByEndpoint(endpoint: string): Promise<boolean> {
  const result = await db
    .delete(pushSubscriptions)
    .where(eq(pushSubscriptions.endpoint, endpoint))
    .returning({ id: pushSubscriptions.id });

  return result.length > 0;
}

export async function deleteSubscriptionById(id: string): Promise<boolean> {
  const result = await db
    .delete(pushSubscriptions)
    .where(eq(pushSubscriptions.id, id))
    .returning({ id: pushSubscriptions.id });

  return result.length > 0;
}

export async function notifyTeachersOfNewRequest(
  request: DomainRequest
): Promise<NotificationResult> {
  if (!VAPID_CONFIGURED) {
    return { sent: 0, failed: 0, disabled: true };
  }

  const subscriptions = await getSubscriptionsForGroup(request.groupId);
  if (subscriptions.length === 0) {
    return { sent: 0, failed: 0, noSubscriptions: true };
  }

  const payload: NotificationPayload = {
    title: '📨 New request',
    body: `Domain: ${request.domain}`,
    icon: config.pushIconPath,
    badge: config.pushBadgePath,
    data: {
      requestId: request.id,
      domain: request.domain,
      groupId: request.groupId,
      url: `/?highlight=${request.id}`,
    },
  };

  const results = await Promise.allSettled(
    subscriptions.map((sub) => webPush.sendNotification(sub.subscription, JSON.stringify(payload)))
  );

  let sent = 0;
  let failed = 0;

  for (const [index, result] of results.entries()) {
    if (result.status === 'fulfilled') {
      sent++;
      continue;
    }

    failed++;
    const reason = result.reason as { statusCode?: number; message?: string } | undefined;
    if (reason?.statusCode === 410) {
      const subscription = subscriptions[index];
      if (subscription !== undefined) {
        await deleteSubscriptionByEndpoint(subscription.subscription.endpoint);
        logger.info('Removed expired push subscription', { subscriptionId: subscription.id });
      }
      continue;
    }

    logger.error('Push notification failed', {
      error: reason?.message,
      requestId: request.id,
      subscriptionId: subscriptions[index]?.id,
    });
  }

  logger.info('Push notifications sent', {
    sent,
    total: subscriptions.length,
    requestId: request.id,
  });

  return { sent, failed, total: subscriptions.length };
}
