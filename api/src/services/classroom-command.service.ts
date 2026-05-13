import {
  createClassroom,
  deleteClassroom,
  setClassroomActiveGroup,
  updateClassroom,
} from './classroom-classroom-command.service.js';
import {
  createOperationalExemptionForClassroom,
  createExemptionForClassroom,
  deleteExemptionForClassroom,
  listExemptionsForClassroom,
} from './classroom-exemption-command.service.js';
import {
  deleteMachine,
  registerMachine,
  rotateMachineToken,
} from './classroom-machine-command.service.js';

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
};

export const ClassroomCommandService = {
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
};

export default ClassroomCommandService;
