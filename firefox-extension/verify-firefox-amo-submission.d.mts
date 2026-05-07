export interface VerifyFirefoxAmoSubmissionOptions {
  manifestPath?: string;
  sourceArchive?: string;
  metadataPath?: string;
}

export interface VerifyFirefoxAmoSubmissionResult {
  required: boolean;
  sourceArchive: string;
  metadataPath: string;
  approvalNotes: string;
  releaseNotes: Record<string, string>;
}

export function verifyFirefoxAmoSubmission(
  options?: VerifyFirefoxAmoSubmissionOptions
): VerifyFirefoxAmoSubmissionResult;
