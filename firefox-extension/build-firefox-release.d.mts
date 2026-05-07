export interface FirefoxReleaseMetadata {
  extensionId: string;
  version: string;
  signatureSource: 'amo';
  signatureState: 'signed';
  installUrl?: string;
  payloadHash?: string;
}

export interface PrepareFirefoxReleaseArtifactsOptions {
  extensionRoot?: string;
  signedXpiPath: string;
  installUrl?: string;
  outputDir?: string;
  manifestPath?: string;
  extensionId?: string;
  version?: string;
  payloadHash?: string;
}

export interface PrepareFirefoxReleaseArtifactsResult {
  outputDir: string;
  outputXpiPath: string;
  metadataPath: string;
  metadata: FirefoxReleaseMetadata;
}

export function prepareFirefoxReleaseArtifacts(
  options: PrepareFirefoxReleaseArtifactsOptions
): PrepareFirefoxReleaseArtifactsResult;
