import { z } from 'zod';

export const WINDOWS_OFFLINE_INSTALLER_HEADER_MAGIC = 'OPWSI1\0\0';
export const WINDOWS_OFFLINE_INSTALLER_EPILOGUE_MAGIC = 'OPWS';
export const WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION = 1;
export const WINDOWS_OFFLINE_INSTALLER_FLAGS = 0;
export const WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE = 52;
export const WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE = 16;
export const WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH = 65_536;
export const WINDOWS_OFFLINE_INSTALLER_TRAILER_SIZE =
  WINDOWS_OFFLINE_INSTALLER_HEADER_SIZE +
  WINDOWS_OFFLINE_INSTALLER_SLOT_LENGTH +
  WINDOWS_OFFLINE_INSTALLER_EPILOGUE_SIZE;

export const MAX_WINDOWS_OFFLINE_INSTALLER_API_URL_LENGTH = 2_048;
export const MAX_WINDOWS_OFFLINE_INSTALLER_CLASSROOM_ID_LENGTH = 128;
export const MAX_WINDOWS_OFFLINE_INSTALLER_ENROLLMENT_TOKEN_LENGTH = 8_192;
export const MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAINS = 16;
export const MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAIN_LENGTH = 253;
export const MAX_WINDOWS_OFFLINE_INSTALLER_APPROVED_STUDENT_BROWSERS = 8;
export const MAX_WINDOWS_OFFLINE_INSTALLER_APPROVED_STUDENT_BROWSER_LENGTH = 64;

const HOSTNAME_LABEL_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const UTC_TIMESTAMP_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

function isValidHttpsUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return (
      parsed.protocol === 'https:' &&
      parsed.hostname.length > 0 &&
      parsed.username.length === 0 &&
      parsed.password.length === 0 &&
      parsed.hash.length === 0
    );
  } catch {
    return false;
  }
}

function isValidHostname(value: string): boolean {
  if (value.length > MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAIN_LENGTH) {
    return false;
  }

  const normalized = value.toLowerCase();
  if (normalized.includes('..')) {
    return false;
  }

  const labels = normalized.split('.');
  const tld = labels.at(-1);
  return (
    labels.length >= 2 &&
    tld !== undefined &&
    tld.length >= 2 &&
    labels.every((label) => HOSTNAME_LABEL_PATTERN.test(label))
  );
}

const HttpsUrlSchema = z
  .string()
  .min(1)
  .max(MAX_WINDOWS_OFFLINE_INSTALLER_API_URL_LENGTH)
  .refine(isValidHttpsUrl, 'apiUrl must be a valid HTTPS URL without credentials or hash');

const UtcIsoTimestampSchema = z
  .string()
  .regex(
    UTC_TIMESTAMP_PATTERN,
    'enrollmentTokenExpiresAt must be an ISO-8601 UTC timestamp with millisecond precision'
  )
  .refine((value) => {
    const parsed = new Date(value);
    return !Number.isNaN(parsed.getTime()) && parsed.toISOString() === value;
  }, 'enrollmentTokenExpiresAt must be a valid UTC timestamp');

const CaptivePortalDomainSchema = z
  .string()
  .min(1)
  .max(MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAIN_LENGTH)
  .refine(isValidHostname, 'captivePortalDomains entries must be exact hostnames');

const ApprovedStudentBrowserSchema = z
  .string()
  .min(1)
  .max(MAX_WINDOWS_OFFLINE_INSTALLER_APPROVED_STUDENT_BROWSER_LENGTH);

export const WINDOWS_OFFLINE_INSTALLER_OPTIONS_SCHEMA = z
  .object({
    approvedStudentBrowsers: z
      .array(ApprovedStudentBrowserSchema)
      .max(MAX_WINDOWS_OFFLINE_INSTALLER_APPROVED_STUDENT_BROWSERS),
    installFirefoxIfMissing: z.boolean(),
    enforceManagedBrowserBoundary: z.boolean(),
  })
  .strict();

export const WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA = z
  .object({
    schemaVersion: z.literal(WINDOWS_OFFLINE_INSTALLER_SCHEMA_VERSION),
    apiUrl: HttpsUrlSchema,
    classroomId: z.string().min(1).max(MAX_WINDOWS_OFFLINE_INSTALLER_CLASSROOM_ID_LENGTH),
    enrollmentToken: z.string().min(1).max(MAX_WINDOWS_OFFLINE_INSTALLER_ENROLLMENT_TOKEN_LENGTH),
    enrollmentTokenExpiresAt: UtcIsoTimestampSchema,
    captivePortalDomains: z
      .array(CaptivePortalDomainSchema)
      .max(MAX_WINDOWS_OFFLINE_INSTALLER_CAPTIVE_PORTAL_DOMAINS),
    options: WINDOWS_OFFLINE_INSTALLER_OPTIONS_SCHEMA,
  })
  .strict();

export const WINDOWS_OFFLINE_INSTALLER_PAYLOAD_SCHEMA = WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA;

export type WindowsOfflineInstallerOptions = z.infer<
  typeof WINDOWS_OFFLINE_INSTALLER_OPTIONS_SCHEMA
>;
export type WindowsOfflineInstallerConfig = z.infer<typeof WINDOWS_OFFLINE_INSTALLER_CONFIG_SCHEMA>;
export type WindowsOfflineInstallerPayload = z.infer<
  typeof WINDOWS_OFFLINE_INSTALLER_PAYLOAD_SCHEMA
>;
