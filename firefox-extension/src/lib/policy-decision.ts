export type PolicyDecision = 'allowed' | 'blocked' | 'unknown';

export interface PolicyDecisionInput {
  domain?: unknown;
  error?: unknown;
  inWhitelist?: unknown;
  policyActive?: unknown;
  policyDecision?: unknown;
  policyReason?: unknown;
  policyVersion?: unknown;
}

export interface NormalizedPolicyDecision {
  active: boolean | null;
  decision: PolicyDecision;
  error: string | null;
  reason: string | null;
  version: string | null;
}

export function normalizePolicyDecision(input: PolicyDecisionInput): NormalizedPolicyDecision {
  const active = typeof input.policyActive === 'boolean' ? input.policyActive : null;
  const error = typeof input.error === 'string' && input.error.length > 0 ? input.error : null;
  const reason =
    typeof input.policyReason === 'string' && input.policyReason.length > 0
      ? input.policyReason
      : null;
  const version =
    typeof input.policyVersion === 'string' && input.policyVersion.length > 0
      ? input.policyVersion
      : null;
  const decision: PolicyDecision =
    input.policyDecision === 'allowed' ||
    input.policyDecision === 'blocked' ||
    input.policyDecision === 'unknown'
      ? input.policyDecision
      : 'unknown';

  return { active, decision, error, reason, version };
}

export function permitsPolicyRedirect(
  verdict: NormalizedPolicyDecision,
  expectedVersion?: string
): boolean {
  return (
    verdict.active === true &&
    verdict.decision === 'blocked' &&
    verdict.error === null &&
    verdict.reason !== null &&
    verdict.version !== null &&
    (expectedVersion === undefined || verdict.version === expectedVersion)
  );
}
