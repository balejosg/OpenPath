/**
 * Local mirror of CONFIG_POSTURE_KEYS from @openpath/shared
 * (shared/src/schemas/index.ts). NEVER import the runtime value from the
 * shared barrel in SPA source: any runtime import drags the whole package
 * into the bundle (known ~21→50 MB e2e memory regression). The test in
 * __tests__/config-posture.test.ts asserts this list stays identical to the
 * shared source of truth.
 */
export const CONFIG_POSTURE_KEYS = [
  'ipv6FirewallEnabled',
  'sinkholeFastFail',
  'captivePortalScopedPassthrough',
  'rfc1918EgressMode',
  'allowSetEgressEnabled',
  'failureMode',
  'outboundEgressFloorEnabled',
] as const;

export type ConfigPostureKey = (typeof CONFIG_POSTURE_KEYS)[number];

/**
 * Allowlisted, non-empty posture entries of a machine in canonical display
 * order. Free-form keys (which the API already strips) are ignored
 * defensively here too.
 */
export function configPostureEntries(
  posture: Record<string, string> | null | undefined
): { key: ConfigPostureKey; value: string }[] {
  if (!posture) {
    return [];
  }
  const entries: { key: ConfigPostureKey; value: string }[] = [];
  for (const key of CONFIG_POSTURE_KEYS) {
    const value = posture[key];
    if (typeof value === 'string' && value !== '') {
      entries.push({ key, value });
    }
  }
  return entries;
}
