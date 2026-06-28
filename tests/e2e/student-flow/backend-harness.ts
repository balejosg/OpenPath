#!/usr/bin/env npx tsx

import path from 'node:path';
import { pathToFileURL } from 'node:url';

export type {
  ActiveGroupResult,
  BootstrapStudentScenarioOptions,
  ExemptionResult,
  HarnessClassroom,
  HarnessCredentials,
  HarnessGroup,
  HarnessMachine,
  HarnessSchedule,
  HarnessSession,
  PublicRequestSubmission,
  RequestMutationResult,
  RequestStatusResult,
  RuleMutationResult,
  StudentFixtureHosts,
  StudentScenario,
} from './backend-harness-shared.js';
export {
  approveRequest,
  createClassroom,
  createEnrollmentTicket,
  createGroup,
  createGroupRule,
  createOneOffSchedule,
  createTemporaryExemption,
  deleteGroupRule,
  deleteTemporaryExemption,
  getClassroomDetails,
  getRequestStatus,
  login,
  registerMachine,
  rejectRequest,
  setActiveGroup,
  submitManualRequest,
  tickBoundaries,
} from './backend-harness-api.js';
export { bootstrapStudentScenario } from './backend-harness-scenario.js';

import { runCli } from './backend-harness-cli.js';

const isMainModule =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMainModule) {
  runCli(process.argv.slice(2)).catch((error: unknown) => {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`${message}\n`);
    process.exit(1);
  });
}
