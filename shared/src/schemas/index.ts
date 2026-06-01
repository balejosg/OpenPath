import { z } from 'zod';

// =============================================================================
// Enum Types
// =============================================================================

export const RequestStatus = z.enum(['pending', 'approved', 'rejected']);

export const UserRole = z.enum(['admin', 'teacher', 'student']);
export const GroupVisibility = z.enum(['private', 'instance_public']);
export const MachineStatus = z.enum(['online', 'offline', 'unknown']);
export const HealthStatus = z.enum([
  'HEALTHY',
  'DEGRADED',
  'CRITICAL',
  'FAIL_OPEN',
  'STALE_FAILSAFE',
  'TAMPERED',
]);

// =============================================================================
// Entity Schemas
// =============================================================================

export const DomainRequest = z.object({
  id: z.string(),
  domain: z.string(),
  reason: z.string(),
  requesterEmail: z.string(),
  groupId: z.string(),
  source: z.string().optional(),
  machineHostname: z.string().nullable().optional(),
  originHost: z.string().nullable().optional(),
  originPage: z.string().nullable().optional(),
  clientVersion: z.string().nullable().optional(),
  errorType: z.string().nullable().optional(),

  status: RequestStatus,
  createdAt: z.string(),
  updatedAt: z.string(),
  resolvedAt: z.string().nullable(),
  resolvedBy: z.string().nullable(),
  resolutionNote: z.string().optional(),
});

export const User = z.object({
  id: z.string(),
  email: z.email(),
  name: z.string(),
  passwordHash: z.string().optional(),
  googleId: z.string().optional(),
  isActive: z.boolean(),
  emailVerified: z.boolean().optional(),
  createdAt: z.string(),
  updatedAt: z.string(),
});

export const SafeUser = User.omit({ passwordHash: true, googleId: true });

export const RoleInfo = z.object({
  role: UserRole,
  groupIds: z.array(z.string()),
});

export const UserCapabilities = z.object({
  teacherGroups: z.boolean(),
});

export const SafeUserWithRoles = SafeUser.extend({
  roles: z.array(RoleInfo),
});

export const AuthUser = SafeUser.pick({
  id: true,
  email: true,
  name: true,
}).extend({
  emailVerified: z.boolean(),
  roles: z.array(RoleInfo),
  capabilities: UserCapabilities,
});

export const Role = z.object({
  id: z.string(),
  userId: z.string(),
  role: UserRole,
  groupIds: z.array(z.string()),
  createdAt: z.string(),
  expiresAt: z.string().nullable(),
});

export const Classroom = z.object({
  id: z.string(),
  name: z.string(),
  displayName: z.string(),
  defaultGroupId: z.string().nullable(),
  activeGroupId: z.string().nullable(),
  captivePortalDomains: z.array(z.string()).default([]),
  currentGroupId: z.string().nullable().optional(),
  createdAt: z.string(),
  updatedAt: z.string(),
  // Optional computed/joined fields
  machines: z.array(z.lazy(() => Machine)).optional(),
  machineCount: z.number().optional(),
});

export const Machine = z.object({
  id: z.string(),
  hostname: z.string(),
  classroomId: z.string().nullable(),
  version: z.string().optional(),
  lastSeen: z.string().nullable(),
  status: MachineStatus,
  createdAt: z.string().optional(),
  updatedAt: z.string().optional(),
});

export const Schedule = z.object({
  id: z.string(),
  classroomId: z.string(),
  dayOfWeek: z.number().min(1).max(5), // 1=Mon, 5=Fri (weekdays only)
  startTime: z.string(),
  endTime: z.string(),
  groupId: z.string(),
  teacherId: z.string(),
  recurrence: z.string().optional().default('weekly'),
  createdAt: z.string(),
  updatedAt: z.string().optional(),
});

export const OneOffSchedule = z.object({
  id: z.string(),
  classroomId: z.string(),
  startAt: z.string(),
  endAt: z.string(),
  groupId: z.string(),
  teacherId: z.string(),
  recurrence: z.literal('one_off').optional().default('one_off'),
  createdAt: z.string(),
  updatedAt: z.string().optional(),
});

export const HealthReport = z.object({
  id: z.string(),
  hostname: z.string(),
  status: HealthStatus,
  dnsmasqRunning: z.number().nullable().optional(), // 1=true, 0=false, null=unknown
  dnsResolving: z.number().nullable().optional(), // 1=true, 0=false, null=unknown
  failCount: z.number().default(0),
  actions: z.string().nullable().optional(),
  version: z.string().nullable().optional(),
  reportedAt: z.string(),
});

export const PushSubscription = z.object({
  id: z.string(),
  userId: z.string(),
  groupIds: z.array(z.string()),
  endpoint: z.string(),
  p256dh: z.string(),
  auth: z.string(),
  userAgent: z.string().nullable().optional(),
  createdAt: z.string(),
});

// =============================================================================
// TypeScript Type Exports (inferred from Zod schemas)
// =============================================================================

export type RequestStatus = z.infer<typeof RequestStatus>;

export type UserRole = z.infer<typeof UserRole>;
export type GroupVisibility = z.infer<typeof GroupVisibility>;
export type MachineStatus = z.infer<typeof MachineStatus>;
export type HealthStatus = z.infer<typeof HealthStatus>;

export type DomainRequest = z.infer<typeof DomainRequest>;
export type User = z.infer<typeof User>;
export type SafeUser = z.infer<typeof SafeUser>;
export type RoleInfo = z.infer<typeof RoleInfo>;
export type UserCapabilities = z.infer<typeof UserCapabilities>;
export type SafeUserWithRoles = z.infer<typeof SafeUserWithRoles>;
export type AuthUser = z.infer<typeof AuthUser>;
export type Role = z.infer<typeof Role>;
export type Classroom = z.infer<typeof Classroom>;
export type Machine = z.infer<typeof Machine>;
export type Schedule = z.infer<typeof Schedule>;
export type OneOffSchedule = z.infer<typeof OneOffSchedule>;
export type HealthReport = z.infer<typeof HealthReport>;
export type PushSubscription = z.infer<typeof PushSubscription>;

// =============================================================================
// API Response Types
// =============================================================================

export const APIResponse = <T extends z.ZodType>(
  dataSchema: T
): z.ZodObject<{
  success: z.ZodBoolean;
  data: z.ZodOptional<T>;
  error: z.ZodOptional<z.ZodString>;
  code: z.ZodOptional<z.ZodString>;
  message: z.ZodOptional<z.ZodString>;
}> =>
  z.object({
    success: z.boolean(),
    data: dataSchema.optional(),
    error: z.string().optional(),
    code: z.string().optional(),
    message: z.string().optional(),
  });

export interface APIResponseType<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
  code?: string;
  message?: string;
}

export interface PaginatedResponse<T> extends APIResponseType<T[]> {
  total: number;
  page: number;
  limit: number;
  hasMore: boolean;
}

// =============================================================================
// DTO Schemas
// =============================================================================

// Enhanced domain validation regex:
// - Each label: 1-63 chars, alphanumeric with hyphens (not at start/end)
// - TLD: 2-63 chars, letters only
// - Total length: max 253 chars (validated separately via refine)
// - Supports wildcards (*.domain.com) for whitelist patterns
const DOMAIN_REGEX =
  /^(?:\*\.)?(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$/;

export const DomainSchema = z
  .string()
  .min(4, 'Domain too short')
  .max(253, 'Domain exceeds maximum length of 253 characters')
  .regex(DOMAIN_REGEX, 'Invalid domain format')
  .refine((domain) => !domain.includes('..'), 'Domain cannot contain consecutive dots')
  .refine((domain) => {
    // Validate each label length (max 63 chars)
    const labels = domain.replace(/^\*\./, '').split('.');
    return labels.every((label) => label.length <= 63);
  }, 'Each domain label must be 63 characters or less');

export const CreateRequestDTO = z
  .object({
    domain: DomainSchema,
    reason: z.string().optional(),
    requesterEmail: z.email().optional(),
    groupId: z.string().optional(),

    source: z.string().max(50).optional(),
    machineHostname: z.string().max(255).optional(),
    originHost: z.string().max(255).optional(),
    originPage: z.string().max(2048).optional(),
    clientVersion: z.string().max(50).optional(),
    errorType: z.string().max(100).optional(),
  })
  .strict();

export const UpdateRequestStatusDTO = z.object({
  status: z.enum(['approved', 'rejected']),
  note: z.string().optional(),
});

export const StrongPasswordSchema = z
  .string()
  .min(8, 'Password must be at least 8 characters')
  .max(128, 'Password must be at most 128 characters')
  .regex(/[a-z]/, 'Password must include at least one lowercase letter')
  .regex(/[A-Z]/, 'Password must include at least one uppercase letter')
  .regex(/\d/, 'Password must include at least one number');

export const CreateUserDTO = z.object({
  email: z.email(),
  name: z.string().min(1),
  password: StrongPasswordSchema,
});

export const LoginDTO = z.object({
  email: z.email(),
  password: z.string().min(8),
});

export const CreateClassroomDTO = z.object({
  name: z.string().min(1),
  displayName: z.string().optional(),
  captivePortalDomains: z.array(z.string()).optional(),
});

export const CreateScheduleDTO = z.object({
  classroomId: z.string(),
  dayOfWeek: z.number().min(1).max(5), // 1=Mon, 5=Fri (weekdays only)
  startTime: z.string(),
  endTime: z.string(),
  groupId: z.string(),
  teacherId: z.string(),
  recurrence: z.string().optional(),
});

export const CreateOneOffScheduleDTO = z.object({
  classroomId: z.string(),
  startAt: z.string(),
  endAt: z.string(),
  groupId: z.string(),
  teacherId: z.string(),
  recurrence: z.literal('one_off').optional(),
});

export const UpdateOneOffScheduleDTO = z.object({
  id: z.string(),
  startAt: z.string().optional(),
  endAt: z.string().optional(),
  groupId: z.string().min(1).optional(),
});

export const PushSubscriptionKeys = z.object({
  p256dh: z.string(),
  auth: z.string(),
});

export const CreatePushSubscriptionDTO = z.object({
  endpoint: z.string().min(1),
  keys: PushSubscriptionKeys,
  expirationTime: z.number().nullable().optional(),
  userAgent: z.string().optional(),
});

// GitHub API response schemas (for SPA OAuth)
export const GitHubUser = z.object({
  id: z.number(),
  login: z.string(),
  avatar_url: z.string().optional(),
  name: z.string().nullable().optional(),
  email: z.string().nullable().optional(),
});

export const GitHubRepoPermissions = z.object({
  permissions: z
    .object({
      admin: z.boolean(),
      push: z.boolean(),
      pull: z.boolean(),
    })
    .optional(),
});

// DTO Types
export type CreateRequestDTO = z.infer<typeof CreateRequestDTO>;
export type UpdateRequestStatusDTO = z.infer<typeof UpdateRequestStatusDTO>;
export type CreateUserDTO = z.infer<typeof CreateUserDTO>;
export type LoginDTO = z.infer<typeof LoginDTO>;
export type CreateClassroomDTO = z.infer<typeof CreateClassroomDTO>;
export type CreateScheduleDTO = z.infer<typeof CreateScheduleDTO>;
export type CreateOneOffScheduleDTO = z.infer<typeof CreateOneOffScheduleDTO>;
export type UpdateOneOffScheduleDTO = z.infer<typeof UpdateOneOffScheduleDTO>;
export type PushSubscriptionKeys = z.infer<typeof PushSubscriptionKeys>;
export type CreatePushSubscriptionDTO = z.infer<typeof CreatePushSubscriptionDTO>;
export type GitHubUser = z.infer<typeof GitHubUser>;
export type GitHubRepoPermissions = z.infer<typeof GitHubRepoPermissions>;
