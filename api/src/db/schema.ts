/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * Drizzle ORM Schema Definition
 * This is the source of truth for database types and migrations.
 */

import {
  pgTable,
  varchar,
  text,
  timestamp,
  integer,
  time,
  uuid,
  unique,
  uniqueIndex,
  index,
  check,
  boolean,
} from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

// =============================================================================
// Users Table
// =============================================================================

export const users = pgTable('users', {
  id: varchar('id', { length: 50 }).primaryKey(),
  email: varchar('email', { length: 255 }).unique().notNull(),
  name: varchar('name', { length: 255 }).notNull(),
  passwordHash: varchar('password_hash', { length: 255 }),
  googleId: varchar('google_id', { length: 255 }).unique(),
  isActive: boolean('is_active').default(true).notNull(),
  emailVerified: boolean('email_verified').default(false).notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow(),
});

// =============================================================================
// Roles Table
// =============================================================================

export const roles = pgTable(
  'roles',
  {
    id: varchar('id', { length: 50 }).primaryKey(),
    userId: varchar('user_id', { length: 50 })
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    role: varchar('role', { length: 20 }).notNull(), // 'admin' | 'teacher' | 'student'
    // Deferred normalization: IDs are validated on write until these arrays are replaced by join tables.
    groupIds: text('group_ids').array(),
    createdBy: varchar('created_by', { length: 50 }).references(() => users.id),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow(),
    expiresAt: timestamp('expires_at', { withTimezone: true }),
  },
  (table) => [
    unique('roles_user_id_key').on(table.userId),
    index('roles_role_idx').on(table.role),
    index('roles_group_ids_gin_idx').using('gin', table.groupIds),
  ]
);

// =============================================================================
// Requests Table
// =============================================================================

export const requests = pgTable(
  'requests',
  {
    id: varchar('id', { length: 50 }).primaryKey(),
    domain: varchar('domain', { length: 255 }).notNull(),
    reason: text('reason'),
    requesterEmail: varchar('requester_email', { length: 255 }),
    groupId: varchar('group_id', { length: 50 })
      .notNull()
      .references(() => whitelistGroups.id, { onDelete: 'cascade' }),
    source: varchar('source', { length: 50 }).default('unknown'),
    machineHostname: varchar('machine_hostname', { length: 255 }),
    originHost: varchar('origin_host', { length: 255 }),
    originPage: text('origin_page'),
    clientVersion: varchar('client_version', { length: 50 }),
    errorType: varchar('error_type', { length: 100 }),
    status: varchar('status', { length: 20 }).default('pending'),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow(),
    resolvedAt: timestamp('resolved_at', { withTimezone: true }),
    resolvedBy: varchar('resolved_by', { length: 255 }),
    resolutionNote: text('resolution_note'),
  },
  (table) => [
    index('requests_group_created_idx').on(table.groupId, table.createdAt),
    index('requests_status_created_idx').on(table.status, table.createdAt),
  ]
);

// =============================================================================
// Classrooms Table
// =============================================================================

export const classrooms = pgTable('classrooms', {
  id: varchar('id', { length: 50 }).primaryKey(),
  name: varchar('name', { length: 100 }).unique().notNull(),
  displayName: varchar('display_name', { length: 255 }).notNull(),
  defaultGroupId: varchar('default_group_id', { length: 50 }).references(() => whitelistGroups.id, {
    onDelete: 'set null',
  }),
  activeGroupId: varchar('active_group_id', { length: 50 }).references(() => whitelistGroups.id, {
    onDelete: 'set null',
  }),
  captivePortalDomains: text('captive_portal_domains')
    .array()
    .default(sql`'{}'::text[]`)
    .notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow(),
});

// =============================================================================
// Machines Table
// =============================================================================

export const machines = pgTable(
  'machines',
  {
    id: varchar('id', { length: 50 }).primaryKey(),
    hostname: varchar('hostname', { length: 255 }).unique().notNull(),
    reportedHostname: varchar('reported_hostname', { length: 255 }),
    classroomId: varchar('classroom_id', { length: 50 }).references(() => classrooms.id, {
      onDelete: 'cascade',
    }),
    version: varchar('version', { length: 50 }).default('unknown'),
    lastSeen: timestamp('last_seen', { withTimezone: true }).defaultNow(),
    downloadTokenHash: varchar('download_token_hash', { length: 64 }).unique(),
    downloadTokenLastRotatedAt: timestamp('download_token_last_rotated_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow(),
  },
  (table) => [index('machines_classroom_created_idx').on(table.classroomId, table.createdAt)]
);

// =============================================================================
// Schedules Table
// =============================================================================

export const schedules = pgTable(
  'schedules',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    classroomId: varchar('classroom_id', { length: 50 })
      .notNull()
      .references(() => classrooms.id, { onDelete: 'cascade' }),
    teacherId: varchar('teacher_id', { length: 50 })
      .notNull()
      .references(() => users.id),
    groupId: varchar('group_id', { length: 50 })
      .notNull()
      .references(() => whitelistGroups.id, { onDelete: 'cascade' }),

    // Weekly scheduling (Mon-Fri). Null for one-off schedules.
    dayOfWeek: integer('day_of_week'),
    startTime: time('start_time'),
    endTime: time('end_time'),

    // One-off scheduling (absolute instants). Null for weekly schedules.
    startAt: timestamp('start_at', { withTimezone: true }),
    endAt: timestamp('end_at', { withTimezone: true }),

    recurrence: varchar('recurrence', { length: 20 }).default('weekly'),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow(),
  },
  (table) => [
    index('schedules_classroom_weekly_idx').on(table.classroomId, table.dayOfWeek, table.startTime),
    index('schedules_classroom_one_off_start_idx').on(table.classroomId, table.startAt),
  ]
);

// =============================================================================
// Machine Exemptions Table
// =============================================================================

export const machineExemptions = pgTable(
  'machine_exemptions',
  {
    id: varchar('id', { length: 50 }).primaryKey(),
    machineId: varchar('machine_id', { length: 50 })
      .notNull()
      .references(() => machines.id, { onDelete: 'cascade' }),
    classroomId: varchar('classroom_id', { length: 50 })
      .notNull()
      .references(() => classrooms.id, { onDelete: 'cascade' }),
    scheduleId: uuid('schedule_id').references(() => schedules.id, { onDelete: 'cascade' }),
    source: varchar('source', { length: 20 }).notNull().default('schedule'),
    reason: text('reason'),
    createdBy: varchar('created_by', { length: 50 }).references(() => users.id, {
      onDelete: 'set null',
    }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  },
  (table) => [
    uniqueIndex('machine_exemptions_machine_schedule_expires_key')
      .on(table.machineId, table.scheduleId, table.expiresAt)
      .where(sql`${table.source} = 'schedule'`),
    uniqueIndex('machine_exemptions_machine_operational_expires_key')
      .on(table.machineId, table.expiresAt)
      .where(sql`${table.source} = 'operational' AND ${table.scheduleId} IS NULL`),
    index('machine_exemptions_classroom_expires_idx').on(table.classroomId, table.expiresAt),
    index('machine_exemptions_machine_expires_idx').on(table.machineId, table.expiresAt),
    check(
      'machine_exemptions_source_schedule_id_check',
      sql`${table.source} IN ('schedule', 'operational') AND ((${table.source} = 'schedule' AND ${table.scheduleId} IS NOT NULL) OR (${table.source} = 'operational' AND ${table.scheduleId} IS NULL))`
    ),
  ]
);
// =============================================================================
// Tokens Table (Refresh Token Blacklist)
// =============================================================================

export const tokens = pgTable(
  'tokens',
  {
    id: varchar('id', { length: 50 }).primaryKey(),
    userId: varchar('user_id', { length: 50 })
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    tokenHash: varchar('token_hash', { length: 255 }).notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  },
  (table) => [index('tokens_expires_at_idx').on(table.expiresAt)]
);

// =============================================================================
// Settings Table
// =============================================================================

export const settings = pgTable('settings', {
  key: varchar('key', { length: 100 }).primaryKey(),
  value: text('value').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow(),
});

// =============================================================================
// Password Reset Tokens Table
// =============================================================================

export const passwordResetTokens = pgTable(
  'password_reset_tokens',
  {
    id: varchar('id', { length: 50 }).primaryKey(),
    userId: varchar('user_id', { length: 50 })
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    tokenHash: varchar('token_hash', { length: 255 }).notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  },
  (table) => [index('password_reset_tokens_user_expires_idx').on(table.userId, table.expiresAt)]
);

export const emailVerificationTokens = pgTable(
  'email_verification_tokens',
  {
    id: varchar('id', { length: 50 }).primaryKey(),
    userId: varchar('user_id', { length: 50 })
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    tokenHash: varchar('token_hash', { length: 255 }).notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  },
  (table) => [index('email_verification_tokens_user_expires_idx').on(table.userId, table.expiresAt)]
);

// =============================================================================
// Push Subscriptions Table
// =============================================================================

export const pushSubscriptions = pgTable(
  'push_subscriptions',
  {
    id: varchar('id', { length: 50 }).primaryKey(),
    userId: varchar('user_id', { length: 50 })
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    // Deferred normalization: values are validated on write; '*' remains a deliberate wildcard sentinel.
    groupIds: text('group_ids').array().notNull(),
    endpoint: text('endpoint').unique().notNull(),
    p256dh: text('p256dh').notNull(),
    auth: text('auth').notNull(),
    userAgent: text('user_agent'),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  },
  (table) => [
    index('push_subscriptions_user_id_idx').on(table.userId),
    index('push_subscriptions_group_ids_gin_idx').using('gin', table.groupIds),
  ]
);

// =============================================================================
// Health Reports Table
// =============================================================================

export const healthReports = pgTable(
  'health_reports',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    hostname: varchar('hostname', { length: 255 }).notNull(),
    status: varchar('status', { length: 50 }).notNull(),
    dnsmasqRunning: integer('dnsmasq_running'), // 1=true, 0=false, null=unknown
    dnsResolving: integer('dns_resolving'), // 1=true, 0=false, null=unknown
    firewallActive: integer('firewall_active'), // 1=true, 0=false, null=unknown
    whitelistAgeHours: integer('whitelist_age_hours'), // null=unknown
    captivePortalMode: integer('captive_portal_mode'), // 1=true, 0=false, null=unknown
    failCount: integer('fail_count').default(0),
    actions: text('actions'),
    version: varchar('version', { length: 50 }),
    reportedAt: timestamp('reported_at', { withTimezone: true }).defaultNow(),
  },
  (table) => [index('health_reports_hostname_reported_at_idx').on(table.hostname, table.reportedAt)]
);

// =============================================================================
// Whitelist Groups Table (Dashboard)
// =============================================================================

export const whitelistGroups = pgTable('whitelist_groups', {
  id: varchar('id', { length: 50 }).primaryKey(),
  name: varchar('name', { length: 100 }).unique().notNull(),
  displayName: varchar('display_name', { length: 255 }).notNull(),
  enabled: integer('enabled').default(1).notNull(),
  visibility: varchar('visibility', { length: 20 }).default('private').notNull(),
  ownerUserId: varchar('owner_user_id', { length: 50 }).references(() => users.id, {
    onDelete: 'set null',
  }),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow(),
});

// =============================================================================
// Whitelist Rules Table (Dashboard)
// =============================================================================

export const whitelistRules = pgTable(
  'whitelist_rules',
  {
    id: varchar('id', { length: 50 }).primaryKey(),
    groupId: varchar('group_id', { length: 50 })
      .notNull()
      .references(() => whitelistGroups.id, { onDelete: 'cascade' }),
    type: varchar('type', { length: 50 }).notNull(), // 'whitelist' | 'blocked_subdomain' | 'blocked_path'
    value: varchar('value', { length: 500 }).notNull(),
    source: varchar('source', { length: 50 }).default('manual').notNull(), // 'manual' | 'auto_extension'
    enabled: integer('enabled').default(1).notNull(), // 1=activa (aplica en endpoint), 0=inhabilitada
    comment: text('comment'),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  },
  (table) => [
    unique('whitelist_rules_group_type_value_key').on(table.groupId, table.type, table.value),
  ]
);

// =============================================================================
// API Tokens Table (User-generated API keys)
// =============================================================================

export const apiTokens = pgTable('api_tokens', {
  id: varchar('id', { length: 50 }).primaryKey(),
  userId: varchar('user_id', { length: 50 })
    .notNull()
    .references(() => users.id, { onDelete: 'cascade' }),
  name: varchar('name', { length: 100 }).notNull(),
  tokenHash: varchar('token_hash', { length: 255 }).notNull(),
  lastFour: varchar('last_four', { length: 4 }).notNull(), // Last 4 chars for display
  lastUsedAt: timestamp('last_used_at', { withTimezone: true }),
  expiresAt: timestamp('expires_at', { withTimezone: true }),
  revokedAt: timestamp('revoked_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
});

// =============================================================================
// Dashboard Users Table (Legacy dashboard auth)
// =============================================================================

export const dashboardUsers = pgTable('dashboard_users', {
  id: varchar('id', { length: 50 }).primaryKey(),
  username: varchar('username', { length: 100 }).unique().notNull(),
  passwordHash: varchar('password_hash', { length: 255 }).notNull(),
  role: varchar('role', { length: 50 }).default('admin'),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow(),
});

// =============================================================================
// Type Inference Helpers
// =============================================================================

export type User = typeof users.$inferSelect;
export type NewUser = typeof users.$inferInsert;

export type Role = typeof roles.$inferSelect;
export type NewRole = typeof roles.$inferInsert;

export type Request = typeof requests.$inferSelect;
export type NewRequest = typeof requests.$inferInsert;

export type Classroom = typeof classrooms.$inferSelect;
export type NewClassroom = typeof classrooms.$inferInsert;

export type Machine = typeof machines.$inferSelect;
export type NewMachine = typeof machines.$inferInsert;

export type Schedule = typeof schedules.$inferSelect;
export type NewSchedule = typeof schedules.$inferInsert;

export type MachineExemption = typeof machineExemptions.$inferSelect;
export type NewMachineExemption = typeof machineExemptions.$inferInsert;

export type Token = typeof tokens.$inferSelect;
export type NewToken = typeof tokens.$inferInsert;

export type Setting = typeof settings.$inferSelect;
export type NewSetting = typeof settings.$inferInsert;

export type PushSubscription = typeof pushSubscriptions.$inferSelect;
export type NewPushSubscription = typeof pushSubscriptions.$inferInsert;

export type HealthReport = typeof healthReports.$inferSelect;
export type NewHealthReport = typeof healthReports.$inferInsert;

export type WhitelistGroup = typeof whitelistGroups.$inferSelect;
export type NewWhitelistGroup = typeof whitelistGroups.$inferInsert;

export type WhitelistRule = typeof whitelistRules.$inferSelect;
export type NewWhitelistRule = typeof whitelistRules.$inferInsert;

export type DashboardUser = typeof dashboardUsers.$inferSelect;
export type NewDashboardUser = typeof dashboardUsers.$inferInsert;

export type ApiToken = typeof apiTokens.$inferSelect;
export type NewApiToken = typeof apiTokens.$inferInsert;
