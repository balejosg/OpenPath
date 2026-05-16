/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * Dashboard tRPC Client
 *
 * Provides type-safe API communication with the OpenPath API server.
 */

import { createTRPCProxyClient, httpBatchLink, TRPCClientError } from '@trpc/client';
import type { AppRouter } from '@openpath/api';

// =============================================================================
// Configuration
// =============================================================================

const API_URL = process.env.API_URL ?? 'http://localhost:3000';

// =============================================================================
// Client Factory
// =============================================================================

type DashboardRouter = AppRouter;
type DashboardTRPCClient = ReturnType<typeof createTRPCProxyClient<DashboardRouter>>;

/**
 * Create a tRPC client with the provided authentication token.
 *
 * @param token - JWT access token for authentication
 * @returns Configured tRPC client
 */
export function createTRPCWithAuth(token: string): DashboardTRPCClient {
  return createTRPCProxyClient<DashboardRouter>({
    links: [
      httpBatchLink({
        url: `${API_URL}/trpc`,
        headers: () => ({
          Authorization: `Bearer ${token}`,
        }),
      }),
    ],
  });
}

/**
 * Create an unauthenticated tRPC client.
 * Used for login and other public endpoints.
 */
export function createTRPCPublic(): DashboardTRPCClient {
  return createTRPCProxyClient<DashboardRouter>({
    links: [
      httpBatchLink({
        url: `${API_URL}/trpc`,
      }),
    ],
  });
}

// =============================================================================
// Error Handling
// =============================================================================

/**
 * Check if an error is a tRPC client error.
 */
export function isTRPCError(error: unknown): error is TRPCClientError<DashboardRouter> {
  return error instanceof TRPCClientError;
}

export function getTRPCErrorCode(error: unknown): string | undefined {
  if (!isTRPCError(error) || typeof error.data !== 'object' || error.data === null) {
    return undefined;
  }

  const { code } = error.data as { code?: unknown };
  return typeof code === 'string' ? code : undefined;
}

/**
 * Extract error message from tRPC error or unknown error.
 */
export function getTRPCErrorMessage(error: unknown): string {
  if (isTRPCError(error)) {
    return error.message;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}

/**
 * Get HTTP-like status code from tRPC error.
 */
export function getTRPCErrorStatus(error: unknown): number {
  switch (getTRPCErrorCode(error)) {
    case 'BAD_REQUEST':
      return 400;
    case 'UNAUTHORIZED':
      return 401;
    case 'FORBIDDEN':
      return 403;
    case 'NOT_FOUND':
      return 404;
    case 'CONFLICT':
      return 409;
    case 'TOO_MANY_REQUESTS':
      return 429;
    default:
      return 500;
  }
}

// =============================================================================
// Exports
// =============================================================================

export { API_URL };
export type { DashboardRouter, DashboardTRPCClient };
