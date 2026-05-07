export interface FirefoxReleaseMetadata {
  extensionId: string;
  version: string;
  signatureSource: 'amo';
  signatureState: 'signed';
  installUrl?: string;
  payloadHash: string;
}

export function verifyFirefoxReleaseArtifacts(options: {
  releaseDir?: string;
  payloadHash: string;
}): FirefoxReleaseMetadata;
