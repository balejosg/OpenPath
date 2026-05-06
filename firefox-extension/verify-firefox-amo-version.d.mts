export interface BuildFirefoxAmoVersionUrlOptions {
  addonId?: string;
  versionId?: string;
  version?: string;
  amoBaseUrl?: string;
}

export function buildFirefoxAmoVersionUrl(options: BuildFirefoxAmoVersionUrlOptions): URL;

export interface VerifyFirefoxAmoVersionOptions extends BuildFirefoxAmoVersionUrlOptions {
  apiKey: string;
  apiSecret: string;
  requireSource?: boolean;
  requireApprovalNotes?: boolean;
  fetchImpl?: typeof fetch;
}

export interface FirefoxAmoVersionSummary {
  versionId: number | string;
  version: string;
  channel: string;
  fileStatus: string;
  sourcePresent: boolean;
  approvalNotesPresent: boolean;
}

export function verifyFirefoxAmoVersion(
  options: VerifyFirefoxAmoVersionOptions
): Promise<FirefoxAmoVersionSummary>;
