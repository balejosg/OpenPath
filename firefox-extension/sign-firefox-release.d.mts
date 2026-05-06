export interface BuildWebExtSignArgsOptions {
  apiKey: string;
  apiSecret: string;
  artifactsDir: string;
  sourceDir?: string;
  uploadSourceCode?: string;
  amoMetadata?: string;
}

export function buildWebExtSignArgs(options: BuildWebExtSignArgsOptions): string[];

export interface ComputeFirefoxReleasePayloadHashOptions {
  sourceDir?: string;
}

export function computeFirefoxReleasePayloadHash(
  options?: ComputeFirefoxReleasePayloadHashOptions
): string;

export function findSignedXpiArtifact(artifactsDir: string): string;

export interface PrepareSigningSourceDirOptions {
  sourceDir?: string;
  version?: string;
}

export interface PrepareSigningSourceDirResult {
  sourceDir: string;
  effectiveVersion: string;
  cleanup: () => void;
}

export function prepareSigningSourceDir(
  options?: PrepareSigningSourceDirOptions
): PrepareSigningSourceDirResult;
