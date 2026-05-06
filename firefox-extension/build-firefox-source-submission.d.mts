export interface BuildFirefoxSourceSubmissionOptions {
  rootDir?: string;
  outputPath?: string;
  entries?: string[];
}

export interface BuildFirefoxSourceSubmissionResult {
  outputPath: string;
  entries: string[];
}

export function buildFirefoxSourceSubmission(
  options?: BuildFirefoxSourceSubmissionOptions
): BuildFirefoxSourceSubmissionResult;
