import {
  createSubmittedMachineRequest,
  type CreateSubmittedMachineRequestInput,
  type PendingMachineRequestOutcome,
  type PublicRequestResult,
  type PublicRequestServiceError,
} from './machine-request-admission.service.js';

export type { PendingMachineRequestOutcome, PublicRequestResult, PublicRequestServiceError };

export async function submitMachineRequest(
  input: CreateSubmittedMachineRequestInput
): Promise<PublicRequestResult<PendingMachineRequestOutcome>> {
  return createSubmittedMachineRequest(input);
}

export default {
  submitMachineRequest,
};
