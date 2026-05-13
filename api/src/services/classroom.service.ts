/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * ClassroomService - Business logic for classroom and machine management
 */

export type {
  ClassroomAccessResult,
  ClassroomAccessScope,
  ClassroomMachineListItem,
  ClassroomResult,
  ClassroomServiceError,
  ClassroomStatus,
  ClassroomWithMachines,
  CreateClassroomInput,
  CreateMachineExemptionInput,
  CreateOperationalMachineExemptionInput,
  CurrentGroupSource,
  MachineExemptionInfo,
  MachineInfo,
  MachineRegistrationResult,
  MachineStatus,
  RegisterMachineInput,
  RotateMachineTokenResult,
  SetActiveGroupInput,
  UpdateClassroomData,
} from './classroom-service-shared.js';
export {
  ensureUserCanAccessClassroom,
  ensureUserCanEnrollClassroom,
} from './classroom-access.service.js';
export { getClassroom, getStats, listClassrooms, listMachines } from './classroom-query.service.js';
export {
  createClassroom,
  createExemptionForClassroom,
  createOperationalExemptionForClassroom,
  deleteClassroom,
  deleteExemptionForClassroom,
  deleteMachine,
  listExemptionsForClassroom,
  registerMachine,
  rotateMachineToken,
  setClassroomActiveGroup,
  updateClassroom,
} from './classroom-command.service.js';

import {
  ensureUserCanAccessClassroom,
  ensureUserCanEnrollClassroom,
} from './classroom-access.service.js';
import { getClassroom, getStats, listClassrooms, listMachines } from './classroom-query.service.js';
import {
  createClassroom,
  createExemptionForClassroom,
  createOperationalExemptionForClassroom,
  deleteClassroom,
  deleteExemptionForClassroom,
  deleteMachine,
  listExemptionsForClassroom,
  registerMachine,
  rotateMachineToken,
  setClassroomActiveGroup,
  updateClassroom,
} from './classroom-command.service.js';

export default {
  createClassroom,
  updateClassroom,
  setClassroomActiveGroup,
  createExemptionForClassroom,
  createOperationalExemptionForClassroom,
  deleteExemptionForClassroom,
  listExemptionsForClassroom,
  deleteClassroom,
  getStats,
  deleteMachine,
  listMachines,
  rotateMachineToken,
  registerMachine,
  listClassrooms,
  getClassroom,
  ensureUserCanAccessClassroom,
  ensureUserCanEnrollClassroom,
};
