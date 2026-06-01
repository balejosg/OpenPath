import React from 'react';

import type {
  ClassroomMachineStatus as SharedMachineStatus,
  ClassroomStatus as SharedClassroomStatus,
  CurrentGroupSource as SharedCurrentGroupSource,
} from '@openpath/shared';

export enum UserRole {
  ADMIN = 'admin',
  TEACHER = 'teacher',
  STUDENT = 'student',
  NO_ROLES = 'no roles',
}

export interface User {
  id: string;
  name: string;
  email: string;
  roles: UserRole[];
  status: 'Active' | 'Inactive';
}

export type ClassroomStatus = SharedClassroomStatus;

export type MachineStatus = SharedMachineStatus;

export type CurrentGroupSource = SharedCurrentGroupSource;

export interface Classroom {
  id: string;
  name: string;
  displayName: string;
  defaultGroupId: string | null;
  defaultGroupDisplayName?: string | null;
  computerCount: number;
  activeGroup: string | null;
  currentGroupId: string | null;
  currentGroupDisplayName?: string | null;
  currentGroupSource?: CurrentGroupSource;
  status: ClassroomStatus;
  onlineMachineCount: number;
  captivePortalDomains?: string[];
  machines?: {
    id: string;
    hostname: string;
    lastSeen: string | null;
    status: MachineStatus;
  }[];
}

export interface ClassroomExemption {
  id: string;
  machineId: string;
  machineHostname?: string;
  classroomId: string;
  scheduleId: string | null;
  source: 'schedule' | 'operational';
  reason: string | null;
  createdBy: string | null;
  createdAt: string | null;
  expiresAt: string;
}

export interface Group {
  id: string;
  name: string;
  description: string;
  domainCount: number;
  status: 'Active' | 'Inactive';
}

export interface GroupData {
  enabled: boolean;
  whitelist: string[];
  blockedSubdomains: string[];
  blockedPaths: string[];
}

export interface Schedule {
  id: string;
  classroomId: string;
  dayOfWeek: number; // 1=Mon … 5=Fri
  startTime: string; // "HH:MM"
  endTime: string;
  groupId: string;
  groupDisplayName?: string | null;
  teacherId: string;
  teacherName?: string | null;
  recurrence?: string;
  createdAt: string;
  updatedAt?: string;
}

export interface OneOffSchedule {
  id: string;
  classroomId: string;
  startAt: string; // ISO
  endAt: string; // ISO
  groupId: string;
  groupDisplayName?: string | null;
  teacherId: string;
  teacherName?: string | null;
  recurrence?: 'one_off';
  createdAt: string;
  updatedAt?: string;
}

export interface ScheduleWithPermissions extends Schedule {
  isMine: boolean;
  canEdit: boolean;
}

export interface OneOffScheduleWithPermissions extends OneOffSchedule {
  isMine: boolean;
  canEdit: boolean;
}

export interface NavItem {
  id: string;
  label: string;
  icon: React.ReactNode;
}
