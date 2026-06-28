import {
  getOption,
  optionalProp,
  parseArgs,
  printJson,
  requireOption,
} from './backend-harness-shared.js';
import {
  approveRequest,
  createGroupRule,
  createTemporaryExemption,
  deleteGroupRule,
  deleteTemporaryExemption,
  getRequestStatus,
  rejectRequest,
  setActiveGroup,
  submitManualRequest,
  tickBoundaries,
} from './backend-harness-api.js';
import { bootstrapStudentScenario } from './backend-harness-scenario.js';

export async function runCli(argv: string[]): Promise<void> {
  const { command, options } = parseArgs(argv);

  switch (command) {
    case 'bootstrap': {
      const result = await bootstrapStudentScenario({
        apiUrl: requireOption(options, 'api-url'),
        ...optionalProp('scenarioName', getOption(options, 'scenario-name')),
        ...optionalProp('machineHostname', getOption(options, 'machine-hostname')),
        ...optionalProp('version', getOption(options, 'version')),
        admin: {
          ...optionalProp('email', getOption(options, 'admin-email')),
          ...optionalProp('password', getOption(options, 'admin-password')),
        },
        teacher: {
          ...optionalProp('email', getOption(options, 'teacher-email')),
          ...optionalProp('password', getOption(options, 'teacher-password')),
        },
      });
      printJson(result);
      return;
    }

    case 'submit-request': {
      const result = await submitManualRequest({
        apiUrl: requireOption(options, 'api-url'),
        domain: requireOption(options, 'domain'),
        hostname: requireOption(options, 'hostname'),
        token: requireOption(options, 'machine-token'),
        ...optionalProp('reason', getOption(options, 'reason')),
        ...optionalProp('originPage', getOption(options, 'origin-page')),
      });
      printJson(result);
      return;
    }

    case 'request-status': {
      const result = await getRequestStatus({
        apiUrl: requireOption(options, 'api-url'),
        requestId: requireOption(options, 'request-id'),
      });
      printJson(result);
      return;
    }

    case 'approve-request': {
      const result = await approveRequest({
        apiUrl: requireOption(options, 'api-url'),
        accessToken: requireOption(options, 'access-token'),
        requestId: requireOption(options, 'request-id'),
        ...optionalProp('groupId', getOption(options, 'group-id')),
      });
      printJson(result);
      return;
    }

    case 'reject-request': {
      const result = await rejectRequest({
        apiUrl: requireOption(options, 'api-url'),
        accessToken: requireOption(options, 'access-token'),
        requestId: requireOption(options, 'request-id'),
        ...optionalProp('reason', getOption(options, 'reason')),
      });
      printJson(result);
      return;
    }

    case 'create-rule': {
      const type = requireOption(options, 'type');
      if (type !== 'whitelist' && type !== 'blocked_subdomain' && type !== 'blocked_path') {
        throw new Error(`Unsupported rule type: ${type}`);
      }

      const result = await createGroupRule({
        apiUrl: requireOption(options, 'api-url'),
        accessToken: requireOption(options, 'access-token'),
        groupId: requireOption(options, 'group-id'),
        type,
        value: requireOption(options, 'value'),
        ...optionalProp('comment', getOption(options, 'comment')),
      });
      printJson(result);
      return;
    }

    case 'delete-rule': {
      const result = await deleteGroupRule({
        apiUrl: requireOption(options, 'api-url'),
        accessToken: requireOption(options, 'access-token'),
        ruleId: requireOption(options, 'rule-id'),
        ...optionalProp('groupId', getOption(options, 'group-id')),
      });
      printJson(result);
      return;
    }

    case 'create-exemption': {
      const result = await createTemporaryExemption({
        apiUrl: requireOption(options, 'api-url'),
        accessToken: requireOption(options, 'access-token'),
        machineId: requireOption(options, 'machine-id'),
        classroomId: requireOption(options, 'classroom-id'),
        scheduleId: requireOption(options, 'schedule-id'),
      });
      printJson(result);
      return;
    }

    case 'delete-exemption': {
      const result = await deleteTemporaryExemption({
        apiUrl: requireOption(options, 'api-url'),
        accessToken: requireOption(options, 'access-token'),
        exemptionId: requireOption(options, 'exemption-id'),
      });
      printJson(result);
      return;
    }

    case 'set-active-group': {
      const rawGroupId = requireOption(options, 'group-id');
      const result = await setActiveGroup({
        apiUrl: requireOption(options, 'api-url'),
        accessToken: requireOption(options, 'access-token'),
        classroomId: requireOption(options, 'classroom-id'),
        groupId: rawGroupId === 'null' ? null : rawGroupId,
      });
      printJson(result);
      return;
    }

    case 'tick-boundaries': {
      const result = await tickBoundaries(requireOption(options, 'at'));
      printJson(result);
      return;
    }

    case '':
      throw new Error(
        'Missing command. Expected one of: bootstrap, submit-request, request-status, approve-request, reject-request, create-rule, delete-rule, create-exemption, delete-exemption, set-active-group, tick-boundaries'
      );

    default:
      throw new Error(`Unknown command: ${command}`);
  }
}
