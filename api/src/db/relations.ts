/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * Drizzle ORM Table Relations
 * Defines relationships for relational queries (e.g., db.query.classrooms.findMany({ with: { machines: true } }))
 */

import { relations } from 'drizzle-orm';
import {
  users,
  roles,
  classrooms,
  machines,
  schedules,
  machineExemptions,
  tokens,
  passwordResetTokens,
  emailVerificationTokens,
  windowsOfflineDownloadRefs,
} from './schema.js';

// =============================================================================
// User Relations
// =============================================================================

export const usersRelations = relations(users, ({ many }) => ({
  roles: many(roles),
  schedules: many(schedules),
  tokens: many(tokens),
  passwordResetTokens: many(passwordResetTokens),
  emailVerificationTokens: many(emailVerificationTokens),
  windowsOfflineDownloadRefs: many(windowsOfflineDownloadRefs),
}));

// =============================================================================
// Role Relations
// =============================================================================

export const rolesRelations = relations(roles, ({ one }) => ({
  user: one(users, {
    fields: [roles.userId],
    references: [users.id],
  }),
  createdByUser: one(users, {
    fields: [roles.createdBy],
    references: [users.id],
  }),
}));

// =============================================================================
// Classroom Relations
// =============================================================================

export const classroomsRelations = relations(classrooms, ({ many }) => ({
  machines: many(machines),
  schedules: many(schedules),
  machineExemptions: many(machineExemptions),
  windowsOfflineDownloadRefs: many(windowsOfflineDownloadRefs),
}));

export const windowsOfflineDownloadRefsRelations = relations(
  windowsOfflineDownloadRefs,
  ({ one }) => ({
    classroom: one(classrooms, {
      fields: [windowsOfflineDownloadRefs.classroomId],
      references: [classrooms.id],
    }),
    createdByUser: one(users, {
      fields: [windowsOfflineDownloadRefs.createdBy],
      references: [users.id],
    }),
  })
);

// =============================================================================
// Machine Relations
// =============================================================================

export const machinesRelations = relations(machines, ({ one, many }) => ({
  classroom: one(classrooms, {
    fields: [machines.classroomId],
    references: [classrooms.id],
  }),
  machineExemptions: many(machineExemptions),
}));

// =============================================================================
// Schedule Relations
// =============================================================================

export const schedulesRelations = relations(schedules, ({ one, many }) => ({
  classroom: one(classrooms, {
    fields: [schedules.classroomId],
    references: [classrooms.id],
  }),
  teacher: one(users, {
    fields: [schedules.teacherId],
    references: [users.id],
  }),
  machineExemptions: many(machineExemptions),
}));

// =============================================================================
// Machine Exemption Relations
// =============================================================================

export const machineExemptionsRelations = relations(machineExemptions, ({ one }) => ({
  machine: one(machines, {
    fields: [machineExemptions.machineId],
    references: [machines.id],
  }),
  classroom: one(classrooms, {
    fields: [machineExemptions.classroomId],
    references: [classrooms.id],
  }),
  schedule: one(schedules, {
    fields: [machineExemptions.scheduleId],
    references: [schedules.id],
  }),
  createdByUser: one(users, {
    fields: [machineExemptions.createdBy],
    references: [users.id],
  }),
}));

// =============================================================================
// Token Relations
// =============================================================================

export const tokensRelations = relations(tokens, ({ one }) => ({
  user: one(users, {
    fields: [tokens.userId],
    references: [users.id],
  }),
}));

export const passwordResetTokensRelations = relations(passwordResetTokens, ({ one }) => ({
  user: one(users, {
    fields: [passwordResetTokens.userId],
    references: [users.id],
  }),
}));

export const emailVerificationTokensRelations = relations(emailVerificationTokens, ({ one }) => ({
  user: one(users, {
    fields: [emailVerificationTokens.userId],
    references: [users.id],
  }),
}));
